"""Hermetic tests for password_policy.py — ALL HIBP / network calls mocked."""
from unittest.mock import AsyncMock, MagicMock, patch

import structlog.testing

POLICY = "sport_slot.auth.password_policy"

# ── validate_password: structural checks ──────────────────────────────────────


async def test_too_short_rejected():
    from sport_slot.auth.password_policy import validate_password

    result = await validate_password("Short1!")  # 7 chars — below min 8
    assert not result.ok
    assert any("8" in e for e in result.errors)


async def test_too_long_rejected():
    from sport_slot.auth.password_policy import validate_password

    result = await validate_password("A" * 65)
    assert not result.ok
    assert any("64" in e for e in result.errors)


async def test_long_but_weak_rejected_by_zxcvbn_and_hibp_not_called():
    """Length >= 8 but zxcvbn score < 3; HIBP must NOT be contacted."""
    from sport_slot.auth.password_policy import validate_password

    with patch(f"{POLICY}._is_pwned") as mock_pwned:
        # "password1" — 9 chars (passes length), weak zxcvbn (fails strength)
        result = await validate_password("password1")

    assert not result.ok
    assert any("easily guessed" in e for e in result.errors)
    mock_pwned.assert_not_called()


async def test_pwned_password_rejected():
    """Strong password but found in HIBP breach list → rejected."""
    from sport_slot.auth.password_policy import validate_password

    with patch(f"{POLICY}._is_pwned", new=AsyncMock(return_value=True)):
        result = await validate_password("Tr0ub4dor&3xtr@Strong!QzXp9")

    assert not result.ok
    assert any("breach" in e for e in result.errors)


async def test_hibp_timeout_fail_open_passes_and_logs_warning():
    """HIBP timeout → _is_pwned returns None → fail-open: strong password PASSES
    and a hibp_check_degraded WARNING is logged."""
    from sport_slot.auth.password_policy import validate_password

    with structlog.testing.capture_logs() as cap_logs:
        with patch(f"{POLICY}._is_pwned", new=AsyncMock(return_value=None)):
            result = await validate_password("Tr0ub4dor&3xtr@Strong!QzXp9")

    assert result.ok, "Fail-open: strong password must pass when HIBP is unavailable"
    degrade_events = [lg for lg in cap_logs if lg.get("event") == "hibp_check_degraded"]
    assert degrade_events, "Expected a hibp_check_degraded warning in the log output"


async def test_strong_unique_password_passes():
    """Strong password not in HIBP → ok=True, no errors."""
    from sport_slot.auth.password_policy import validate_password

    with patch(f"{POLICY}._is_pwned", new=AsyncMock(return_value=False)):
        result = await validate_password("Tr0ub4dor&3xtr@Strong!QzXp9")

    assert result.ok
    assert result.errors == []


# ── _is_pwned: HIBP response parsing ─────────────────────────────────────────


async def test_is_pwned_returns_true_on_matching_suffix():
    """Build a response body whose SUFFIX:COUNT line matches our hash → True."""
    import hashlib

    from sport_slot.auth.password_policy import _is_pwned

    pw = "hunter2"
    sha1 = hashlib.sha1(pw.encode()).hexdigest().upper()
    suffix = sha1[5:]

    body = f"AAAAABBBBB:0\n{suffix}:42\nZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ:0\n"
    mock_resp = MagicMock(status_code=200, text=body)
    mock_client = AsyncMock()
    mock_client.get = AsyncMock(return_value=mock_resp)

    with patch("httpx.AsyncClient", return_value=AsyncMock(
        __aenter__=AsyncMock(return_value=mock_client),
        __aexit__=AsyncMock(return_value=False),
    )):
        result = await _is_pwned(pw)

    assert result is True


async def test_is_pwned_returns_none_on_timeout():
    """Any httpx exception → None (fail-open signal)."""
    import httpx

    from sport_slot.auth.password_policy import _is_pwned

    with patch("httpx.AsyncClient", side_effect=httpx.TimeoutException("timed out")):
        result = await _is_pwned("some-password")

    assert result is None
