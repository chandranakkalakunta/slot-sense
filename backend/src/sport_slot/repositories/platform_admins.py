"""Platform-admin profile store: platform_admins/{uid} (ADR-0008 / ADR-0014)."""
from __future__ import annotations

from typing import Any

from google.cloud import firestore


class PlatformAdminRepository:
    """Firestore access for platform_admins collection (no tenant scope)."""

    collection_name = "platform_admins"

    def __init__(self, client: firestore.Client) -> None:
        self._client = client

    @property
    def _collection(self):
        return self._client.collection(self.collection_name)

    def get(self, uid: str) -> dict[str, Any] | None:
        snap = self._collection.document(uid).get()
        if not snap.exists:
            return None
        data = snap.to_dict() or {}
        data.setdefault("uid", uid)
        data.setdefault("role", "platform_admin")
        return data

    def clear_must_change_password(self, uid: str) -> None:
        ref = self._collection.document(uid)
        if not ref.get().exists:
            return
        ref.update({
            "must_change_password": False,  # nosec B105 - Firestore field name
            "temp_password_expires_at": firestore.DELETE_FIELD,
        })
