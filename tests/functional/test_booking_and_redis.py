"""Booking path + Redis lock (would have caught LOCK_UNAVAILABLE 503)."""

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


def test_list_facilities_on_tenant_host(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    r, body = api_json(
        http, cfg.tenant_origin, "GET", "/api/v1/facilities", headers=auth_headers
    )
    assert r.status_code == 200, body
    items = body.get("items") or []
    assert items, "expected at least one facility for functional tenant"


def test_availability_returns_slots(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
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
    slots = body.get("slots") or []
    assert slots, f"no slots for facility {fid} on {date} — check weekly_schedule"
    # At least one slot not BEYOND_HORIZON for tomorrow under normal horizon>=1
    reasons = {s.get("reason") for s in slots}
    assert "BEYOND_HORIZON" not in reasons or any(
        s.get("bookable") for s in slots
    ), f"all slots beyond horizon for tomorrow; check policies: {reasons}"


def test_availability_horizon_respects_policy(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    """Far future date must be BEYOND_HORIZON (or empty); near day should not be all beyond."""
    fid = pick_facility_id(http, cfg.tenant_origin, auth_headers, cfg.facility_id)
    far = (datetime.date.today() + datetime.timedelta(days=60)).isoformat()
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "GET",
        f"/api/v1/facilities/{fid}/availability?date={far}",
        headers=auth_headers,
    )
    assert r.status_code == 200, body
    slots = body.get("slots") or []
    if slots:
        assert all(s.get("reason") == "BEYOND_HORIZON" for s in slots), slots[:3]
        assert all(not s.get("bookable") for s in slots)


def test_booking_create_not_lock_unavailable(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    """Redis AUTH mismatch surfaces as 503 LOCK_UNAVAILABLE on POST /bookings."""
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
        pytest.skip(
            f"no bookable slot on {date} for {fid} "
            f"(horizon/window/schedule) — cannot prove Redis path"
        )

    start = bookable[-1]["start"]  # prefer late slot to reduce collisions
    r2, body2 = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/bookings",
        headers=auth_headers,
        json={"facility_id": fid, "date": date, "start": start},
    )
    # Must NOT be Redis lock failure
    if r2.status_code == 503:
        code = body2.get("code") if isinstance(body2, dict) else None
        assert code != "LOCK_UNAVAILABLE", (
            "LOCK_UNAVAILABLE — Redis AUTH/secret mismatch or Memorystore down "
            f"(body={body2})"
        )

    assert r2.status_code in (201, 409, 422), (
        f"unexpected booking status {r2.status_code}: {body2}"
    )

    # Cleanup on success
    if r2.status_code == 201 and isinstance(body2, dict):
        bid = body2.get("id") or body2.get("booking_id")
        if bid:
            http.post(
                f"{cfg.tenant_origin}/api/v1/bookings/{bid}/cancel",
                headers=auth_headers,
            )
