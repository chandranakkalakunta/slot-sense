"""Platform-admin facility catalog CRUD (ADR-0015 management)."""
from unittest.mock import MagicMock, patch

from sport_slot.dependencies import get_firestore_client

PLATFORM_CLAIMS = {
    "uid": "admin-1",
    "role": "platform_admin",
    "tenant_id": None,
    "tenant_slug": None,
    "household_id": None,
}
RESIDENT_CLAIMS = {
    "uid": "user-1",
    "role": "resident",
    "tenant_id": "t-1",
    "tenant_slug": "demo",
    "household_id": "h-1",
}
AUTH = {"authorization": "Bearer fake-token"}
HOST = {"host": "admin-test.slotsense.chandraailabs.com"}
VERIFY = "sport_slot.auth.dependency.fb_auth.verify_id_token"


def _catalog_client(*, existing: dict | None = None):
    """Firestore mock: collection('facility_catalog').document(id)."""
    client = MagicMock()
    col = client.collection.return_value
    doc_ref = col.document.return_value
    snap = MagicMock()
    if existing is None:
        snap.exists = False
        snap.to_dict.return_value = None
    else:
        snap.exists = True
        snap.to_dict.return_value = dict(existing)
    doc_ref.get.return_value = snap
    # stream() for list
    if existing:
        stream_snap = MagicMock()
        stream_snap.to_dict.return_value = dict(existing)
        col.stream.return_value = [stream_snap]
    else:
        col.stream.return_value = []
    return client, doc_ref


async def test_create_catalog_type_platform_admin(make_client):
    client, doc_ref = _catalog_client(existing=None)
    with patch(VERIFY, return_value=PLATFORM_CLAIMS):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = (
                lambda: client
            )
            resp = await c.post(
                "/api/v1/admin/facility-catalog",
                headers={**AUTH, **HOST},
                json={"type_id": "squash", "name": "Squash", "sport": "squash"},
            )
    assert resp.status_code == 201
    assert resp.json()["type_id"] == "squash"
    doc_ref.set.assert_called_once()


async def test_create_catalog_type_forbidden_for_resident(make_client):
    client, _ = _catalog_client()
    with patch(VERIFY, return_value=RESIDENT_CLAIMS):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = (
                lambda: client
            )
            resp = await c.post(
                "/api/v1/admin/facility-catalog",
                headers={
                    **AUTH,
                    "host": "demo.slotsense.chandraailabs.com",
                },
                json={"type_id": "squash", "name": "Squash", "sport": "squash"},
            )
    assert resp.status_code == 403


async def test_delete_catalog_type(make_client):
    client, doc_ref = _catalog_client(
        existing={"type_id": "squash", "name": "Squash", "sport": "squash"}
    )
    with patch(VERIFY, return_value=PLATFORM_CLAIMS):
        async with make_client() as c:
            c._transport.app.dependency_overrides[get_firestore_client] = (
                lambda: client
            )
            resp = await c.delete(
                "/api/v1/admin/facility-catalog/squash",
                headers={**AUTH, **HOST},
            )
    assert resp.status_code == 204
    doc_ref.delete.assert_called_once()
