"""Platform admin facility catalog CRUD (F1b)."""

from __future__ import annotations

import time
import uuid

import httpx
import pytest

from conftest import api_json, require_mutations

pytestmark = pytest.mark.functional


def test_catalog_list_authenticated(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    r, body = api_json(
        http, cfg.tenant_origin, "GET", "/api/v1/facility-catalog", headers=auth_headers
    )
    assert r.status_code == 200, body
    assert "items" in body


def test_platform_catalog_crud(
    http: httpx.Client, cfg, platform_headers: dict[str, str]
) -> None:
    require_mutations(cfg)
    type_id = f"sfunc-{uuid.uuid4().hex[:8]}"
    origin = cfg.admin_origin
    headers = platform_headers

    # Create
    r, body = api_json(
        http,
        origin,
        "POST",
        "/api/v1/admin/facility-catalog",
        headers=headers,
        json={
            "type_id": type_id,
            "name": f"S-FUNC Test {type_id}",
            "sport": "test-sport",
        },
    )
    assert r.status_code == 201, body
    assert body.get("type_id") == type_id

    try:
        # List includes it
        r2, body2 = api_json(
            http, origin, "GET", "/api/v1/facility-catalog", headers=headers
        )
        assert r2.status_code == 200, body2
        ids = {(it or {}).get("type_id") for it in body2.get("items") or []}
        assert type_id in ids

        # Patch
        r3, body3 = api_json(
            http,
            origin,
            "PATCH",
            f"/api/v1/admin/facility-catalog/{type_id}",
            headers=headers,
            json={"name": f"S-FUNC Updated {type_id}"},
        )
        assert r3.status_code == 200, body3
        assert "Updated" in (body3.get("name") or "")
    finally:
        # Delete (hard)
        r4, _ = api_json(
            http,
            origin,
            "DELETE",
            f"/api/v1/admin/facility-catalog/{type_id}",
            headers=headers,
        )
        assert r4.status_code in (204, 200), r4.text
        # Confirm gone
        time.sleep(0.5)
        r5, body5 = api_json(
            http, origin, "GET", "/api/v1/facility-catalog", headers=headers
        )
        ids_after = {(it or {}).get("type_id") for it in (body5.get("items") or [])}
        assert type_id not in ids_after
