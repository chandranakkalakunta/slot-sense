from google.cloud import firestore

from sport_slot.repositories.base import TenantRepository


class UserProfileRepository(TenantRepository):
    """/tenants/{tenant_id}/users/{uid} (ADR-0008 Decision 4)."""

    collection_name = "users"

    def clear_must_change_password(self, uid: str) -> None:
        """Clear force-change flag + temp expiry after successful password set."""
        ref = self._collection.document(uid)
        if not ref.get().exists:
            return
        ref.update({
            "must_change_password": False,  # nosec B105 - Firestore field name
            "temp_password_expires_at": firestore.DELETE_FIELD,
        })
