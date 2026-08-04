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
    # Shape varies slightly; require tenant-scoped identity
    role = body.get("role") or (body.get("claims") or {}).get("role")
    slug = (
        body.get("tenant_slug")
        or (body.get("claims") or {}).get("tenant_slug")
        or body.get("tenant", {}).get("slug")
    )
    assert role in (
        "resident",
        "tenant_admin",
        "household_admin",
    ), f"unexpected role for resident functional user: {body}"
    if slug:
        assert slug == cfg.tenant_slug, (
            f"token tenant_slug={slug!r} != FUNC_TENANT_SLUG={cfg.tenant_slug!r}"
        )
