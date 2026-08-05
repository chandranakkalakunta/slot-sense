#!/usr/bin/env python3
"""
Soak / load traffic against a SlotSense **test** environment (ADR-0045 / SLO-LOAD-TEST).

Uses seeded residents ({slug}.resident.N@example.com / ResidentPass143$) on
slot-sense-test-*. Discovers users via Firestore Admin; drives real HTTPS
book / cancel / availability traffic.

Scenarios (default mix):
  1. Steady multi-tenant traffic — book, list, cancel, availability
  2. Tenant coverage — at least --tenant-pct (default 15%) of tenants active
  3. Morning rush flash — many users hit the same slot (08:00 Asia/Kolkata
     wall-clock, or --rush-now)
  4. Periodic lock proof — N parallel POSTs → expect ≤1 winner per slot
  5. Horizon / multi-day scatter — book across next few days
  6. Read-heavy waves — facilities + availability without write

Monitoring: leave SlotSense Ops dashboard open (see docs/runbooks/soak-test.md).
Hold nightly env-power disable before long soaks.

Examples:
  # 30 min soak, rush immediately, 15% tenants, test-03
  cd backend && uv run python ../scripts/soak_test.py \\
    --project slot-sense-test-03 \\
    --base-domain slotsense-test.chandraailabs.com \\
    --firebase-api-key "$FUNC_FIREBASE_API_KEY" \\
    --duration 30m --rush-now --tenant-pct 15

  # Wait for real 08:00 IST flash, then continue soak 2h
  uv run python ../scripts/soak_test.py ... --duration 2h --rush-at 08:00
"""

from __future__ import annotations

import argparse
import asyncio
import collections
import json
import random
import statistics
import sys
import time
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import httpx

_REPO = Path(__file__).resolve().parents[1]
TZ = ZoneInfo("Asia/Kolkata")
DEFAULT_PASSWORD = "ResidentPass143$"  # nosec B105 — seed password
SEED_STATE = _REPO / ".seed-test-population-state.json"

# ── metrics ───────────────────────────────────────────────────────────────


@dataclass
class Metrics:
    latencies_ms: list[float] = field(default_factory=list)
    status: collections.Counter = field(default_factory=collections.Counter)
    ops: collections.Counter = field(default_factory=collections.Counter)
    errors: collections.Counter = field(default_factory=collections.Counter)
    rush_winners: int = 0
    rush_contenders: int = 0
    lock_proof_ok: int = 0
    lock_proof_fail: int = 0
    active_tenants: set[str] = field(default_factory=set)
    bookings_created: int = 0
    bookings_cancelled: int = 0

    def record(self, op: str, status: int, ms: float, tenant: str = "") -> None:
        self.ops[op] += 1
        self.status[status] += 1
        self.latencies_ms.append(ms)
        if tenant:
            self.active_tenants.add(tenant)
        if status >= 400:
            self.errors[f"{op}:{status}"] += 1

    def summary(self) -> dict[str, Any]:
        lats = sorted(self.latencies_ms)
        def pct(p: float) -> float | None:
            if not lats:
                return None
            i = min(len(lats) - 1, max(0, int(round((p / 100) * (len(lats) - 1)))))
            return round(lats[i], 1)

        return {
            "ops": dict(self.ops),
            "status": {str(k): v for k, v in self.status.items()},
            "errors_top": dict(self.errors.most_common(15)),
            "latency_ms": {
                "n": len(lats),
                "p50": pct(50),
                "p95": pct(95),
                "p99": pct(99),
                "max": round(lats[-1], 1) if lats else None,
                "mean": round(statistics.fmean(lats), 1) if lats else None,
            },
            "active_tenants": sorted(self.active_tenants),
            "active_tenant_count": len(self.active_tenants),
            "bookings_created": self.bookings_created,
            "bookings_cancelled": self.bookings_cancelled,
            "rush": {
                "contenders": self.rush_contenders,
                "winners": self.rush_winners,
            },
            "lock_proof": {"ok": self.lock_proof_ok, "fail": self.lock_proof_fail},
        }


# ── helpers ───────────────────────────────────────────────────────────────


def parse_duration(s: str) -> float:
    s = s.strip().lower()
    if s.endswith("h"):
        return float(s[:-1]) * 3600
    if s.endswith("m"):
        return float(s[:-1]) * 60
    if s.endswith("s"):
        return float(s[:-1])
    return float(s)


