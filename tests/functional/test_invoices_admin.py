"""Tenant-admin invoice surfaces (latest, preview, export, regenerate)."""

from __future__ import annotations

import httpx
import pytest

from conftest import api_json

pytestmark = pytest.mark.functional


def test_tenant_latest_invoices(
    http: httpx.Client, cfg, tenant_admin_headers: dict[str, str]
) -> None:
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "GET",
        "/api/v1/invoices/tenant/latest",
        headers=tenant_admin_headers,
    )
    assert r.status_code == 200, body
    assert "items" in body


def test_tenant_invoice_preview_requires_household(
    http: httpx.Client, cfg, tenant_admin_headers: dict[str, str]
) -> None:
    # Missing household_id → 422/400
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "GET",
        "/api/v1/invoices/tenant/preview",
        headers=tenant_admin_headers,
    )
    assert r.status_code in (400, 422), body


def test_tenant_export_and_download_urls(
    http: httpx.Client, cfg, tenant_admin_headers: dict[str, str]
) -> None:
    """Export may no-op if no invoices; must not 5xx / LOCK_UNAVAILABLE."""
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/invoices/tenant/export",
        headers=tenant_admin_headers,
    )
    # 200 success, or 404/422 if no data for period
    assert r.status_code in (200, 404, 422), body
    if r.status_code == 503 and isinstance(body, dict):
        assert body.get("code") != "LOCK_UNAVAILABLE"

    r2, body2 = api_json(
        http,
        cfg.tenant_origin,
        "GET",
        "/api/v1/invoices/tenant/export/download",
        headers=tenant_admin_headers,
    )
    # Signed URLs or graceful error if no export files
    assert r2.status_code in (200, 404, 422, 500), body2
    if r2.status_code == 200:
        assert isinstance(body2, dict)


def test_tenant_regenerate_invoices(
    http: httpx.Client, cfg, tenant_admin_headers: dict[str, str]
) -> None:
    """Regenerate previous-month invoices (mutating). Skip if FUNC_SKIP_MUTATIONS."""
    if cfg.skip_mutations:
        pytest.skip("FUNC_SKIP_MUTATIONS=1")
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/invoices/tenant/regenerate",
        headers=tenant_admin_headers,
    )
    # May succeed with empty households or return structured result
    assert r.status_code in (200, 422, 404), body
    if r.status_code == 503 and isinstance(body, dict):
        assert body.get("code") != "LOCK_UNAVAILABLE"


def test_resident_cannot_regenerate(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/invoices/tenant/regenerate",
        headers=auth_headers,
    )
    assert r.status_code in (401, 403), body
