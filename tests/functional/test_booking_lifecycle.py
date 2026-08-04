"""Resident book → list → cancel (F5)."""

from __future__ import annotations

import datetime
from zoneinfo import ZoneInfo

import httpx
import pytest

from conftest import api_json, pick_facility_id

pytestmark = pytest.mark.functional


def _tomorrow_iso(tz_name: str = "Asia/Kolkata") -> str:
    now = datetime.datetime.now(ZoneInfo(tz_name))
    return (now.date() + datetime.timedelta(days=1)).isoformat()


def test_book_list_cancel_lifecycle(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    if cfg.skip_booking:
        pytest.skip("FUNC_SKIP_BOOKING=1")

    fid = pick_facility_id(http, cfg.tenant_origin, auth_headers, cfg.facility_id)
    date = _tomorrow_iso()
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "GET",
        f"/api/v1/facilities/{fid}/availability?date={date}",
        headers=auth_headers,
    )
    assert r.status_code == 200, body
    bookable = [s for s in (body.get("slots") or []) if s.get("bookable")]
    if not bookable:
        pytest.skip(f"no bookable slot on {date} for {fid}")

    start = bookable[-1]["start"]
    r2, created = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/bookings",
        headers=auth_headers,
        json={"facility_id": fid, "date": date, "start": start},
    )
    if r2.status_code == 503 and isinstance(created, dict):
        assert created.get("code") != "LOCK_UNAVAILABLE", created
    if r2.status_code in (409, 422):
        pytest.skip(f"slot not creatable ({r2.status_code}): {created}")
    assert r2.status_code == 201, created
    bid = created.get("id") or created.get("booking_id")
    assert bid, created

    try:
        r3, mine = api_json(
            http, cfg.tenant_origin, "GET", "/api/v1/bookings/mine", headers=auth_headers
        )
        assert r3.status_code == 200, mine
        items = mine.get("items") or []
        ids = {it.get("id") for it in items}
        assert bid in ids, f"created booking {bid} not in mine: {items[:5]}"
    finally:
        r4, cancelled = api_json(
            http,
            cfg.tenant_origin,
            "POST",
            f"/api/v1/bookings/{bid}/cancel",
            headers=auth_headers,
        )
        assert r4.status_code == 200, cancelled