def log(msg: str) -> None:
    ts = datetime.now(TZ).strftime("%H:%M:%S")
    print(f"[soak {ts}] {msg}", flush=True)


def load_tenant_slugs(state_path: Path) -> list[str]:
    if state_path.is_file():
        data = json.loads(state_path.read_text())
        tenants = data.get("tenants") or {}
        # Prefer complete tenants with users
        ordered = []
        for slug, t in tenants.items():
            if t.get("complete") and (t.get("users_done") or 0) > 0:
                ordered.append(slug)
        if ordered:
            return ordered
        return list(tenants.keys())
    # Fallback seed list
    return [
        "marina-skies", "rvrg", "green-valley", "lakeview-heights",
        "orchid-park", "sunset-boulevard", "riverfront-plaza", "cedar-grove",
        "maple-residency", "azure-bay", "harmony-enclave", "prestige-oaks",
        "silver-oak-estate", "palm-meadows", "skyline-towers", "garden-city-homes",
        "royal-courtyard", "emerald-hills", "nimbus-park", "lakeside-commons",
    ]


def sample_residents_from_firestore(
    project: str,
    slugs: list[str],
    per_tenant: int,
) -> dict[str, list[dict[str, str]]]:
    """Return {slug: [{email, uid, flat_number}, ...]} via Admin SDK."""
    import firebase_admin
    from firebase_admin import credentials, firestore

    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.ApplicationDefault(), {"projectId": project})
    db = firestore.client()

    out: dict[str, list[dict[str, str]]] = {}
    for slug in slugs:
        # Resolve tenant_id by scanning tenants collection (slug field) or state
        tid = None
        if SEED_STATE.is_file():
            st = json.loads(SEED_STATE.read_text())
            tid = (st.get("tenants") or {}).get(slug, {}).get("tenant_id")
        if not tid:
            for doc in db.collection("tenants").where("slug", "==", slug).limit(1).stream():
                tid = doc.id
                break
        if not tid:
            log(f"WARN: no tenant_id for {slug} — skip")
            continue

        rows: list[dict[str, str]] = []
        # Prefer seeded residents — filter client-side (no composite index required)
        q = (
            db.collection("tenants")
            .document(tid)
            .collection("users")
            .limit(max(per_tenant * 20, 80))
        )
        for doc in q.stream():
            d = doc.to_dict() or {}
            email = d.get("email")
            if not email or d.get("active") is False:
                continue
            if d.get("role") and d.get("role") != "resident":
                continue
            rows.append(
                {
                    "email": email,
                    "uid": d.get("uid") or doc.id,
                    "flat_number": str(d.get("flat_number") or ""),
                }
            )
            if len(rows) >= per_tenant * 3:
                break
        random.shuffle(rows)
        out[slug] = rows[:per_tenant]
        log(f"sampled {len(out[slug])} residents for {slug} (tenant_id={tid})")
    return out


async def firebase_id_token(
    client: httpx.AsyncClient,
    api_key: str,
    email: str,
    password: str,
) -> str | None:
    url = (
        "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword"
        f"?key={api_key}"
    )
    r = await client.post(
        url,
        json={"email": email, "password": password, "returnSecureToken": True},
        timeout=30.0,
    )
    if r.status_code != 200:
        return None
    return r.json().get("idToken")


async def api(
    client: httpx.AsyncClient,
    metrics: Metrics,
    *,
    origin: str,
    method: str,
    path: str,
    token: str,
    op: str,
    tenant: str,
    json_body: dict | None = None,
) -> tuple[int, Any]:
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    t0 = time.perf_counter()
    try:
        r = await client.request(
            method,
            f"{origin}{path}",
            headers=headers,
            json=json_body,
            timeout=45.0,
        )
        ms = (time.perf_counter() - t0) * 1000
        metrics.record(op, r.status_code, ms, tenant)
        try:
            body = r.json()
        except Exception:
            body = None
        return r.status_code, body
    except Exception as exc:  # noqa: BLE001
        ms = (time.perf_counter() - t0) * 1000
        metrics.record(op, 0, ms, tenant)
        metrics.errors[f"{op}:exc:{type(exc).__name__}"] += 1
        return 0, None


# ── actors ────────────────────────────────────────────────────────────────


@dataclass
class Actor:
    slug: str
    email: str
    token: str
    origin: str
    facility_ids: list[str] = field(default_factory=list)
    my_bookings: list[str] = field(default_factory=list)


