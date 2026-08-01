"""Shared password policy validator: length + zxcvbn strength + HIBP breach check.

Enforced on POST /me/change-password (ADR-0020 §4, Phase 7.2.1).
All HIBP calls are async and fail-open: a network/timeout error degrades
to zxcvbn-only validation rather than blocking the user.
"""
import hashlib
from dataclasses import dataclass, field

import httpx
import structlog
import zxcvbn as _zxcvbn

log = structlog.get_logger()

# ADR-0044 D1: floor 12 → 8 (strength gate + HIBP unchanged)
MIN_LENGTH = 8
MAX_LENGTH = 64
MIN_ZXCVBN_SCORE = 3            # zxcvbn score is 0–4; require ≥ 3
HIBP_TIMEOUT_SECONDS = 2.0
HIBP_RANGE_URL = "https://api.pwnedpasswords.com/range/"


@dataclass
class PasswordPolicyResult:
    ok: bool
    errors: list[str] = field(default_factory=list)


async def validate_password(password: str) -> PasswordPolicyResult:
    """Validate *password* against the shared policy.

    Short-circuits: HIBP is never contacted when earlier checks already fail.
    """
    errors: list[str] = []

    # (a) Length checks
    if len(password) < MIN_LENGTH:
        errors.append(
            f"Password must be at least {MIN_LENGTH} characters."
        )
    if len(password) > MAX_LENGTH:
        errors.append(
            f"Password must be no more than {MAX_LENGTH} characters."
        )

    # (b) zxcvbn strength check
    result = _zxcvbn.zxcvbn(password)
    if result["score"] < MIN_ZXCVBN_SCORE:
        weak_msg = "This password is too easily guessed; choose a stronger one."
        suggestions = (result.get("feedback") or {}).get("suggestions") or []
        if suggestions:
            weak_msg += " " + " ".join(suggestions)
        errors.append(weak_msg)

    # (c) Short-circuit — skip HIBP when earlier checks already failed
    if errors:
        return PasswordPolicyResult(ok=False, errors=errors)

    # (d) HIBP breach check
    pwned = await _is_pwned(password)
    if pwned is True:
        errors.append(
            "This password has appeared in a known data breach; choose a different one."
        )
        return PasswordPolicyResult(ok=False, errors=errors)
    if pwned is None:
        log.warning("hibp_check_degraded", reason="HIBP unavailable; falling back to zxcvbn-only")

    return PasswordPolicyResult(ok=True)


async def _is_pwned(password: str) -> bool | None:
    """Return True if password is in HIBP, False if not, None on any error.

    Uses k-anonymity range query so only the first 5 chars of the SHA-1
    hash are transmitted.
    """
    # SHA-1 is MANDATED by the HIBP k-anonymity API, not used for security.
    sha1 = hashlib.sha1(password.encode("utf-8")).hexdigest().upper()  # nosec B303 B324
    prefix, suffix = sha1[:5], sha1[5:]
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                HIBP_RANGE_URL + prefix,
                timeout=HIBP_TIMEOUT_SECONDS,
                headers={"Add-Padding": "true"},
            )
        if response.status_code != 200:
            return None
        for line in response.text.splitlines():
            if ":" not in line:
                continue
            line_suffix, _, count_str = line.partition(":")
            if line_suffix == suffix and int(count_str) >= 1:
                return True
        return False
    except Exception:  # noqa: BLE001
        return None
