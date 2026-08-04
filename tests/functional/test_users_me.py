"""Authenticated identity surface (users/me)."""

from __future__ import annotations

import httpx
import pytest

from conftest import api_json

pytestmark = pytest.mark.functional


def test_users_me_returns_claims(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    r, body = api_json(
        http, cfg.tenant_origin, "GET", "/api/v1/users/me", headers=auth_headers
    )
    assert r.status_code == 200, body
    assert isinstance(body, dict), body
    # Profile doc may store role; at minimum email/uid present for provisioned users
    assert body.get("email") or body.get("uid") or body.get("display_name"), body
    role = body.get("role")
    if role is not None:
        assert role in (
            "resident",
            "tenant_admin",
            "household_admin",
        ), f"unexpected role: {body}"
