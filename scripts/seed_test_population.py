#!/usr/bin/env python3
"""Seed test env with multi-tenant population for load/perf (Coordinator-run).

Creates/ensures 20 tenants (including marina-skies + rvrg), random flats
(250–2000) and members (2–6), emails {slug}.resident.{n}@example.com,
password ResidentPass143$ (must_change_password=false). Facilities scaled
by tenant size from facility_catalog (recreated). Resumable state file.

Uses Firebase Admin + Firestore (bulk-import *semantics* at scale; product
HTTP bulk is 500/req and too slow for 10k–200k users). Does NOT enqueue
welcome emails.

Usage (from repo root, ADC with Firebase Admin on target project):

  cd backend && uv run python ../scripts/seed_test_population.py \\
    --project slot-sense-test-03

  # Smoke first:
  uv run python ../scripts/seed_test_population.py --project slot-sense-test-03 \\
    --max-users-per-tenant 50 --dry-run

  # Resume after interrupt:
  uv run python ../scripts/seed_test_population.py --project slot-sense-test-03
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

# backend/src on path
_REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_REPO / "backend" / "src"))

import firebase_admin
import firebase_admin.auth as fb_auth
from google.cloud import firestore

# ─── Constants ──────────────────────────────────────────────────────────

DEFAULT_PASSWORD = "ResidentPass143$"  # nosec B105 — intentional shared seed password
EMAIL_DOMAIN = "example.com"
STATE_FILE = _REPO / f".seed-test-population-state.json"

# 20 tenants: existing first, then invented communities
TENANTS: list[tuple[str, str]] = [
    ("marina-skies", "Marina Skies Residency"),
    ("rvrg", "RVR Gardens"),
    ("green-valley", "Green Valley Township"),
    ("lakeview-heights", "Lakeview Heights"),
    ("orchid-park", "Orchid Park Residences"),
    ("sunset-boulevard", "Sunset Boulevard Homes"),
    ("riverfront-plaza", "Riverfront Plaza"),
    ("cedar-grove", "Cedar Grove Community"),
    ("maple-residency", "Maple Residency"),
    ("azure-bay", "Azure Bay Apartments"),
    ("harmony-enclave", "Harmony Enclave"),
    ("prestige-oaks", "Prestige Oaks"),
    ("silver-oak-estate", "Silver Oak Estate"),
    ("palm-meadows", "Palm Meadows"),
    ("skyline-towers", "Skyline Towers"),
    ("garden-city-homes", "Garden City Homes"),
    ("royal-courtyard", "Royal Courtyard"),
    ("emerald-hills", "Emerald Hills Township"),
    ("nimbus-park", "Nimbus Park"),
    ("lakeside-commons", "Lakeside Commons"),
]

WEEKDAYS = (
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
)

DEFAULT_SCHEDULE = {
    day: [
        {"start": "06:00", "end": "10:00"},
        {"start": "16:00", "end": "21:00"},
    ]
    for day in WEEKDAYS
}

# Fallback catalog if project has none
FALLBACK_CATALOG = [
    {"type_id": "badminton", "name": "Badminton Court", "sport": "badminton"},
    {"type_id": "tennis", "name": "Tennis Court", "sport": "tennis"},
    {"type_id": "table-tennis", "name": "Table Tennis", "sport": "table-tennis"},
    {"type_id": "swimming", "name": "Swimming Pool Lane", "sport": "swimming"},
    {"type_id": "gym", "name": "Gym Slot", "sport": "fitness"},
]


@dataclass
class TenantPlan:
    slug: str
    display_name: str
    tenant_id: str
    n_flats: int
    members_per_flat: list[int]  # length n_flats
    facilities_per_type: int
    users_done: int = 0
    facilities_done: bool = False
    complete: bool = False


# ─── Helpers ────────────────────────────────────────────────────────────


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_state(path: Path) -> dict:
    if path.is_file():
        return json.loads(path.read_text())
    return {
        "version": 1,
        "global_counter": 1,
        "tenants": {},
        "password": DEFAULT_PASSWORD,
        "updated_at": None,
    }


def _save_state(path: Path, state: dict) -> None:
    state["updated_at"] = _now()
    path.write_text(json.dumps(state, indent=2) + "\n")


def _tier_facilities_per_type(n_flats: int) -> int:
    if n_flats < 500:
        return 1
    if n_flats < 1200:
        return 2
    return 3


def _ensure_app(project: str) -> firestore.Client:
    if not firebase_admin._apps:
        firebase_admin.initialize_app(options={"projectId": project})
    return firestore.Client(project=project)


def _ensure_catalog(db: firestore.Client, dry_run: bool) -> list[dict]:
    col = db.collection("facility_catalog")
    items = [d.to_dict() or {} for d in col.stream()]
    items = [x for x in items if x.get("type_id")]
    if items:
        return items
    print("[seed] facility_catalog empty — seeding fallback types")
    if dry_run:
        return list(FALLBACK_CATALOG)
    for doc in FALLBACK_CATALOG:
        col.document(doc["type_id"]).set(doc)
    return list(FALLBACK_CATALOG)


def _ensure_tenant(
    db: firestore.Client, slug: str, display_name: str, dry_run: bool
) -> str:
    snaps = list(
        db.collection("tenants").where("slug", "==", slug).limit(1).stream()
    )
    if snaps:
        tid = snaps[0].id
        print(f"[seed] tenant exists slug={slug} id={tid}")
        return tid
    tid = f"t-{uuid.uuid4().hex[:12]}"
    print(f"[seed] create tenant slug={slug} id={tid}")
    if dry_run:
        return tid
    db.collection("tenants").document(tid).set(
        {
            "tenant_id": tid,
            "slug": slug,
            "display_name": display_name,
            "status": "active",
            "timezone": "Asia/Kolkata",
            "policies": {
                "booking_horizon_days": 7,
                "booking_window_open_time": "06:00",
                "cancellation_buffer_hours": 2,
                "max_slots_per_user_per_sport_per_day": 2,
            },
            "created_at": datetime.now(timezone.utc),
            "created_by": "seed_test_population",
        }
    )
    return tid


def _delete_facilities(db: firestore.Client, tenant_id: str, dry_run: bool) -> int:
    col = db.collection("tenants").document(tenant_id).collection("facilities")
    snaps = list(col.stream())
    print(f"[seed] recreate facilities: deleting {len(snaps)} existing")
    if dry_run:
        return len(snaps)
    for s in snaps:
        s.reference.delete()
    return len(snaps)


def _create_facilities(
    db: firestore.Client,
    tenant_id: str,
    catalog: list[dict],
    per_type: int,
    dry_run: bool,
) -> int:
    created = 0
    fac_col = db.collection("tenants").document(tenant_id).collection("facilities")
    for cat in catalog:
        tid = cat["type_id"]
        base_name = cat.get("name") or tid
        for i in range(1, per_type + 1):
            fid = uuid.uuid4().hex[:12]
            name = f"{base_name} - {i}" if per_type > 1 else base_name
            doc = {
                "id": fid,
                "facility_type_id": tid,
                "sport": cat.get("sport") or tid,
                "name": name,
                "weekly_schedule": DEFAULT_SCHEDULE,
                "slot_duration_minutes": 60,
                "description": "Seeded for load testing",
                "price_paise": 0,
                "active": True,
            }
            print(f"  facility {name} ({fid})")
            if not dry_run:
                fac_col.document(fid).set(doc)
            created += 1
    return created


def _create_resident(
    db: firestore.Client,
    *,
    tenant_id: str,
    tenant_slug: str,
    email: str,
    display_name: str,
    flat_number: str,
    password: str,
    dry_run: bool,
) -> str | None:
    """Create Auth user + profile with final password (no temp / no welcome)."""
    if dry_run:
        return "dry-run-uid"
    hid = f"h-{flat_number}"
    try:
        user = fb_auth.create_user(
            email=email,
            password=password,
            display_name=display_name,
            email_verified=True,
        )
    except fb_auth.EmailAlreadyExistsError:
        user = fb_auth.get_user_by_email(email)
        fb_auth.update_user(user.uid, password=password, disabled=False)
        # refresh claims/profile below

    fb_auth.set_custom_user_claims(
        user.uid,
        {
            "tenant_id": tenant_id,
            "tenant_slug": tenant_slug,
            "role": "resident",
            "household_id": hid,
        },
    )
    db.collection("tenants").document(tenant_id).collection("users").document(
        user.uid
    ).set(
        {
            "uid": user.uid,
            "email": email,
            "display_name": display_name,
            "flat_number": flat_number,
            "household_id": hid,
            "role": "resident",
            "must_change_password": False,
            "temp_password_expires_at": None,
            "seeded": True,
            "created_at": datetime.now(timezone.utc),
        },
        merge=True,
    )
    return user.uid


def _plan_tenant(slug: str, display_name: str, tenant_id: str, rng: random.Random) -> TenantPlan:
    n_flats = rng.randint(250, 2000)
    members = [rng.randint(2, 6) for _ in range(n_flats)]
    return TenantPlan(
        slug=slug,
        display_name=display_name,
        tenant_id=tenant_id,
        n_flats=n_flats,
        members_per_flat=members,
        facilities_per_type=_tier_facilities_per_type(n_flats),
    )


def _total_users(plan: TenantPlan) -> int:
    return sum(plan.members_per_flat)


# ─── Main ───────────────────────────────────────────────────────────────


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--project", required=True, help="GCP project id (e.g. slot-sense-test-03)")
    p.add_argument("--password", default=DEFAULT_PASSWORD, help="Shared resident password")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--skip-facilities", action="store_true")
    p.add_argument("--skip-users", action="store_true")
    p.add_argument(
        "--recreate-facilities",
        action="store_true",
        default=True,
        help="Delete and recreate facilities (default: on)",
    )
    p.add_argument(
        "--keep-facilities",
        action="store_true",
        help="Do not delete existing facilities",
    )
    p.add_argument(
        "--max-users-per-tenant",
        type=int,
        default=0,
        help="Cap residents per tenant (0 = full plan). Use for smoke.",
    )
    p.add_argument(
        "--max-flats",
        type=int,
        default=0,
        help="Override flat count upper cap for smoke (0 = use random 250-2000)",
    )
    p.add_argument("--state-file", type=Path, default=STATE_FILE)
    p.add_argument("--seed", type=int, default=42, help="RNG seed for reproducibility")
    p.add_argument(
        "--set-min-instances",
        type=int,
        default=1,
        help="gcloud run update min instances after seed (0=skip)",
    )
    p.add_argument("--region", default="asia-south1")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    rng = random.Random(args.seed)
    state = _load_state(args.state_file)
    state["password"] = args.password
    state["project"] = args.project

    print(f"[seed] project={args.project} dry_run={args.dry_run} state={args.state_file}")
    print(f"[seed] password set for all seed residents (must_change_password=false)")

    db = _ensure_app(args.project)
    catalog = _ensure_catalog(db, args.dry_run)
    print(f"[seed] catalog types: {len(catalog)}")

    recreate_fac = args.recreate_facilities and not args.keep_facilities

    # Build / restore plans
    plans: list[TenantPlan] = []
    for slug, name in TENANTS:
        tstate = state["tenants"].get(slug) or {}
        if tstate.get("tenant_id") and tstate.get("n_flats"):
            plan = TenantPlan(
                slug=slug,
                display_name=name,
                tenant_id=tstate["tenant_id"],
                n_flats=tstate["n_flats"],
                members_per_flat=tstate.get("members_per_flat")
                or [2] * tstate["n_flats"],
                facilities_per_type=tstate.get("facilities_per_type")
                or _tier_facilities_per_type(tstate["n_flats"]),
                users_done=tstate.get("users_done", 0),
                facilities_done=tstate.get("facilities_done", False),
                complete=tstate.get("complete", False),
            )
            # ensure tenant still exists / create
            plan.tenant_id = _ensure_tenant(db, slug, name, args.dry_run)
        else:
            tid = _ensure_tenant(db, slug, name, args.dry_run)
            plan = _plan_tenant(slug, name, tid, rng)
            if args.max_flats > 0:
                plan.n_flats = min(plan.n_flats, args.max_flats)
                plan.members_per_flat = plan.members_per_flat[: plan.n_flats]
                plan.facilities_per_type = _tier_facilities_per_type(plan.n_flats)
        plans.append(plan)

    total_planned = sum(_total_users(p) for p in plans)
    print(f"[seed] 20 tenants planned; ~{total_planned} residents (before caps)")

    for plan in plans:
        if plan.complete and not args.dry_run:
            print(f"[seed] SKIP complete tenant {plan.slug}")
            continue

        print(
            f"\n[seed] === {plan.slug} flats={plan.n_flats} "
            f"users≈{_total_users(plan)} fac/type={plan.facilities_per_type} ==="
        )

        # Facilities
        if not args.skip_facilities and not plan.facilities_done:
            if recreate_fac:
                _delete_facilities(db, plan.tenant_id, args.dry_run)
            nfac = _create_facilities(
                db, plan.tenant_id, catalog, plan.facilities_per_type, args.dry_run
            )
            print(f"[seed] facilities created: {nfac}")
            plan.facilities_done = True
            state["tenants"][plan.slug] = {
                **asdict(plan),
                "members_per_flat": plan.members_per_flat,
            }
            _save_state(args.state_file, state)

        # Users
        if args.skip_users:
            plan.complete = True
            state["tenants"][plan.slug] = asdict(plan)
            _save_state(args.state_file, state)
            continue

        # Flatten memberships as (flat, member_idx) for resume by users_done
        slots: list[tuple[str, int]] = []
        for fi in range(plan.n_flats):
            flat = f"F-{fi + 1:04d}"
            for mi in range(plan.members_per_flat[fi]):
                slots.append((flat, mi))

        if args.max_users_per_tenant > 0:
            slots = slots[: args.max_users_per_tenant]

        start_idx = plan.users_done
        print(f"[seed] users progress {start_idx}/{len(slots)}")

        for idx in range(start_idx, len(slots)):
            flat, mi = slots[idx]
            n = state["global_counter"]
            email = f"{plan.slug}.resident.{n}@{EMAIL_DOMAIN}"
            display = f"{plan.slug} Resident {n}"
            try:
                _create_resident(
                    db,
                    tenant_id=plan.tenant_id,
                    tenant_slug=plan.slug,
                    email=email,
                    display_name=display,
                    flat_number=flat,
                    password=args.password,
                    dry_run=args.dry_run,
                )
            except Exception as exc:  # noqa: BLE001
                print(f"[seed] WARN user {email}: {exc}")
            state["global_counter"] = n + 1
            plan.users_done = idx + 1
            if (idx + 1) % 50 == 0 or idx + 1 == len(slots):
                state["tenants"][plan.slug] = asdict(plan)
                _save_state(args.state_file, state)
                print(f"[seed] {plan.slug} users {plan.users_done}/{len(slots)} counter={state['global_counter']}")
            # gentle pacing for Auth quotas
            if not args.dry_run and (idx + 1) % 20 == 0:
                time.sleep(0.5)

        plan.complete = True
        state["tenants"][plan.slug] = asdict(plan)
        _save_state(args.state_file, state)
        print(f"[seed] DONE tenant {plan.slug}")

    print(f"\n[seed] finished. state={args.state_file} global_counter={state['global_counter']}")
    print(f"[seed] login password for seed residents: (see --password / state file)")
    print(f"[seed] sample email: {plans[0].slug}.resident.1@{EMAIL_DOMAIN}")

    if args.set_min_instances > 0 and not args.dry_run:
        import subprocess

        print(f"[seed] setting Cloud Run min instances={args.set_min_instances}")
        cmd = [
            "gcloud",
            "run",
            "services",
            "update",
            "sport-slot-api",
            f"--project={args.project}",
            f"--region={args.region}",
            f"--min-instances={args.set_min_instances}",
            "--quiet",
        ]
        try:
            subprocess.run(cmd, check=True)
            print("[seed] Cloud Run min instances updated")
        except Exception as exc:  # noqa: BLE001
            print(f"[seed] WARN gcloud min-instances failed: {exc}")
            print(
                "  Set via Terraform: cloud_run_min_instances = 1 in test tfvars + apply"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
