"""Public smoke + SPA embed checks (no auth required for most).

Would have caught wrong Firebase projectId and missing VITE_BASE_DOMAIN.
"""

from __future__ import annotations

import httpx
import pytest

pytestmark = pytest.mark.functional


def test_health_ok(http: httpx.Client, cfg) -> None:
    r = http.get(f"{cfg.admin_origin}/health")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body.get("status") == "ok"


def test_health_has_build_meta(http: httpx.Client, cfg) -> None:
    r = http.get(f"{cfg.admin_origin}/health")
    assert r.status_code == 200, r.text
    body = r.json()
    assert "build_id" in body, body
    assert body["build_id"] not in ("", None)
    assert "deployed_at" in body, body
    assert "revision" in body, body
    if cfg.expect_build_id:
        assert body["build_id"] == cfg.expect_build_id or body["build_id"].startswith(
            cfg.expect_build_id[:7]
        ), body


def test_version_matches_health(http: httpx.Client, cfg) -> None:
    h = http.get(f"{cfg.admin_origin}/health").json()
    v = http.get(f"{cfg.admin_origin}/version").json()
    assert v.get("build_id") == h.get("build_id")
    assert v.get("deployed_at") == h.get("deployed_at")


def test_tenant_host_health(http: httpx.Client, cfg) -> None:
    r = http.get(f"{cfg.tenant_origin}/health")
    assert r.status_code == 200, r.text
    assert r.json().get("status") == "ok"


def test_spa_embeds_firebase_project_id(http: httpx.Client, cfg) -> None:
    if not cfg.project_id:
        pytest.skip("FUNC_PROJECT_ID required")
    from conftest import fetch_spa_index_js

    js = fetch_spa_index_js(http, cfg.admin_origin)
    assert f'projectId:"{cfg.project_id}"' in js, (
        f"SPA does not embed projectId:\"{cfg.project_id}\" — wrong Firebase env"
    )
    if cfg.project_id != "sport-slot-dev":
        assert 'projectId:"sport-slot-dev"' not in js


def test_spa_embeds_base_domain(http: httpx.Client, cfg) -> None:
    """ADR-0046: without VITE_BASE_DOMAIN, redirects use prod apex and skip host checks."""
    from conftest import fetch_spa_index_js

    js = fetch_spa_index_js(http, cfg.tenant_origin)
    assert cfg.base_domain in js, (
        f"SPA does not embed FUNC_BASE_DOMAIN={cfg.base_domain} — "
        "VITE_BASE_DOMAIN missing at frontend build"
    )


def test_tls_cert_valid_for_tenant_host(http: httpx.Client, cfg) -> None:
    r = http.get(f"{cfg.tenant_origin}/health")
    assert r.status_code == 200
