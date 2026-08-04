"""Tenant admin daily overview + resident invoices (F6 partial)."""

from __future__ import annotations

import datetime
from zoneinfo import ZoneInfo

import httpx
import pytest

from conftest import api_json

pytestmark = pytest.mark.functional


def _today_iso(tz_name: str = "Asia/Kolkata") -> str:
    return datetime.datetime.now(ZoneInfo(tz_name)).date().isoformat()


def test_daily_overview_tenant_admin(
    http: httpx.Client, cfg, tenant_admin_headers: dict[str, str]
) -> None:
    date = _today_iso()
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "GET",
        f"/api/v1/tenant/overview/daily?date={date}",
        headers=tenant_admin_headers,
    )
    assert r.status_code == 200, body
    assert isinstance(body, dict), body
    assert body.get("date") == date
    assert "facilities" in body
    assert isinstance(body["facilities"], list)


def test_daily_overview_resident_forbidden(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    date = _today_iso()
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "GET",
        f"/api/v1/tenant/overview/daily?date={date}",
        headers=auth_headers,
    )
    # Residents must not see tenant-admin overview
    assert r.status_code in (401, 403), body


def test_invoices_mine_resident(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    r, body = api_json(
        http, cfg.tenant_origin, "GET", "/api/v1/invoices/mine", headers=auth_headers
    )
    # Empty list is OK on fresh tenants; must not 5xx
    assert r.status_code == 200, body
    assert isinstance(body, dict), body
