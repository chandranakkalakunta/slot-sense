"""S-PERF P1: N parallel books for one slot → exactly one 201."""

from __future__ import annotations

import asyncio
import collections
import datetime
from zoneinfo import ZoneInfo

import httpx
import pytest

from conftest import api_json, pick_facility_id

pytestmark = pytest.mark.functional


def _tomorrow_iso(tz_name: str = "Asia/Kolkata") -> str:
    now = datetime.datetime.now(ZoneInfo(tz_name))
    return (now.date() + datetime.timedelta(days=1)).isoformat()


@pytest.mark.asyncio
async def test_slot_lock_exactly_one_winner(cfg, auth_headers: dict[str, str]) -> None:
    if cfg.skip_concurrency or cfg.skip_booking:
        pytest.skip("FUNC_SKIP_CONCURRENCY or FUNC_SKIP_BOOKING set")

    with httpx.Client(timeout=45.0, follow_redirects=True) as http:
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
            pytest.skip(f"no bookable slot for concurrency on {date}")
        start = bookable[-1]["start"]

    n = cfg.concurrency_n
    payload = {"facility_id": fid, "date": date, "start": start}
    headers = dict(auth_headers)
    winner_ids: list[str] = []

    async with httpx.AsyncClient(
        base_url=cfg.tenant_origin, timeout=45.0, follow_redirects=True
    ) as client:
        responses = await asyncio.gather(
            *[
                client.post("/api/v1/bookings", json=payload, headers=headers)
                for _ in range(n)
            ]
        )
        for resp in responses:
            if resp.status_code == 201:
                try:
                    bid = resp.json().get("id") or resp.json().get("booking_id")
                    if bid:
                        winner_ids.append(bid)
                except Exception:
                    pass
        for bid in winner_ids:
            await client.post(f"/api/v1/bookings/{bid}/cancel", headers=headers)

    counts = collections.Counter(r.status_code for r in responses)
    created = counts.get(201, 0)
    assert created == 1, (
        f"expected exactly one 201 under contention, got {created}; "
        f"status counts={dict(counts)}"
    )
    for resp in responses:
        if resp.status_code == 503:
            try:
                code = resp.json().get("code")
            except Exception:
                code = None
            assert code != "LOCK_UNAVAILABLE", resp.text
