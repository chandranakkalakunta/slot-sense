"""Initial credential generation (ADR-0044 D4–D5).

Machine-generated temporary passwords are 6-digit numeric codes with a
short TTL. User-chosen passwords go through password_policy.validate_password
(min length 8 + zxcvbn + HIBP) — not this module.
"""
from __future__ import annotations

import datetime
import secrets

from sport_slot.config import get_settings


def generate_initial_password() -> str:
    """Return a cryptographically random 6-digit code (000000–999999)."""
    return f"{secrets.randbelow(1_000_000):06d}"


def temp_password_expires_at(
    *, now: datetime.datetime | None = None
) -> datetime.datetime:
    """UTC expiry timestamp for a newly issued initial credential."""
    base = now or datetime.datetime.now(datetime.UTC)
    hours = get_settings().temp_password_ttl_hours
    return base + datetime.timedelta(hours=hours)


def is_temp_password_expired(
    expires_at: datetime.datetime | str | None,
    *,
    now: datetime.datetime | None = None,
) -> bool:
    """True if *expires_at* is in the past. Missing expiry = not expired
    (legacy profiles provisioned before ADR-0044)."""
    if expires_at is None:
        return False
    if isinstance(expires_at, str):
        # Firestore may return ISO strings in some test fakes
        try:
            expires_at = datetime.datetime.fromisoformat(
                expires_at.replace("Z", "+00:00")
            )
        except ValueError:
            return False
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=datetime.UTC)
    current = now or datetime.datetime.now(datetime.UTC)
    return current >= expires_at
