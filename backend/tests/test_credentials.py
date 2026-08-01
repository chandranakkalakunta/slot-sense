"""Unit tests for ADR-0044 initial credential helpers."""
import datetime

from sport_slot.auth.credentials import (
    generate_initial_password,
    is_temp_password_expired,
    temp_password_expires_at,
)


def test_generate_initial_password_is_six_digits():
    for _ in range(20):
        code = generate_initial_password()
        assert len(code) == 6
        assert code.isdigit()


def test_temp_password_expires_at_default_24h():
    now = datetime.datetime(2026, 8, 1, 12, 0, 0, tzinfo=datetime.UTC)
    exp = temp_password_expires_at(now=now)
    assert exp == now + datetime.timedelta(hours=24)


def test_is_temp_password_expired_none_is_not_expired():
    assert is_temp_password_expired(None) is False


def test_is_temp_password_expired_past():
    past = datetime.datetime(2020, 1, 1, tzinfo=datetime.UTC)
    assert is_temp_password_expired(past) is True


def test_is_temp_password_expired_future():
    future = datetime.datetime.now(datetime.UTC) + datetime.timedelta(hours=1)
    assert is_temp_password_expired(future) is False