async def discover_facilities(
    client: httpx.AsyncClient,
    metrics: Metrics,
    actor: Actor,
) -> None:
    code, body = await api(
        client, metrics,
        origin=actor.origin, method="GET", path="/api/v1/facilities",
        token=actor.token, op="list_facilities", tenant=actor.slug,
    )
    if code != 200 or not body:
        return
    items = body.get("items") or body if isinstance(body, list) else body.get("items") or []
    ids = []
    for f in items:
        if isinstance(f, dict) and f.get("active", True):
            fid = f.get("id") or f.get("facility_id")
            if fid:
                ids.append(fid)
    actor.facility_ids = ids


async def pick_bookable_slot(
    client: httpx.AsyncClient,
    metrics: Metrics,
    actor: Actor,
    facility_id: str,
    day: date,
) -> str | None:
    code, body = await api(
        client, metrics,
        origin=actor.origin, method="GET",
        path=f"/api/v1/facilities/{facility_id}/availability?date={day.isoformat()}",
        token=actor.token, op="availability", tenant=actor.slug,
    )
    if code != 200 or not body:
        return None
    slots = [s for s in (body.get("slots") or []) if s.get("bookable")]
    if not slots:
        return None
    return random.choice(slots)["start"]


async def steady_tick(
    client: httpx.AsyncClient,
    metrics: Metrics,
    actor: Actor,
    rng: random.Random,
) -> None:
    """One unit of mixed real-world traffic for a resident."""
    if not actor.facility_ids:
        await discover_facilities(client, metrics, actor)
        if not actor.facility_ids:
            return

    roll = rng.random()
    fid = rng.choice(actor.facility_ids)
    # 40% availability read, 25% book, 15% list bookings, 15% cancel, 5% facilities refresh
    if roll < 0.40:
        day = date.today() + timedelta(days=rng.randint(0, 6))
        await pick_bookable_slot(client, metrics, actor, fid, day)
    elif roll < 0.65:
        day = date.today() + timedelta(days=rng.randint(1, 6))
        start = await pick_bookable_slot(client, metrics, actor, fid, day)
        if not start:
            return
        code, body = await api(
            client, metrics,
            origin=actor.origin, method="POST", path="/api/v1/bookings",
            token=actor.token, op="book", tenant=actor.slug,
            json_body={"facility_id": fid, "date": day.isoformat(), "start": start},
        )
        if code == 201 and isinstance(body, dict):
            bid = body.get("id") or body.get("booking_id")
            if bid:
                actor.my_bookings.append(bid)
                metrics.bookings_created += 1
    elif roll < 0.80:
        await api(
            client, metrics,
            origin=actor.origin, method="GET", path="/api/v1/bookings/mine",
            token=actor.token, op="list_mine", tenant=actor.slug,
        )
    elif roll < 0.95:
        if not actor.my_bookings:
            return
        bid = actor.my_bookings.pop(0)
        code, _ = await api(
            client, metrics,
            origin=actor.origin, method="POST",
            path=f"/api/v1/bookings/{bid}/cancel",
            token=actor.token, op="cancel", tenant=actor.slug,
        )
        if code in (200, 204):
            metrics.bookings_cancelled += 1
    else:
        await discover_facilities(client, metrics, actor)


