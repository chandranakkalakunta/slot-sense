"""Tests for the platform-admin bulk-create endpoint (Phase 13.5).

Endpoint: POST /api/v1/admin/tenants/{tenant_id}/users/bulk
Auth:     require_platform_admin (ADMIN_CLAIMS on ADMIN_HOST)

Distinct from the tenant-admin equivalent at /tenant/users/bulk (tested in
test_tenant_config.py). The admin endpoint:
  - Accepts arbitrary rows dicts (no Pydantic row model)
  - Returns {"results": [...]} only — no top-level total/created/failed summary
  - reason field stores exc.message (human string), not exc.code (machine token)
"""
from unittest.mock import MagicMock, patch

import firebase_admin.auth as fb_auth

from sport_slot.dependencies import get_firestore_client

VERIFY = "sport_slot.auth.dependency.fb_auth.verify_id_token"
CREATE_FB = "sport_slot.services.provisioning.fb_auth.create_user"
CLAIMS_FB = "sport_slot.services.provisioning.fb_auth.set_custom_user_claims"
DELETE_FB = "sport_slot.services.provisioning.fb_auth.delete_user"

ADMIN_CLAIMS = {"uid": "sa-1", "role": "platform_admin"}
ADMIN_HOST = {"host": "admin.slotsense.chandraailabs.com"}
AUTH = {"authorization": "Bearer fake"}

TENANT_ID = "t-bulk-1"
URL = f"/api/v1/admin/tenants/{TENANT_ID}/users/bulk"


def _mock_client(tenant_exists: bool = True, tenant_slug: str = "demo"):
    """Minimal mock for the provisioning paths used by bulk_create_users."""
    client = MagicMock()
    tenant_snap = MagicMock()
    tenant_snap.exists = tenant_exists
    tenant_snap.to_dict.return_value = {"slug": tenant_slug} if tenant_exists else {}
    client.collection.return_value.document.return_value.get.return_value = tenant_snap

    # Profile write (create) succeeds by default
    (client.collection.return_value
     .document.return_value
     .collection.return_value
     .document.return_value
     .create.return_value) = None

    # list_tenants (used if GET /admin/tenants is hit) returns empty — not relevant here
    client.collection.return_value.order_by.return_value.limit.return_value.stream.return_value = []
    return client


# ── (1) Happy path: all rows succeed ────────────────────────────────────────


async def test_bulk_admin_all_rows_created(make_client):
    """All rows valid → results list with status='created' and temp_password per row."""
    uid1, uid2 = MagicMock(uid="new-uid-1"), MagicMock(uid="new-uid-2")
    uid1.uid = "new-uid-1"
    uid2.uid = "new-uid-2"
    with patch(VERIFY, return_value=ADMIN_CLAIMS), \
         patch(CREATE_FB, side_effect=[uid1, uid2]), \
         patch(CLAIMS_FB), patch(DELETE_FB):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = lambda: _mock_client()
            resp = await c.post(
                URL,
                json={"rows": [
                    {"email": "alice@demo.com", "display_name": "Alice",
                     "flat_number": "A-1", "role": "resident"},
                    {"email": "bob@demo.com", "display_name": "Bob",
                     "flat_number": "B-2", "role": "resident"},
                ]},
                headers={**AUTH, **ADMIN_HOST},
            )

    assert resp.status_code == 200
    body = resp.json()
    results = body["results"]
    assert len(results) == 2

    # Both rows created
    assert all(r["status"] == "created" for r in results)

    # Per-row fields present: row number (1-indexed), email, temp_password
    assert results[0]["row"] == 1
    assert results[0]["email"] == "alice@demo.com"
    assert "temp_password" in results[0]
    assert len(results[0]["temp_password"]) == 6
    assert results[0]["temp_password"].isdigit()

    assert results[1]["row"] == 2
    assert results[1]["email"] == "bob@demo.com"
    assert "temp_password" in results[1]


# ── (2) Partial failure: mixed success/failure with per-row status ───────────


