"""Platform admin /users/me + force-change path (ADR-0014 + ADR-0044)."""
import datetime
from unittest.mock import AsyncMock, MagicMock, patch

from sport_slot.dependencies import get_firestore_client

PLATFORM_CLAIMS = {
    "uid": "admin-1",
    "role": "platform_admin",
    "tenant_id": None,
    "tenant_slug": None,
    "household_id": None,
}
AUTH = {"authorization": "Bearer fake-token"}
HOST = {"host": "admin-test.slotsense.chandraailabs.com"}
VERIFY = "sport_slot.auth.dependency.fb_auth.verify_id_token"
UPDATE_USER = "sport_slot.api.v1.users.fb_auth.update_user"


def _platform_client(profile: dict | None):
    client = MagicMock()
    # platform_admins/{uid}
    col = client.collection.return_value
    doc = col.document.return_value
    snap = MagicMock()
    snap.exists = profile is not None
    snap.to_dict.return_value = profile
    doc.get.return_value = snap
    return client, doc


async def test_me_returns_platform_admin_profile(make_client):
    profile = {
        "uid": "admin-1",
        "email": "admin@chandraailabs.com",
        "role": "platform_admin",
        "must_change_password": True,
    }
    client, _ = _platform_client(profile)
    with patch(VERIFY, return_value=PLATFORM_CLAIMS):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = (
                lambda: client
            )
            resp = await c.get("/api/v1/users/me", headers={**AUTH, **HOST})
    assert resp.status_code == 200
    assert resp.json()["must_change_password"] is True
    assert resp.json()["role"] == "platform_admin"


async def test_change_password_clears_platform_admin_flag(make_client):
    profile = {
        "uid": "admin-1",
        "must_change_password": True,
        "temp_password_expires_at": datetime.datetime.now(datetime.UTC)
        + datetime.timedelta(hours=12),
    }
    client, doc = _platform_client(profile)
    with patch(VERIFY, return_value=PLATFORM_CLAIMS):
        with patch(UPDATE_USER) as mock_update:
            with patch(
                "sport_slot.api.v1.users.validate_password",
                new=AsyncMock(return_value=MagicMock(ok=True, errors=[])),
            ):
                async with make_client() as c:
                    c._transport.app.dependency_overrides[get_firestore_client] = (
                        lambda: client
                    )
                    resp = await c.post(
                        "/api/v1/users/me/change-password",
                        headers={**AUTH, **HOST},
                        json={"new_password": "Tr0ub4dor&3xtr@Strong!Qz"},
                    )
    assert resp.status_code == 200
    mock_update.assert_called_once()
    doc.update.assert_called_once()
    assert doc.update.call_args[0][0]["must_change_password"] is False


async def test_change_password_expired_temp_code(make_client):
    profile = {
        "uid": "admin-1",
        "must_change_password": True,
        "temp_password_expires_at": datetime.datetime(2020, 1, 1, tzinfo=datetime.UTC),
    }
    client, _ = _platform_client(profile)
    with patch(VERIFY, return_value=PLATFORM_CLAIMS):
        with patch(UPDATE_USER):
            async with make_client() as c:
                c._transport.app.dependency_overrides[get_firestore_client] = (
                    lambda: client
                )
                resp = await c.post(
                    "/api/v1/users/me/change-password",
                    headers={**AUTH, **HOST},
                    json={"new_password": "Tr0ub4dor&3xtr@Strong!Qz"},
                )
    assert resp.status_code == 403
    assert resp.json()["code"] == "TEMP_PASSWORD_EXPIRED"
