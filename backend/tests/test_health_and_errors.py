from unittest.mock import patch

import sport_slot.health as health


async def test_health_ok(make_client, monkeypatch):
    monkeypatch.setenv("BUILD_ID", "abc123")
    monkeypatch.setenv("DEPLOYED_AT", "2026-08-03T12:00:00Z")
    monkeypatch.setenv("K_REVISION", "sport-slot-api-00003-test")
    async with make_client() as client:
        resp = await client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["build_id"] == "abc123"
    assert body["deployed_at"] == "2026-08-03T12:00:00Z"
    assert body["revision"] == "sport-slot-api-00003-test"


async def test_version_matches_health_meta(make_client, monkeypatch):
    monkeypatch.setenv("BUILD_ID", "deadbeef")
    monkeypatch.setenv("DEPLOYED_AT", "2026-08-03T13:00:00Z")
    async with make_client() as client:
        h = (await client.get("/health")).json()
        v = (await client.get("/version")).json()
    assert v["build_id"] == h["build_id"] == "deadbeef"
    assert v["deployed_at"] == h["deployed_at"] == "2026-08-03T13:00:00Z"


async def test_readyz_ok_when_firestore_reachable(make_client):
    with patch.object(health, "_firestore_ping", return_value=None):
        async with make_client() as client:
            resp = await client.get("/readyz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ready"}


async def test_readyz_503_when_firestore_down(make_client):
    with patch.object(health, "_firestore_ping", side_effect=RuntimeError("boom")):
        async with make_client() as client:
            resp = await client.get("/readyz")
    assert resp.status_code == 503
    body = resp.json()
    assert body["code"] == "NOT_READY"
    assert body["request_id"]
    assert body["timestamp"]


async def test_request_id_header_on_every_response(make_client):
    async with make_client() as client:
        r1 = await client.get("/health")
        r2 = await client.get("/health")
    assert r1.headers["x-request-id"]
    assert r1.headers["x-request-id"] != r2.headers["x-request-id"]


async def test_404_uses_error_envelope(make_client):
    async with make_client() as client:
        resp = await client.get("/api/v1/nonexistent")
    assert resp.status_code == 404
    body = resp.json()
    assert body["code"] == "NOT_FOUND"
    assert body["request_id"] == resp.headers["x-request-id"]


async def test_security_headers_on_every_response(make_client):
    async with make_client() as client:
        resp = await client.get("/health")
    assert resp.headers["strict-transport-security"] == "max-age=31536000; includeSubDomains"
    assert resp.headers["x-content-type-options"] == "nosniff"
    assert resp.headers["x-frame-options"] == "DENY"
    assert resp.headers["referrer-policy"] == "strict-origin-when-cross-origin"
    assert resp.headers["content-security-policy"] == "default-src 'self'; frame-ancestors 'none'"