async def test_bulk_admin_mixed_success_and_failure(make_client):
    """Row 1 succeeds; row 2 has a duplicate email → status='failed' with reason message."""
    good_user = MagicMock()
    good_user.uid = "good-uid"
    with patch(VERIFY, return_value=ADMIN_CLAIMS), \
         patch(CREATE_FB, side_effect=[
             good_user,
             fb_auth.EmailAlreadyExistsError("", "", ""),
         ]), \
         patch(CLAIMS_FB), patch(DELETE_FB):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = lambda: _mock_client()
            resp = await c.post(
                URL,
                json={"rows": [
                    {"email": "ok@demo.com", "display_name": "OK",
                     "flat_number": "A-1", "role": "resident"},
                    {"email": "dup@demo.com", "display_name": "Dup",
                     "flat_number": "A-2", "role": "resident"},
                ]},
                headers={**AUTH, **ADMIN_HOST},
            )

    assert resp.status_code == 200
    results = resp.json()["results"]
    assert len(results) == 2

    created = next(r for r in results if r["status"] == "created")
    failed = next(r for r in results if r["status"] == "failed")

    # Successful row has temp_password
    assert "temp_password" in created
    assert created["email"] == "ok@demo.com"

    # Failed row has a non-empty human-readable reason (exc.message, not exc.code)
    assert failed["email"] == "dup@demo.com"
    assert failed.get("reason")  # non-empty string
    assert "dup@demo.com" in failed["reason"]  # message includes the email

    # No temp_password on failed row
    assert "temp_password" not in failed


# ── (3) Empty rows list → 200 with empty results, no crash ──────────────────


async def test_bulk_admin_empty_rows_returns_empty_results(make_client):
    """Empty rows list is allowed; the endpoint returns an empty results array."""
    with patch(VERIFY, return_value=ADMIN_CLAIMS):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = lambda: _mock_client()
            resp = await c.post(
                URL,
                json={"rows": []},
                headers={**AUTH, **ADMIN_HOST},
            )

    assert resp.status_code == 200
    body = resp.json()
    assert body["results"] == []


# ── (4) Missing required fields: per-row failure, no crash ──────────────────


async def test_bulk_admin_row_missing_flat_number_fails_per_row(make_client):
    """Resident row with no flat_number → per-row status='failed'; batch continues."""
    with patch(VERIFY, return_value=ADMIN_CLAIMS), patch(DELETE_FB):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = lambda: _mock_client()
            resp = await c.post(
                URL,
                json={"rows": [
                    {"email": "noflat@demo.com", "display_name": "No Flat",
                     "flat_number": "", "role": "resident"},
                ]},
                headers={**AUTH, **ADMIN_HOST},
            )

    assert resp.status_code == 200
    results = resp.json()["results"]
    assert len(results) == 1
    assert results[0]["status"] == "failed"
    assert results[0]["email"] == "noflat@demo.com"
    assert results[0].get("reason")  # non-empty error message


# ── (5) Over 500-row limit → 422 ────────────────────────────────────────────


async def test_bulk_admin_over_500_rows_returns_422(make_client):
    """More than 500 rows → 422 VALIDATION_FAILED before any creation attempt."""
    rows = [{"email": f"u{i}@demo.com", "display_name": f"U{i}",
             "flat_number": f"A-{i}", "role": "resident"}
            for i in range(501)]
    with patch(VERIFY, return_value=ADMIN_CLAIMS):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = lambda: _mock_client()
            resp = await c.post(
                URL,
                json={"rows": rows},
                headers={**AUTH, **ADMIN_HOST},
            )

    assert resp.status_code == 422
    assert resp.json()["code"] == "VALIDATION_FAILED"


# ── (6) Non-platform-admin caller is rejected ────────────────────────────────


async def test_bulk_admin_resident_caller_forbidden(make_client):
    """A resident caller is rejected at the auth gate before any row is processed."""
    resident_claims = {
        "uid": "u-1", "role": "resident",
        "tenant_id": "t-1", "tenant_slug": "demo",
    }
    with patch(VERIFY, return_value=resident_claims):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = lambda: _mock_client()
            resp = await c.post(
                URL,
                json={"rows": [{"email": "x@demo.com", "display_name": "X",
                                "flat_number": "A-1", "role": "resident"}]},
                headers={"authorization": "Bearer fake",
                         "host": "demo.slotsense.chandraailabs.com"},
            )

    assert resp.status_code == 403
    assert resp.json()["code"] == "FORBIDDEN_ROLE"
