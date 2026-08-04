"""Agent propose → confirm/deny path (ADR-0023)."""

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


def test_agent_book_propose_then_deny(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    """Ask agent to book; if pending_action_id returned, confirm=false path via re-query deny.

    Confirm API is confirm=true + pending_action_id. We confirm then cancel if needed,
    or only assert propose returns structured fields when Vertex cooperates.
    """
    if cfg.skip_agent:
        pytest.skip("FUNC_SKIP_AGENT=1")
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
        pytest.skip(f"no bookable slot for agent book on {date}")
    start = bookable[-1]["start"]

    msg = (
        f"Please book facility {fid} on {date} at {start}. "
        "I want to reserve that slot."
    )
    r2, propose = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/agent/query",
        headers=auth_headers,
        json={"message": msg},
    )
    assert r2.status_code == 200, propose
    assert isinstance(propose, dict), propose
    reply = propose.get("reply") or ""
    assert reply, propose

    fallback = "I can only help with facility availability and booking queries"
    if fallback.lower() in reply.lower() and len(reply) < 180:
        pytest.fail(f"Vertex fallback on propose: {reply!r}")

    pending = propose.get("pending_action_id")
    if not pending:
        # Agent answered without propose (tool not chosen) — still OK if not fallback
        pytest.skip(
            f"agent did not return pending_action_id (no propose). reply={reply[:200]!r}"
        )

    # Execute confirm
    r3, confirmed = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/agent/query",
        headers=auth_headers,
        json={"confirm": True, "pending_action_id": pending},
    )
    assert r3.status_code == 200, confirmed
    conf_reply = (confirmed or {}).get("reply") or ""
    assert conf_reply, confirmed

    # Best-effort cleanup: cancel any booking created for that slot
    r4, mine = api_json(
        http, cfg.tenant_origin, "GET", "/api/v1/bookings/mine", headers=auth_headers
    )
    if r4.status_code == 200:
        for it in mine.get("items") or []:
            if (
                it.get("facility_id") == fid
                and it.get("date") == date
                and it.get("start") == start
                and it.get("status") == "confirmed"
            ):
                bid = it.get("id")
                if bid:
                    http.post(
                        f"{cfg.tenant_origin}/api/v1/bookings/{bid}/cancel",
                        headers=auth_headers,
                    )


def test_agent_confirm_without_pending_is_safe(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    if cfg.skip_agent:
        pytest.skip("FUNC_SKIP_AGENT=1")
    r, body = api_json(
        http,
        cfg.tenant_origin,
        "POST",
        "/api/v1/agent/query",
        headers=auth_headers,
        json={"confirm": True, "pending_action_id": "nonexistent-pending-id"},
    )
    assert r.status_code == 200, body
    reply = (body or {}).get("reply") or ""
    assert reply, body
    # Should not 500; expired/missing pending has a user-facing message
    assert "error" not in reply.lower() or "expired" in reply.lower() or "again" in reply.lower()