async def rush_flash(
    client: httpx.AsyncClient,
    metrics: Metrics,
    actors: list[Actor],
    *,
    day: date,
    start_hint: str | None,
    n: int,
) -> None:
    """Morning rush: many users contend for early slots across active tenants."""
    contenders = actors[:n] if n < len(actors) else actors
    if not contenders:
        log("rush: no actors")
        return
    log(f"RUSH flash: {len(contenders)} contenders date={day}")

    # Group by tenant — each tenant has its own facilities/slots
    by_tenant: dict[str, list[Actor]] = collections.defaultdict(list)
    for a in contenders:
        by_tenant[a.slug].append(a)

    async def one_tenant(slug: str, group: list[Actor]) -> None:
        lead = group[0]
        if not lead.facility_ids:
            await discover_facilities(client, metrics, lead)
        if not lead.facility_ids:
            log(f"rush {slug}: no facilities")
            return
        fid = lead.facility_ids[0]
        start = start_hint
        if not start:
            start = await pick_bookable_slot(client, metrics, lead, fid, day)
        if not start:
            # try next days
            for off in range(1, 5):
                start = await pick_bookable_slot(
                    client, metrics, lead, fid, day + timedelta(days=off)
                )
                if start:
                    day_use = day + timedelta(days=off)
                    break
            else:
                log(f"rush {slug}: no bookable slot")
                return
        else:
            day_use = day

        body = {"facility_id": fid, "date": day_use.isoformat(), "start": start}
        metrics.rush_contenders += len(group)

        async def post(a: Actor) -> int:
            code, resp = await api(
                client, metrics,
                origin=a.origin, method="POST", path="/api/v1/bookings",
                token=a.token, op="rush_book", tenant=a.slug,
                json_body=body,
            )
            if code == 201 and isinstance(resp, dict):
                bid = resp.get("id") or resp.get("booking_id")
                if bid:
                    a.my_bookings.append(bid)
                    metrics.bookings_created += 1
                    metrics.rush_winners += 1
            return code

        codes = await asyncio.gather(*[post(a) for a in group])
        winners = sum(1 for c in codes if c == 201)
        log(
            f"rush {slug}: facility={fid} {day_use}@{start} "
            f"n={len(group)} winners={winners} codes={dict(collections.Counter(codes))}"
        )
        # Exactly one winner is ideal for same-slot contention
        if winners > 1:
            log(f"WARN rush {slug}: expected ≤1 winner, got {winners}")

    await asyncio.gather(*[one_tenant(s, g) for s, g in by_tenant.items()])


async def lock_proof_wave(
    client: httpx.AsyncClient,
    metrics: Metrics,
    actors: list[Actor],
    n: int = 12,
) -> None:
    """Classic N-parallel one-slot proof on one tenant."""
    if len(actors) < 2:
        return
    # Use multiple actors from same tenant if possible
    by_tenant: dict[str, list[Actor]] = collections.defaultdict(list)
    for a in actors:
        by_tenant[a.slug].append(a)
    slug, group = max(by_tenant.items(), key=lambda kv: len(kv[1]))
    group = group[: max(2, min(n, len(group)))]
    lead = group[0]
    if not lead.facility_ids:
        await discover_facilities(client, metrics, lead)
    if not lead.facility_ids:
        return
    fid = lead.facility_ids[0]
    day = date.today() + timedelta(days=2)
    start = await pick_bookable_slot(client, metrics, lead, fid, day)
    if not start:
        return
    body = {"facility_id": fid, "date": day.isoformat(), "start": start}

    async def post(a: Actor) -> int:
        code, resp = await api(
            client, metrics,
            origin=a.origin, method="POST", path="/api/v1/bookings",
            token=a.token, op="lock_proof", tenant=a.slug,
            json_body=body,
        )
        if code == 201 and isinstance(resp, dict):
            bid = resp.get("id") or resp.get("booking_id")
            if bid:
                # cancel to free slot for later waves
                await api(
                    client, metrics,
                    origin=a.origin, method="POST",
                    path=f"/api/v1/bookings/{bid}/cancel",
                    token=a.token, op="lock_proof_cancel", tenant=a.slug,
                )
                metrics.bookings_cancelled += 1
        return code

    codes = await asyncio.gather(*[post(a) for a in group])
    winners = sum(1 for c in codes if c == 201)
    if winners == 1:
        metrics.lock_proof_ok += 1
        log(f"lock_proof PASS tenant={slug} n={len(group)} winners=1")
    else:
        metrics.lock_proof_fail += 1
        log(f"lock_proof FAIL tenant={slug} n={len(group)} winners={winners} {dict(collections.Counter(codes))}")


async def wait_until_local(hhmm: str) -> None:
    hour, minute = map(int, hhmm.split(":"))
    while True:
        now = datetime.now(TZ)
        target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if now >= target:
            # if we started after target today, run immediately
            return
        wait = (target - now).total_seconds()
        if wait > 3600:
            log(f"waiting for {hhmm} IST — {wait/3600:.1f}h remaining")
            await asyncio.sleep(min(1800, wait / 2))
        elif wait > 60:
            log(f"waiting for {hhmm} IST — {wait:.0f}s")
            await asyncio.sleep(min(30, wait / 2))
        else:
            await asyncio.sleep(max(0.1, wait))
            return


# ── main ──────────────────────────────────────────────────────────────────


