"""Host isolation + agent/Vertex (env wiring)."""

from __future__ import annotations

import httpx
import pytest

from conftest import api_json

pytestmark = pytest.mark.functional


def test_wrong_tenant_host_rejected(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    """Resident of tenant A on host of tenant B → TENANT_MISMATCH (if multi-tenant).

    If only one tenant exists, uses a synthetic slug host that still matches
    base domain so host-derived slug is non-null and mismatches claim.
    """
    wrong_origin = f"https://not-your-tenant.{cfg.base_domain}"
    r, body = api_json(
        http, wrong_origin, "GET", "/api/v1/facilities", headers=auth_headers
    )
    # Host may 404 at LB if cert/host rules reject unknown hosts — either is OK
    # for isolation; if request reaches API, must be 403 TENANT_MISMATCH.
    if r.status_code in (404, 502, 503) and not isinstance(body, dict):
        pytest.skip(f"LB did not route synthetic host ({r.status_code})")
    assert r.status_code == 403, body
    if isinstance(body, dict):
        assert body.get("code") == "TENANT_MISMATCH", body


def test_admin_host_as_tenant_slug_is_not_tenant_data(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    """Calling tenant APIs on admin host: host slug may be 'admin' → mismatch.

    Documents that residents must use {slug}.{base_domain}, not admin host.
    """
    r, body = api_json(
        http, cfg.admin_origin, "GET", "/api/v1/facilities", headers=auth_headers
    )
    # platform_admin would pass; residents should 403 when admin is parsed as slug
    if r.status_code == 200:
        pytest.skip(
            "token appears platform-scoped or admin host not enforced as tenant slug"
        )
    assert r.status_code in (401, 403), body


def test_agent_query_not_vertex_disabled(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    """Vertex AI API disabled → 200 with safe-fallback only; detect via content.

    Would have caught missing aiplatform.googleapis.com on greenfield test.
    """
    if cfg.skip_agent:
        pytest.skip("FUNC_SKIP_AGENT=1")

    r, body = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/agent/query",
        headers=auth_headers,
        json={"message": "What facilities are available?"},
    )
    assert r.status_code == 200, body
    assert isinstance(body, dict), body
    reply = (
        body.get("reply")
        or body.get("message")
        or body.get("text")
        or ""
    )
    assert reply, f"empty agent reply: {body}"

    # Classic empty-Vertex fallback (orchestrator _SAFE_FALLBACK)
    fallback = "I can only help with facility availability and booking queries"
    # If only fallback and very short, Vertex likely failed closed
    if fallback.lower() in reply.lower() and len(reply) < 160:
        pytest.fail(
            "Agent returned safe-fallback-only reply — likely Vertex/AI Platform "
            f"disabled or IAM missing (reply={reply!r}). "
            "Enable aiplatform.googleapis.com and roles/aiplatform.user on Cloud Run SA."
        )
