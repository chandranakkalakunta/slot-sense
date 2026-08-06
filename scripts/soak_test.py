#!/usr/bin/env python3
"""
Soak / load traffic against a SlotSense **test** environment (ADR-0045 / SLO-LOAD-TEST).

Uses seeded residents ({slug}.resident.N@example.com / ResidentPass143$) on
slot-sense-test-*. Discovers users via Firestore Admin; drives real HTTPS
book / cancel / availability traffic.

## Realistic mode (default)
  - **All tenants** participate
  - ~**10–15% of users per tenant** (capped) book/cancel so quota is spread
  - Cancel-aware mix keeps slots + daily quota recycling for multi-hour runs
  - Avoids the old trap: 3 tenants × 8 users → quota wall → only failed books

Scenarios:
  1. Steady multi-tenant book / cancel / availability / list
  2. Morning rush flash (--rush-now or --rush-at 08:00 Asia/Kolkata)
  3. Periodic lock proof (N parallel POSTs → ≤1 winner)
  4. Multi-day horizon scatter

Monitoring: docs/runbooks/soak-test.md · hold nightly env-power during long soaks.

Examples:
  # Realistic 2h soak (default mode)
  make soak-test DURATION=2h

  # Legacy narrow soak (few tenants, fixed users each)
  uv run python ../scripts/soak_test.py --mode legacy --tenant-pct 15 --users-per-tenant 8
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
    api_codes: collections.Counter = field(default_factory=collections.Counter)
    rush_winners: int = 0
    rush_contenders: int = 0
    lock_proof_ok: int = 0
    lock_proof_fail: int = 0
    lock_proof_inconclusive: int = 0
    lock_proof_double: int = 0
    active_tenants: set[str] = field(default_factory=set)
    bookings_created: int = 0
    bookings_cancelled: int = 0
    # Detailed contention outcomes (who won / double-book evidence)
    contention_events: list[dict[str, Any]] = field(default_factory=list)
    cloud_run_instances: list[dict[str, Any]] = field(default_factory=list)
    started_at: str = ""
    ended_at: str = ""

    latencies_all_ms: list[float] = field(default_factory=list)  # includes 401s
    token_refreshes: int = 0
    quota_bumps: dict[str, int] = field(default_factory=dict)

    def record(
        self,
        op: str,
        status: int,
        ms: float,
        tenant: str = "",
        api_code: str | None = None,
    ) -> None:
        self.ops[op] += 1
        self.status[status] += 1
        self.latencies_all_ms.append(ms)
        # Exclude pure 401s from SLO percentiles (expired-token noise)
        if status != 401:
            self.latencies_ms.append(ms)
        if tenant:
            self.active_tenants.add(tenant)
        if api_code:
            self.api_codes[api_code] += 1
        if status >= 400:
            key = f"{op}:{status}"
            if api_code:
                key = f"{op}:{status}:{api_code}"
            self.errors[key] += 1

    def summary(self) -> dict[str, Any]:
        lats = sorted(self.latencies_ms)
        lats_all = sorted(self.latencies_all_ms)

        def pct(series: list[float], p: float) -> float | None:
            if not series:
                return None
            i = min(len(series) - 1, max(0, int(round((p / 100) * (len(series) - 1)))))
            return round(series[i], 1)

        doubles = [e for e in self.contention_events if e.get("result") == "DOUBLE_BOOK"]
        passes = [e for e in self.contention_events if e.get("result") == "PASS"]
        inconclusive = [e for e in self.contention_events if e.get("result") == "INCONCLUSIVE"]
        inst_vals = [x["instances"] for x in self.cloud_run_instances if x.get("instances") is not None]

        return {
            "ops": dict(self.ops),
            "status": {str(k): v for k, v in self.status.items()},
            "api_codes": dict(self.api_codes.most_common(20)),
            "errors_top": dict(self.errors.most_common(20)),
            "latency_ms": {
                "note": "excludes HTTP 401 (AUTH_INVALID_TOKEN) from percentiles",
                "n": len(lats),
                "n_excluded_401": max(0, len(lats_all) - len(lats)),
                "p50": pct(lats, 50),
                "p95": pct(lats, 95),
                "p99": pct(lats, 99),
                "max": round(lats[-1], 1) if lats else None,
                "mean": round(statistics.fmean(lats), 1) if lats else None,
            },
            "latency_ms_including_401": {
                "n": len(lats_all),
                "p50": pct(lats_all, 50),
                "p95": pct(lats_all, 95),
                "p99": pct(lats_all, 99),
            },
            "active_tenants": sorted(self.active_tenants),
            "active_tenant_count": len(self.active_tenants),
            "bookings_created": self.bookings_created,
            "bookings_cancelled": self.bookings_cancelled,
            "rush": {
                "contenders": self.rush_contenders,
                "winners": self.rush_winners,
            },
            "token_refreshes": self.token_refreshes,
            "quota_bumps": self.quota_bumps,
            "lock_proof": {
                "ok": self.lock_proof_ok,
                "fail_double_book": self.lock_proof_double,
                "inconclusive": self.lock_proof_inconclusive,
                "fail_other": self.lock_proof_fail,
            },
            "contention": {
                "pass_count": len(passes),
                "double_book_count": len(doubles),
                "inconclusive_count": len(inconclusive),
                # Full detail: winner emails, booking_ids, slot keys
                "events": self.contention_events,
                "double_books": doubles,
            },
            "cloud_run": {
                "samples": self.cloud_run_instances,
                "min_instances": min(inst_vals) if inst_vals else None,
                "max_instances": max(inst_vals) if inst_vals else None,
            },
            "window": {"started_at": self.started_at, "ended_at": self.ended_at},
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


def _tenant_users_done(state_path: Path, slug: str) -> int:
    if not state_path.is_file():
        return 0
    try:
        st = json.loads(state_path.read_text())
        return int((st.get("tenants") or {}).get(slug, {}).get("users_done") or 0)
    except Exception:  # noqa: BLE001
        return 0


def sample_residents_from_firestore(
    project: str,
    slugs: list[str],
    per_tenant: int | dict[str, int],
    *,
    fetch_pool_factor: int = 8,
) -> dict[str, list[dict[str, str]]]:
    """Return {slug: [{email, uid, flat_number}, ...]} via Admin SDK.

    per_tenant: fixed int or map slug → target count.
    Fetches a larger pool then random-samples so long soaks don't always
    hit the same first N Firestore docs.
    """
    import firebase_admin
    from firebase_admin import credentials, firestore

    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.ApplicationDefault(), {"projectId": project})
    db = firestore.client()

    out: dict[str, list[dict[str, str]]] = {}
    for slug in slugs:
        want = per_tenant[slug] if isinstance(per_tenant, dict) else per_tenant
        want = max(1, int(want))
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

        pool_limit = min(max(want * fetch_pool_factor, want + 50), 2000)
        rows: list[dict[str, str]] = []
        q = (
            db.collection("tenants")
            .document(tid)
            .collection("users")
            .limit(pool_limit)
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
        random.shuffle(rows)
        out[slug] = rows[:want]
        log(
            f"sampled {len(out[slug])}/{want} residents for {slug} "
            f"(pool={len(rows)} tenant_id={tid})"
        )
    return out


def plan_realistic_actors(
    slugs: list[str],
    *,
    user_pct: float,
    max_users_per_tenant: int,
    min_users_per_tenant: int,
    max_total_actors: int,
    state_path: Path,
) -> dict[str, int]:
    """Per-tenant actor counts: ~user_pct of seeded users, capped for auth cost."""
    raw: dict[str, int] = {}
    for slug in slugs:
        n_users = _tenant_users_done(state_path, slug)
        if n_users <= 0:
            n_users = max_users_per_tenant * 10  # unknown size → use cap band
        target = int(round(n_users * (user_pct / 100.0)))
        target = max(min_users_per_tenant, target)
        target = min(max_users_per_tenant, target)
        raw[slug] = target
    total = sum(raw.values())
    if total > max_total_actors and total > 0:
        scale = max_total_actors / total
        raw = {
            s: max(min_users_per_tenant, int(round(n * scale)))
            for s, n in raw.items()
        }
        # trim if still over due to rounding
        while sum(raw.values()) > max_total_actors:
            s_max = max(raw, key=lambda k: raw[k])
            if raw[s_max] <= min_users_per_tenant:
                break
            raw[s_max] -= 1
    return raw


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


def ensure_adc(project: str) -> None:
    """Fail fast if Application Default Credentials need reauth (common on long laptop sessions)."""
    log("ADC preflight (Firestore / gcloud application-default)…")
    try:
        import google.auth
        from google.auth.transport.requests import Request
        from google.cloud import firestore as gcf

        creds, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        if not creds.valid:
            creds.refresh(Request())
        # Cheap live call — surfaces invalid_rapt / reauth clearly
        db = gcf.Client(project=project, credentials=creds)
        list(db.collection("tenants").limit(1).stream())
        log("ADC preflight OK")
    except Exception as exc:  # noqa: BLE001
        log("FATAL: Google Application Default Credentials failed.")
        log(f"  last error: {type(exc).__name__}: {exc}")
        log("  Re-authenticate, then re-run soak:")
        log("    gcloud auth login")
        log("    gcloud auth application-default login")
        log(f"    gcloud config set project {project}")
        log("  (ADC is required for Firestore user sampling + quota bump.)")
        raise SystemExit(2) from exc


def bump_tenant_booking_quota(
    project: str,
    slugs: list[str],
    *,
    max_slots: int,
    state_path: Path,
) -> dict[str, int]:
    """Temporarily raise max_slots_per_user_per_sport_per_day on active tenants (test soak)."""
    import firebase_admin
    from firebase_admin import credentials, firestore

    if not firebase_admin._apps:
        firebase_admin.initialize_app(
            credentials.ApplicationDefault(), {"projectId": project}
        )
    db = firestore.client()
    state = {}
    if state_path.is_file():
        try:
            state = json.loads(state_path.read_text())
        except Exception:  # noqa: BLE001
            state = {}
    bumped: dict[str, int] = {}
    for slug in slugs:
        tid = (state.get("tenants") or {}).get(slug, {}).get("tenant_id")
        if not tid:
            for doc in db.collection("tenants").where("slug", "==", slug).limit(1).stream():
                tid = doc.id
                break
        if not tid:
            log(f"WARN: quota bump skip {slug} (no tenant_id)")
            continue
        ref = db.collection("tenants").document(tid)
        snap = ref.get()
        data = snap.to_dict() or {} if snap.exists else {}
        policies = dict(data.get("policies") or {})
        old = policies.get("max_slots_per_user_per_sport_per_day")
        policies["max_slots_per_user_per_sport_per_day"] = int(max_slots)
        ref.set({"policies": policies}, merge=True)
        bumped[slug] = int(max_slots)
        log(f"quota bump {slug}: max_slots_per_user_per_sport_per_day {old} → {max_slots}")
    return bumped


async def refresh_actor_token(
    client: httpx.AsyncClient,
    actor: Actor,
    *,
    api_key: str,
    password: str,
    metrics: Metrics,
) -> bool:
    tok = await firebase_id_token(client, api_key, actor.email, password)
    if not tok:
        metrics.errors["token_refresh_fail"] += 1
        return False
    actor.token = tok
    actor.token_issued_at = time.time()
    metrics.token_refreshes += 1
    return True


async def ensure_fresh_token(
    client: httpx.AsyncClient,
    actor: Actor,
    *,
    api_key: str,
    password: str,
    metrics: Metrics,
    max_age_s: float,
) -> None:
    age = time.time() - (actor.token_issued_at or 0)
    if age < max_age_s and actor.token:
        return
    ok = await refresh_actor_token(
        client, actor, api_key=api_key, password=password, metrics=metrics
    )
    if ok:
        log(f"token refresh ok {actor.email} (age was {age/60:.0f}m)")
    else:
        log(f"WARN token refresh failed {actor.email}")


def _api_code(body: Any) -> str | None:
    if not isinstance(body, dict):
        return None
    if body.get("code"):
        return str(body["code"])
    err = body.get("error")
    if isinstance(err, dict) and err.get("code"):
        return str(err["code"])
    return None


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
        try:
            body = r.json()
        except Exception:
            body = None
        metrics.record(op, r.status_code, ms, tenant, api_code=_api_code(body))
        return r.status_code, body
    except Exception as exc:  # noqa: BLE001
        ms = (time.perf_counter() - t0) * 1000
        metrics.record(op, 0, ms, tenant)
        metrics.errors[f"{op}:exc:{type(exc).__name__}"] += 1
        return 0, None


async def sample_cloud_run_instances(project: str, region: str = "asia-south1") -> int | None:
    """Best-effort instance count via Cloud Monitoring REST (last ~5 min max)."""
    del region  # reserved for future revision-scoped queries
    try:
        proc2 = await asyncio.create_subprocess_exec(
            "gcloud", "auth", "print-access-token",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await proc2.communicate()
        token = out.decode().strip()
        if not token:
            return None
        import urllib.parse
        import urllib.request
        from datetime import timezone as _tz

        end = datetime.now(_tz.utc)
        start = end - timedelta(minutes=5)
        filt = (
            'metric.type="run.googleapis.com/container/instance_count" '
            'AND resource.type="cloud_run_revision" '
            'AND resource.labels.service_name="sport-slot-api"'
        )
        q = urllib.parse.urlencode({
            "filter": filt,
            "interval.endTime": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "interval.startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "aggregation.alignmentPeriod": "60s",
            "aggregation.perSeriesAligner": "ALIGN_MAX",
            "aggregation.crossSeriesReducer": "REDUCE_SUM",
            "view": "FULL",
        })
        url = f"https://monitoring.googleapis.com/v3/projects/{project}/timeSeries?{q}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})

        def _fetch() -> int | None:
            with urllib.request.urlopen(req, timeout=20) as r:
                d = json.load(r)
            best = 0
            found = False
            for ts in d.get("timeSeries") or []:
                for p in ts.get("points") or []:
                    found = True
                    v = p.get("value", {})
                    val = v.get("int64Value")
                    if val is None:
                        val = v.get("doubleValue") or 0
                    best = max(best, int(float(val)))
            return best if found else None

        return await asyncio.to_thread(_fetch)
    except Exception:  # noqa: BLE001
        return None


# ── actors ────────────────────────────────────────────────────────────────


@dataclass
class Actor:
    slug: str
    email: str
    token: str
    origin: str
    facility_ids: list[str] = field(default_factory=list)
    my_bookings: list[str] = field(default_factory=list)
    # Track confirmed opens we created (for cancel preference / quota hygiene)
    open_count: int = 0
    token_issued_at: float = 0.0  # time.time() when token was minted


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
    *,
    realistic: bool = True,
    api_key: str = "",
    password: str = DEFAULT_PASSWORD,
    token_max_age_s: float = 45 * 60,
) -> None:
    """One unit of mixed real-world traffic for a resident.

    Realistic mode: bias toward cancel when the actor already holds opens so
    daily quota (max_slots_per_user_per_sport_per_day) and facility slots
    recycle — long soaks stay bookable instead of dying on 409 QUOTA.
    """
    if api_key:
        await ensure_fresh_token(
            client, actor,
            api_key=api_key, password=password, metrics=metrics,
            max_age_s=token_max_age_s,
        )
    if not actor.facility_ids:
        await discover_facilities(client, metrics, actor)
        if not actor.facility_ids:
            return

    fid = rng.choice(actor.facility_ids)
    has_open = bool(actor.my_bookings) or actor.open_count > 0

    if realistic:
        # Sustainable mix: cancel when holding bookings; book when free.
        # ~30% availability, ~25% book, ~25% cancel, ~15% list, ~5% facilities
        if has_open and rng.random() < 0.45:
            action = "cancel"
        else:
            r = rng.random()
            if r < 0.32:
                action = "availability"
            elif r < 0.58:
                action = "book"
            elif r < 0.78:
                action = "cancel" if has_open else "book"
            elif r < 0.93:
                action = "list_mine"
            else:
                action = "facilities"
    else:
        # Legacy fixed mix
        r = rng.random()
        if r < 0.40:
            action = "availability"
        elif r < 0.65:
            action = "book"
        elif r < 0.80:
            action = "list_mine"
        elif r < 0.95:
            action = "cancel"
        else:
            action = "facilities"

    if action == "availability":
        day = date.today() + timedelta(days=rng.randint(0, 6))
        await pick_bookable_slot(client, metrics, actor, fid, day)
    elif action == "book":
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
                actor.open_count += 1
                metrics.bookings_created += 1
        elif code == 409:
            # Quota wall — force cancel preference next ticks
            actor.open_count = max(actor.open_count, 1)
    elif action == "list_mine":
        await api(
            client, metrics,
            origin=actor.origin, method="GET", path="/api/v1/bookings/mine",
            token=actor.token, op="list_mine", tenant=actor.slug,
        )
    elif action == "cancel":
        if not actor.my_bookings:
            # Discover own bookings from API so we can recycle quota
            code, body = await api(
                client, metrics,
                origin=actor.origin, method="GET", path="/api/v1/bookings/mine",
                token=actor.token, op="list_mine", tenant=actor.slug,
            )
            if code == 200 and isinstance(body, dict):
                for b in body.get("items") or []:
                    if isinstance(b, dict) and b.get("status") == "confirmed":
                        bid = b.get("id") or b.get("booking_id")
                        if bid and bid not in actor.my_bookings:
                            actor.my_bookings.append(bid)
                actor.open_count = len(actor.my_bookings)
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
            actor.open_count = max(0, actor.open_count - 1)
        else:
            # put back if cancel failed (already cancelled elsewhere)
            pass
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


# Serialize lock-proof waves so 12 workers don't stampede the same slot.
_LOCK_PROOF_GATE = asyncio.Lock()


async def lock_proof_wave(
    client: httpx.AsyncClient,
    metrics: Metrics,
    actors: list[Actor],
    n: int = 12,
) -> None:
    """Classic N-parallel one-slot proof on one tenant.

    Records who won (email + booking_id + slot). Classifies:
      PASS          — exactly one 201
      DOUBLE_BOOK   — two or more 201s for the same facility/date/start
      INCONCLUSIVE  — zero 201s (usually all 422: slot already taken by steady traffic)
    """
    if len(actors) < 2:
        return
    if _LOCK_PROOF_GATE.locked():
        return  # another wave in flight
    async with _LOCK_PROOF_GATE:
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
        slot_key = f"{slug}/{fid}/{day.isoformat()}/{start}"
        body = {"facility_id": fid, "date": day.isoformat(), "start": start}
        expected_booking_id = f"{fid}_{day.isoformat()}_{start}"

        async def post(a: Actor) -> dict[str, Any]:
            # Do NOT cancel here — cancel-after-wave only. Mid-race cancel
            # frees the slot so a second contender gets 201 on the same
            # booking_id (re-book after cancel), which is a false DOUBLE_BOOK.
            code, resp = await api(
                client, metrics,
                origin=a.origin, method="POST", path="/api/v1/bookings",
                token=a.token, op="lock_proof", tenant=a.slug,
                json_body=body,
            )
            bid = None
            api_code = _api_code(resp)
            if code == 201 and isinstance(resp, dict):
                bid = resp.get("id") or resp.get("booking_id")
            return {
                "email": a.email,
                "status": code,
                "api_code": api_code,
                "booking_id": bid,
            }

        results = await asyncio.gather(*[post(a) for a in group])
        winners = [r for r in results if r["status"] == 201]
        codes = collections.Counter(r["status"] for r in results)
        api_codes = collections.Counter(
            r["api_code"] or f"HTTP_{r['status']}" for r in results
        )
        ts = datetime.now(TZ).isoformat()

        if len(winners) == 1:
            metrics.lock_proof_ok += 1
            result = "PASS"
            log(
                f"lock_proof PASS tenant={slug} slot={slot_key} "
                f"winner={winners[0]['email']} booking_id={winners[0]['booking_id']} "
                f"n={len(group)} losers={dict(codes)}"
            )
        elif len(winners) == 0:
            metrics.lock_proof_inconclusive += 1
            result = "INCONCLUSIVE"
            log(
                f"lock_proof INCONCLUSIVE tenant={slug} slot={slot_key} "
                f"winners=0 n={len(group)} statuses={dict(codes)} "
                f"api_codes={dict(api_codes)} (slot likely taken by steady traffic)"
            )
        else:
            metrics.lock_proof_double += 1
            result = "DOUBLE_BOOK"
            log(
                f"lock_proof DOUBLE_BOOK tenant={slug} slot={slot_key} "
                f"winners={len(winners)} expected_id={expected_booking_id} "
                f"winner_emails={[w['email'] for w in winners]} "
                f"booking_ids={[w['booking_id'] for w in winners]}"
            )

        # Cleanup: cancel only AFTER the race is scored (one cancel per booking_id)
        cancelled_ids: set[str] = set()
        for w in winners:
            bid = w.get("booking_id")
            if not bid or bid in cancelled_ids:
                continue
            # Use the winner's token that created it
            actor = next((a for a in group if a.email == w["email"]), None)
            if actor is None:
                continue
            c_code, _ = await api(
                client, metrics,
                origin=actor.origin, method="POST",
                path=f"/api/v1/bookings/{bid}/cancel",
                token=actor.token, op="lock_proof_cancel", tenant=actor.slug,
            )
            if c_code in (200, 204):
                metrics.bookings_cancelled += 1
                cancelled_ids.add(bid)

        metrics.contention_events.append({
            "kind": "lock_proof",
            "ts": ts,
            "result": result,
            "tenant": slug,
            "facility_id": fid,
            "date": day.isoformat(),
            "start": start,
            "slot_key": slot_key,
            "expected_booking_id": expected_booking_id,
            "n_contenders": len(group),
            "status_counts": dict(codes),
            "api_code_counts": dict(api_codes),
            "winners": winners,
            "all_results": results,
            "note": (
                "Cancel runs only after wave scoring. Two 201s for same "
                "booking_id with this ordering is a real product race."
            ),
        })


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

    # Fail before multi-hour work if laptop ADC is stale (invalid_rapt / reauth)
    ensure_adc(args.project)

    duration_s = parse_duration(args.duration)
    all_slugs = load_tenant_slugs(Path(args.state_file))
    state_path = Path(args.state_file)
    realistic = args.mode == "realistic"
    token_max_age_s = float(args.token_refresh_minutes) * 60.0

    if realistic:
        active_slugs = list(all_slugs)  # all tenants
        per_map = plan_realistic_actors(
            active_slugs,
            user_pct=args.user_pct,
            max_users_per_tenant=args.max_users_per_tenant,
            min_users_per_tenant=args.min_users_per_tenant,
            max_total_actors=args.max_total_actors,
            state_path=state_path,
        )
        log(
            f"mode=realistic project={args.project} "
            f"tenants={len(active_slugs)}/{len(all_slugs)} "
            f"user_pct≈{args.user_pct}% cap/tenant={args.max_users_per_tenant} "
            f"planned_actors={sum(per_map.values())} "
            f"duration={args.duration} workers={args.workers}"
        )
        log(
            "per-tenant actors: "
            + ", ".join(f"{s}={per_map[s]}" for s in sorted(per_map))
        )
    else:
        n_tenants = max(1, int(round(len(all_slugs) * (args.tenant_pct / 100.0))))
        n_tenants = max(n_tenants, args.min_tenants)
        n_tenants = min(n_tenants, len(all_slugs))
        active_slugs = (
            random.sample(all_slugs, n_tenants)
            if len(all_slugs) > n_tenants
            else all_slugs
        )
        per_map = {s: args.users_per_tenant for s in active_slugs}
        pct = 100.0 * len(active_slugs) / max(1, len(all_slugs))
        log(
            f"mode=legacy project={args.project} "
            f"tenants_active={len(active_slugs)}/{len(all_slugs)} ({pct:.0f}%) "
            f"users_per_tenant={args.users_per_tenant} "
            f"duration={args.duration} workers={args.workers}"
        )

    log(f"active tenants: {', '.join(sorted(active_slugs))}")
    log("TIP: hold nightly disable → make env-hold ENV=test-03 DAYS=1 REASON=soak")
    log("TIP: open SlotSense Ops dashboard + Cloud Run metrics for this project")

    metrics = Metrics()
    metrics.started_at = datetime.now(TZ).isoformat()
    password = args.password
    api_key = args.firebase_api_key

    # Temporary soak quota headroom (seed default is often 2)
    if args.soak_quota_slots > 0:
        log(f"raising booking quota to {args.soak_quota_slots} slots/user/sport/day…")
        metrics.quota_bumps = bump_tenant_booking_quota(
            args.project,
            active_slugs,
            max_slots=args.soak_quota_slots,
            state_path=state_path,
        )

    log("sampling residents from Firestore (ADC)…")
    samples = sample_residents_from_firestore(
        args.project, active_slugs, per_tenant=per_map
    )
    if not samples:
        log("ERROR: no residents sampled — is seed complete and ADC authed?")
        return 1

    actors: list[Actor] = []
    async with httpx.AsyncClient(timeout=45.0, follow_redirects=True) as client:
        # Auth pool (bounded concurrency — Identity Toolkit rate limits)
        log("signing in residents (fresh tokens for this soak)…")
        auth_sem = asyncio.Semaphore(max(4, args.auth_concurrency))

        async def _auth_one(slug: str, row: dict[str, str], origin: str) -> Actor | None:
            async with auth_sem:
                tok = await firebase_id_token(
                    client, api_key, row["email"], password
                )
            if not tok:
                metrics.errors["auth_fail"] += 1
                return None
            return Actor(
                slug=slug,
                email=row["email"],
                token=tok,
                origin=origin,
                token_issued_at=time.time(),
            )

        auth_jobs = []
        for slug, rows in samples.items():
            origin = f"https://{slug}.{args.base_domain}"
            for row in rows:
                auth_jobs.append(_auth_one(slug, row, origin))
        auth_results = await asyncio.gather(*auth_jobs)
        actors = [a for a in auth_results if a is not None]
        log(
            f"authenticated actors={len(actors)} "
            f"auth_fail={metrics.errors.get('auth_fail', 0)} "
            f"(planned≈{sum(per_map.values())})"
        )
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
        last_instance_sample = 0.0
        log(f"steady traffic for {args.duration} (workers={args.workers})…")

        async def sample_instances_loop() -> None:
            nonlocal last_instance_sample
            while time.monotonic() < end:
                n = await sample_cloud_run_instances(args.project)
                metrics.cloud_run_instances.append({
                    "ts": datetime.now(TZ).isoformat(),
                    "instances": n,
                })
                if n is not None:
                    log(f"cloud_run instances≈{n}")
                await asyncio.sleep(60)

        async def worker(wid: int) -> None:
            nonlocal tick
            local = random.Random(args.seed + wid * 997)
            while time.monotonic() < end:
                actor = local.choice(actors)
                await steady_tick(
                    client, metrics, actor, local,
                    realistic=realistic,
                    api_key=api_key,
                    password=password,
                    token_max_age_s=token_max_age_s,
                )
                tick += 1
                await asyncio.sleep(args.pace_ms / 1000.0)
                if tick % 50 == 0 and wid == 0:
                    s = metrics.summary()
                    log(
                        f"progress ops={s['latency_ms']['n']} "
                        f"(excl401 n={s['latency_ms'].get('n_excluded_401', 0)}) "
                        f"p50={s['latency_ms']['p50']}ms "
                        f"p95={s['latency_ms']['p95']}ms "
                        f"p99={s['latency_ms']['p99']}ms "
                        f"tenants={s['active_tenant_count']} "
                        f"created={s['bookings_created']} cancelled={s['bookings_cancelled']} "
                        f"5xx={sum(v for k,v in metrics.status.items() if k >= 500)} "
                        f"401={metrics.status.get(401, 0)} "
                        f"refresh={metrics.token_refreshes} "
                        f"double={metrics.lock_proof_double} "
                        f"lock_ok={metrics.lock_proof_ok}"
                    )
                # Only worker 0 triggers lock proof (avoids 12 parallel waves)
                if wid == 0 and tick > 0 and tick % args.lock_proof_every == 0:
                    # Refresh a subset before lock proof so contention isn't 401 noise
                    for a in actors[: args.lock_proof_n + 4]:
                        await ensure_fresh_token(
                            client, a,
                            api_key=api_key, password=password, metrics=metrics,
                            max_age_s=token_max_age_s,
                        )
                    await lock_proof_wave(client, metrics, actors, n=args.lock_proof_n)

        async def proactive_token_refresh_loop() -> None:
            """Refresh all actor tokens every token_max_age_s / 2 (belt + suspenders)."""
            interval = max(60.0, token_max_age_s / 2)
            while time.monotonic() < end:
                await asyncio.sleep(interval)
                log(f"proactive token refresh wave ({len(actors)} actors)…")
                sem = asyncio.Semaphore(max(4, args.auth_concurrency))

                async def _one(a: Actor) -> None:
                    async with sem:
                        await refresh_actor_token(
                            client, a,
                            api_key=api_key, password=password, metrics=metrics,
                        )

                await asyncio.gather(*[_one(a) for a in actors])
                log(f"proactive refresh done total_refreshes={metrics.token_refreshes}")

        await asyncio.gather(
            sample_instances_loop(),
            proactive_token_refresh_loop(),
            *[worker(i) for i in range(args.workers)],
        )

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

    metrics.ended_at = datetime.now(TZ).isoformat()
    # Final instance sample
    n_final = await sample_cloud_run_instances(args.project)
    metrics.cloud_run_instances.append({
        "ts": metrics.ended_at,
        "instances": n_final,
    })

    summary = metrics.summary()
    summary["config"] = {
        "project": args.project,
        "base_domain": args.base_domain,
        "mode": args.mode,
        "duration": args.duration,
        "tenant_pct_target": 100.0 if realistic else args.tenant_pct,
        "user_pct": args.user_pct if realistic else None,
        "max_users_per_tenant": args.max_users_per_tenant if realistic else args.users_per_tenant,
        "tenants_selected": sorted(active_slugs),
        "actors_planned": sum(per_map.values()),
        "actors": len(actors),
        "workers": args.workers,
        "rush_now": args.rush_now,
        "rush_at": args.rush_at,
        "token_refresh_minutes": args.token_refresh_minutes,
        "soak_quota_slots": args.soak_quota_slots,
    }
    report_path = Path(args.report)
    report_path.write_text(json.dumps(summary, indent=2) + "\n")
    log(f"report → {report_path}")
    print(json.dumps(summary, indent=2))

    # Exit code: fail if tenant coverage short or lock proof always failed
    actual_pct = 100.0 * summary["active_tenant_count"] / max(1, len(all_slugs))
    target_pct = 100.0 if realistic else args.tenant_pct
    if actual_pct + 0.5 < target_pct * 0.5:
        log(f"FAIL: tenant coverage {actual_pct:.0f}% << target {target_pct}%")
        return 1
    if metrics.lock_proof_double > 0:
        log(
            f"FAIL: double-book detected {metrics.lock_proof_double} time(s) — "
            f"see contention.double_books in report"
        )
        return 1
    if metrics.lock_proof_ok == 0 and metrics.lock_proof_inconclusive >= 2:
        log("FAIL: lock proof never got a clean single winner")
        return 1
    log(
        f"DONE coverage={actual_pct:.0f}% p95={summary['latency_ms']['p95']}ms "
        f"created={summary['bookings_created']} cancelled={summary['bookings_cancelled']} "
        f"lock_ok={metrics.lock_proof_ok} double={metrics.lock_proof_double} "
        f"inconclusive={metrics.lock_proof_inconclusive} "
        f"cloud_run_max={summary['cloud_run']['max_instances']}"
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
    p.add_argument(
        "--mode",
        choices=("realistic", "legacy"),
        default="realistic",
        help="realistic=all tenants + ~user_pct users + cancel recycle (default); "
             "legacy=tenant-pct + fixed users-per-tenant",
    )
    p.add_argument("--tenant-pct", type=float, default=15.0,
                   help="[legacy] %% of seeded tenants (default 15)")
    p.add_argument("--min-tenants", type=int, default=3)
    p.add_argument("--users-per-tenant", type=int, default=8,
                   help="[legacy] Residents per active tenant")
    p.add_argument("--user-pct", type=float, default=12.0,
                   help="[realistic] %% of each tenant's seeded users (default 12, aim 10–15)")
    p.add_argument("--max-users-per-tenant", type=int, default=40,
                   help="[realistic] Cap actors per tenant after user-pct (default 40)")
    p.add_argument("--min-users-per-tenant", type=int, default=5,
                   help="[realistic] Floor actors per tenant (default 5)")
    p.add_argument("--max-total-actors", type=int, default=500,
                   help="[realistic] Global cap after per-tenant plan (default 500)")
    p.add_argument("--auth-concurrency", type=int, default=16,
                   help="Parallel Firebase sign-ins (default 16)")
    p.add_argument(
        "--token-refresh-minutes",
        type=float,
        default=45.0,
        help="Re-sign-in Firebase ID token after this many minutes (default 45; Firebase ~60m TTL)",
    )
    p.add_argument(
        "--soak-quota-slots",
        type=int,
        default=10,
        help="Temporarily set max_slots_per_user_per_sport_per_day on active tenants "
             "(default 10 for soak; 0 = do not change policies)",
    )
    p.add_argument("--workers", type=int, default=24, help="Concurrent steady-state workers")
    p.add_argument("--pace-ms", type=int, default=80, help="Sleep between ticks per worker")
    p.add_argument("--rush-now", action="store_true", help="Fire morning-rush flash immediately")
    p.add_argument("--rush-at", default="", help="HH:MM Asia/Kolkata wall-clock for rush (e.g. 08:00)")
    p.add_argument("--rush-at-end", action="store_true", help="Also fire rush at end of soak")
    p.add_argument("--rush-n", type=int, default=80, help="Max contenders in rush flash")
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