async def async_main(args: argparse.Namespace) -> int:
    if "test" not in args.project and not args.allow_non_test:
        log("ERROR: refuse non-test project (pass --allow-non-test to override)")
        return 2

    duration_s = parse_duration(args.duration)
    all_slugs = load_tenant_slugs(Path(args.state_file))
    n_tenants = max(1, int(round(len(all_slugs) * (args.tenant_pct / 100.0))))
    n_tenants = max(n_tenants, args.min_tenants)
    n_tenants = min(n_tenants, len(all_slugs))
    active_slugs = random.sample(all_slugs, n_tenants) if len(all_slugs) > n_tenants else all_slugs
    # Ensure pct target documented
    pct = 100.0 * len(active_slugs) / max(1, len(all_slugs))
    log(
        f"project={args.project} base={args.base_domain} "
        f"tenants_active={len(active_slugs)}/{len(all_slugs)} ({pct:.0f}%) "
        f"duration={args.duration} workers={args.workers}"
    )
    log(f"active tenants: {', '.join(sorted(active_slugs))}")
    log("TIP: hold nightly disable → make env-hold ENV=test-03 DAYS=1 REASON=soak")
    log("TIP: open SlotSense Ops dashboard + Cloud Run metrics for this project")

    # Sample residents
    log("sampling residents from Firestore (ADC)…")
    samples = sample_residents_from_firestore(
        args.project, active_slugs, per_tenant=args.users_per_tenant
    )
    if not samples:
        log("ERROR: no residents sampled — is seed complete and ADC authed?")
        return 1

    metrics = Metrics()
    password = args.password
    api_key = args.firebase_api_key

    actors: list[Actor] = []
    async with httpx.AsyncClient(timeout=45.0, follow_redirects=True) as client:
        # Auth pool
        log("signing in residents…")
        for slug, rows in samples.items():
            origin = f"https://{slug}.{args.base_domain}"
            for row in rows:
                tok = await firebase_id_token(client, api_key, row["email"], password)
                if not tok:
                    metrics.errors["auth_fail"] += 1
                    continue
                actors.append(
                    Actor(slug=slug, email=row["email"], token=tok, origin=origin)
                )
        log(f"authenticated actors={len(actors)} auth_fail={metrics.errors.get('auth_fail', 0)}")
        if len(actors) < 3:
            log("ERROR: need at least 3 authenticated actors")
            return 1

        # Warm facility lists
        await asyncio.gather(*[discover_facilities(client, metrics, a) for a in actors])

        # Optional wall-clock rush wait
        rush_done = False
        if args.rush_at and not args.rush_now:
            log(f"will fire morning rush at {args.rush_at} Asia/Kolkata")
            await wait_until_local(args.rush_at)
            await rush_flash(
                client, metrics, actors,
                day=date.today() + timedelta(days=1),
                start_hint=args.rush_slot or None,
                n=args.rush_n,
            )
            rush_done = True
        elif args.rush_now:
            await rush_flash(
                client, metrics, actors,
                day=date.today() + timedelta(days=1),
                start_hint=args.rush_slot or None,
                n=args.rush_n,
            )
            rush_done = True

        # Steady soak loop
        end = time.monotonic() + duration_s
        tick = 0
        rng = random.Random(args.seed)
        log(f"steady traffic for {args.duration} (workers={args.workers})…")

        async def worker(wid: int) -> None:
            nonlocal tick
            local = random.Random(args.seed + wid * 997)
            while time.monotonic() < end:
                actor = local.choice(actors)
                await steady_tick(client, metrics, actor, local)
                tick += 1
                # light pacing
                await asyncio.sleep(args.pace_ms / 1000.0)
                if tick % 50 == 0:
                    s = metrics.summary()
                    log(
                        f"progress ops={s['latency_ms']['n']} "
                        f"p95={s['latency_ms']['p95']}ms "
                        f"tenants={s['active_tenant_count']} "
                        f"created={s['bookings_created']} cancelled={s['bookings_cancelled']} "
                        f"5xx={sum(v for k,v in metrics.status.items() if k >= 500)}"
                    )
                # periodic lock proof
                if tick > 0 and tick % args.lock_proof_every == 0:
                    await lock_proof_wave(client, metrics, actors, n=args.lock_proof_n)

        await asyncio.gather(*[worker(i) for i in range(args.workers)])

        # Final rush if scheduled at end of soak and not yet done
        if args.rush_at_end and not rush_done:
            await rush_flash(
                client, metrics, actors,
                day=date.today() + timedelta(days=1),
                start_hint=args.rush_slot or None,
                n=args.rush_n,
            )

        # Final lock proof
        await lock_proof_wave(client, metrics, actors, n=args.lock_proof_n)

    summary = metrics.summary()
    summary["config"] = {
        "project": args.project,
        "base_domain": args.base_domain,
        "duration": args.duration,
        "tenant_pct_target": args.tenant_pct,
        "tenants_selected": sorted(active_slugs),
        "actors": len(actors),
        "workers": args.workers,
        "rush_now": args.rush_now,
        "rush_at": args.rush_at,
    }
    report_path = Path(args.report)
    report_path.write_text(json.dumps(summary, indent=2) + "\n")
    log(f"report → {report_path}")
    print(json.dumps(summary, indent=2))

    # Exit code: fail if tenant coverage short or lock proof always failed
    actual_pct = 100.0 * summary["active_tenant_count"] / max(1, len(all_slugs))
    if actual_pct + 0.5 < args.tenant_pct * 0.5:
        # only half of target ever touched — hard fail
        log(f"FAIL: tenant coverage {actual_pct:.0f}% << target {args.tenant_pct}%")
        return 1
    if metrics.lock_proof_fail > 0 and metrics.lock_proof_ok == 0 and metrics.lock_proof_fail >= 2:
        log("FAIL: lock proof never passed")
        return 1
    log(
        f"DONE coverage={actual_pct:.0f}% p95={summary['latency_ms']['p95']}ms "
        f"created={summary['bookings_created']} cancelled={summary['bookings_cancelled']}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="SlotSense test-env soak / load harness")
    p.add_argument("--project", default="slot-sense-test-03")
    p.add_argument("--base-domain", default="slotsense-test.chandraailabs.com")
    p.add_argument("--firebase-api-key", default="",
                   help="Firebase Web API key (or env SOAK_FIREBASE_API_KEY / FUNC_FIREBASE_API_KEY)")
    p.add_argument("--password", default=DEFAULT_PASSWORD)
    p.add_argument("--state-file", default=str(SEED_STATE))
    p.add_argument("--duration", default="30m", help="e.g. 30m, 2h, 3600s")
    p.add_argument("--tenant-pct", type=float, default=15.0,
                   help="%% of seeded tenants that must participate (default 15)")
    p.add_argument("--min-tenants", type=int, default=3)
    p.add_argument("--users-per-tenant", type=int, default=8,
                   help="Residents sampled & authed per active tenant")
    p.add_argument("--workers", type=int, default=12, help="Concurrent steady-state workers")
    p.add_argument("--pace-ms", type=int, default=80, help="Sleep between ticks per worker")
    p.add_argument("--rush-now", action="store_true", help="Fire morning-rush flash immediately")
    p.add_argument("--rush-at", default="", help="HH:MM Asia/Kolkata wall-clock for rush (e.g. 08:00)")
    p.add_argument("--rush-at-end", action="store_true", help="Also fire rush at end of soak")
    p.add_argument("--rush-n", type=int, default=40, help="Max contenders in rush flash")
    p.add_argument("--rush-slot", default="", help="Optional fixed HH:MM slot for rush")
    p.add_argument("--lock-proof-every", type=int, default=200, help="Steady ticks between lock proofs")
    p.add_argument("--lock-proof-n", type=int, default=12)
    p.add_argument("--report", default="soak-report.json")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--allow-non-test", action="store_true",
                   help="Allow project id without 'test' (dangerous)")
    return p


def main() -> int:
    args = build_parser().parse_args()
    key = (
        args.firebase_api_key
        or __import__("os").environ.get("SOAK_FIREBASE_API_KEY", "")
        or __import__("os").environ.get("FUNC_FIREBASE_API_KEY", "")
    )
    if not key:
        # try committed firebase web config for test-03
        cfg_path = _REPO / "infrastructure/firebase-web-configs/slot-sense-test-03.json"
        if cfg_path.is_file() and args.project == "slot-sense-test-03":
            key = json.loads(cfg_path.read_text()).get("apiKey", "")
    if not key:
        print("ERROR: --firebase-api-key or SOAK_FIREBASE_API_KEY required", file=sys.stderr)
        return 2
    args.firebase_api_key = key
    return asyncio.run(async_main(args))


if __name__ == "__main__":
    raise SystemExit(main())
