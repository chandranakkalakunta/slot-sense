"""Platform admin: create tenant + tenant_admin + force-password path (F2, F4 partial)."""

from __future__ import annotations

import uuid

import httpx
import pytest

from conftest import api_json, firebase_id_token, require_mutations

pytestmark = pytest.mark.functional


def test_list_tenants_platform_admin(
    http: httpx.Client, cfg, platform_headers: dict[str, str]
) -> None:
    r, body = api_json(
        http, cfg.admin_origin, "GET", "/api/v1/admin/tenants", headers=platform_headers
    )
    assert r.status_code == 200, body
    assert "items" in body


def test_create_tenant_user_and_force_password(
    http: httpx.Client, cfg, platform_headers: dict[str, str]
) -> None:
    """Create ephemeral tenant + user, prove temp password + change-password, then wipe tenant."""
    require_mutations(cfg)
    if not cfg.firebase_api_key:
        pytest.skip("FUNC_FIREBASE_API_KEY required")

    slug = f"sfunc-{uuid.uuid4().hex[:8]}"
    email = f"sfunc-{uuid.uuid4().hex[:8]}@example.com"
    origin = cfg.admin_origin
    headers = platform_headers
    tenant_id: str | None = None

    try:
        r, body = api_json(
            http,
            origin,
            "POST",
            "/api/v1/admin/tenants",
            headers=headers,
            json={"slug": slug, "display_name": f"S-FUNC {slug}"},
        )
        assert r.status_code == 201, body
        tenant_id = body.get("tenant_id")
        assert tenant_id, body

        r2, body2 = api_json(
            http,
            origin,
            "POST",
            f"/api/v1/admin/tenants/{tenant_id}/users",
            headers=headers,
            json={
                "email": email,
                "display_name": "S-FUNC User",
                "role": "tenant_admin",
                "flat_number": "A-1",
            },
        )
        assert r2.status_code == 201, body2
        temp = body2.get("temp_password")
        uid = body2.get("uid")
        assert temp and uid, body2
        assert len(str(temp)) == 6 and str(temp).isdigit(), temp

        # Sign-in with temp code works
        tok = firebase_id_token(cfg.firebase_api_key, email, str(temp))
        user_headers = {"Authorization": f"Bearer {tok}"}
        tenant_origin = f"https://{slug}.{cfg.base_domain}"

        r3, me = api_json(
            http, tenant_origin, "GET", "/api/v1/users/me", headers=user_headers
        )
        assert r3.status_code == 200, me
        assert me.get("must_change_password") is True, me

        # Force-password change
        new_pw = f"Sfunc!{uuid.uuid4().hex[:10]}A1"
        r4, body4 = api_json(
            http,
            tenant_origin,
            "POST",
            "/api/v1/users/me/change-password",
            headers=user_headers,
            json={"new_password": new_pw},
        )
        assert r4.status_code == 200, body4

        # New password works; temp does not (or still works until refresh — re-login)
        tok2 = firebase_id_token(cfg.firebase_api_key, email, new_pw)
        r5, me2 = api_json(
            http,
            tenant_origin,
            "GET",
            "/api/v1/users/me",
            headers={"Authorization": f"Bearer {tok2}"},
        )
        assert r5.status_code == 200, me2
        # Flag should clear after change
        assert me2.get("must_change_password") in (False, None), me2

    finally:
        if tenant_id:
            rd, bodyd = api_json(
                http,
                origin,
                "DELETE",
                f"/api/v1/admin/tenants/{tenant_id}/permanent",
                headers=headers,
            )
            # Permanent delete may 200 or 404 if already gone
            assert rd.status_code in (200, 404), bodyd
