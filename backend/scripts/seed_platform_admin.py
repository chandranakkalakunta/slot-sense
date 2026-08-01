"""Seed the first platform-admin user (ADR-0014 §2).

Run once per environment (idempotent — resets password if email already
exists). --project is required and always explicit: it is passed directly
to both firebase_admin.initialize_app() and firestore.Client(), never
resolved from ambient ADC/gcloud config, so running this against the wrong
gcloud context cannot silently seed an admin into the wrong environment.

    uv run python scripts/seed_platform_admin.py --project <gcp-project-id>

Set PLATFORM_ADMIN_EMAIL env var to override the default address (one
admin address, admin@chandraailabs.com, is used across all environments
by default).

Claim propagation caveat: the custom claims set here (role=platform_admin
etc.) only appear in a Firebase ID token that is issued AFTER this script
runs. If the admin already has a live session, they must sign out and
sign in fresh — refreshing an existing token is not enough.
"""
import argparse
import datetime
import os
import sys
from pathlib import Path

# Allow running as `uv run python scripts/seed_platform_admin.py` from backend/
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import firebase_admin
import firebase_admin.auth as fb_auth
from google.cloud import firestore

from sport_slot.auth.credentials import (
    generate_initial_password,
    temp_password_expires_at,
)

ADMIN_EMAIL = os.environ.get(
    "PLATFORM_ADMIN_EMAIL", "admin@chandraailabs.com"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Seed the first platform-admin user for a given GCP project."
    )
    parser.add_argument(
        "--project",
        required=True,
        help="Target GCP project ID (no default, no ambient fallback).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    project = args.project

    print(f"[seed] Target project: {project}")

    if not firebase_admin._apps:
        firebase_admin.initialize_app(options={"projectId": project})

    temp_password = generate_initial_password()

    try:
        user = fb_auth.create_user(
            email=ADMIN_EMAIL, password=temp_password, display_name="Platform Admin"
        )
        print(f"[seed] Created platform admin: {ADMIN_EMAIL}")
    except fb_auth.EmailAlreadyExistsError:
        user = fb_auth.get_user_by_email(ADMIN_EMAIL)
        fb_auth.update_user(user.uid, password=temp_password, disabled=False)
        print(f"[seed] Reset password for existing platform admin: {ADMIN_EMAIL}")

    fb_auth.set_custom_user_claims(user.uid, {
        "role": "platform_admin",
        "tenant_id": None,
        "tenant_slug": None,
        "household_id": None,
    })

    db = firestore.Client(project=project)
    db.collection("platform_admins").document(user.uid).set(
        {
            "uid": user.uid,
            "email": ADMIN_EMAIL,
            "role": "platform_admin",
            "must_change_password": True,
            "temp_password_expires_at": temp_password_expires_at(),
            "created_at": datetime.datetime.now(datetime.UTC),
        },
        merge=True,
    )

    print(f"[seed] UID:           {user.uid}")
    print(f"[seed] Temp password: {temp_password}")
    print("[seed] Custom claims: role=platform_admin, tenant_id=null")
    print("[seed] Profile written to platform_admins collection")
    print("[seed] must_change_password=true (forced change on first login)")


if __name__ == "__main__":
    main()
