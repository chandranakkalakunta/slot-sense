"""User provisioning service — single path for all user creation (ADR-0016)."""
import datetime

import firebase_admin.auth as fb_auth
import structlog

from sport_slot.api import error_codes
from sport_slot.api.errors import ApiError
from sport_slot.auth.context import TenantContext
from sport_slot.auth.credentials import (
    generate_initial_password,
    temp_password_expires_at,
)
from sport_slot.config import get_settings
from sport_slot.notifications.tasks import enqueue_notification
from sport_slot.repositories.bookings import AuditRepository
from sport_slot.repositories.user_profiles import UserProfileRepository

log = structlog.get_logger()

_VALID_ROLES = {"resident", "tenant_admin"}


class ProvisioningError(ApiError):
    """Expected service-layer error; caught by tenant-admin routes (ADR-0016).

    Extends ApiError so the registered exception handler returns the correct
    HTTP response when the error propagates uncaught (e.g. platform-admin
    endpoints that do not wrap with try/except).
    """
    pass


def _derive_household(flat_number: str, household_id: str | None) -> str:
    return household_id if household_id else f"h-{flat_number}"


def _ctx(tenant_id: str | None, uid: str, role: str) -> TenantContext:
    return TenantContext(uid=uid, tenant_id=tenant_id, tenant_slug=None, role=role)


class UserProvisioningService:
    def __init__(
        self,
        client,
        caller_uid: str | None = None,
        caller_role: str | None = None,
    ) -> None:
        self._client = client
        self._caller_uid = caller_uid
        self._caller_role = caller_role

    def create_user(
        self,
        tenant_id: str,
        email: str,
        display_name: str,
        flat_number: str | None,
        role: str,
        household_id: str | None = None,
        request_id: str = "-",
    ) -> dict:
        if role not in _VALID_ROLES:
            raise ProvisioningError(422, error_codes.VALIDATION_FAILED, f"Invalid role: {role!r}")

        # STEP 5 fix: flat_number required for residents, optional for tenant_admin.
        if role == "resident" and not flat_number:
            raise ProvisioningError(
                422, error_codes.VALIDATION_FAILED, "flat_number required for residents"
            )

        # Look up tenant slug so the JWT claim allows host-based cross-checks (ADR-0012 §2).
        tenant_snap = self._client.collection("tenants").document(tenant_id).get()
        tenant_slug = (tenant_snap.to_dict() or {}).get("slug") if tenant_snap.exists else None

        temp_password = generate_initial_password()
        try:
            user = fb_auth.create_user(
                email=email, display_name=display_name, password=temp_password
            )
        except fb_auth.EmailAlreadyExistsError:
            raise ProvisioningError(409, error_codes.USER_EMAIL_TAKEN, f"Email {email!r} already registered")

        try:
            hid = _derive_household(flat_number, household_id) if flat_number else None
            fb_auth.set_custom_user_claims(user.uid, {
                "tenant_id": tenant_id,
                "tenant_slug": tenant_slug,
                "role": role,
                "household_id": hid,
            })
            ctx = _ctx(tenant_id=tenant_id, uid=user.uid, role=role)
            UserProfileRepository(ctx, self._client).create(user.uid, {
                "uid": user.uid,
                "email": email,
                "display_name": display_name,
                "flat_number": flat_number,
                "household_id": hid,
                "role": role,
                "must_change_password": True,  # nosec B105 - Firestore field name, not a credential
                "temp_password_expires_at": temp_password_expires_at(),
                "created_at": datetime.datetime.now(datetime.UTC),
            })
            AuditRepository(ctx, self._client).write_event(
                event_type="user_provisioned",
                actor_uid=user.uid,
                actor_role=role,
                booking_id="-",
                request_id=request_id,
                details={"email": email, "flat_number": flat_number, "role": role},
            )
        except ApiError:
            fb_auth.delete_user(user.uid)
            raise
        except Exception:
            fb_auth.delete_user(user.uid)
            raise ApiError(500, error_codes.INTERNAL_ERROR, "User creation failed") from None

        # Best-effort (ADR-0019): the user is already created above, so a
        # notification failure here must never roll back provisioning.
        try:
            tenant_doc = tenant_snap.to_dict() if tenant_snap.exists else None
            tenant_name = (tenant_doc or {}).get("display_name", "")
            login_url = get_settings().welcome_login_url
            enqueue_notification(
                event_type="user_welcome",
                to=email,
                params={
                    "user_name": display_name,
                    "tenant_name": tenant_name,
                    "login_url": login_url,
                    "temp_password": temp_password,
                },
            )
        except Exception as exc:  # noqa: BLE001 - best-effort; user already created
            log.warning("notification_enqueue_failed", event_type="user_welcome",
                        uid=user.uid, error=str(exc))

        return {"uid": user.uid, "temp_password": temp_password}

    def deactivate_user(
        self,
        tenant_id: str,
        target_uid: str,
        request_id: str = "-",
    ) -> dict:
        caller_uid = self._caller_uid
        if target_uid == caller_uid:
            raise ProvisioningError(
                403, error_codes.SELF_DEACTIVATION_FORBIDDEN, "Cannot deactivate yourself"
            )

        ctx = _ctx(tenant_id=tenant_id, uid=caller_uid or "", role="tenant_admin")
        repo = UserProfileRepository(ctx, self._client)
        profile = repo.get(target_uid)
        if profile is None:
            raise ProvisioningError(404, error_codes.USER_NOT_FOUND, f"User {target_uid!r} not found")

        repo.update(target_uid, {
            "status": "inactive",
            "active": False,
            "deactivated_at": datetime.datetime.now(datetime.UTC),
        })
        fb_auth.update_user(target_uid, disabled=True)
        today = datetime.date.today().isoformat()
        self._cancel_future_bookings(tenant_id, target_uid, today)
        AuditRepository(ctx, self._client).write_event(
            event_type="user.deactivated",
            actor_uid=caller_uid or "",
            actor_role="tenant_admin",
            booking_id="-",
            request_id=request_id,
            details={"target_uid": target_uid},
        )
        return {"uid": target_uid, "status": "deactivated"}

    def delete_user_permanently(
        self,
        tenant_id: str,
        target_uid: str,
        request_id: str = "-",
    ) -> dict:
        caller_uid = self._caller_uid
        if target_uid == caller_uid:
            raise ProvisioningError(
                403, error_codes.SELF_DELETION_FORBIDDEN, "Cannot delete yourself"
            )

        ctx = _ctx(tenant_id=tenant_id, uid=caller_uid or "", role="tenant_admin")
        repo = UserProfileRepository(ctx, self._client)
        profile = repo.get(target_uid)
        if profile is None:
            raise ProvisioningError(404, error_codes.USER_NOT_FOUND, f"User {target_uid!r} not found")

        # ADR-0034 invoice-exclusion carve-out (Phase 15.7): already satisfied
        # structurally, no code change needed. Invoices live in their own
        # `tenants/{id}/invoices` subcollection keyed by household_id — this
        # function only ever deletes from `bookings` (filtered by uid) and
        # never queries or touches invoices at all. Contrast with
        # delete_tenant_permanently (services/tenants.py), which DID need a
        # real fix since its whole-subtree recursive_delete would otherwise
        # have destroyed invoices along with everything else.
        bookings_col = (
            self._client.collection("tenants")
            .document(tenant_id)
            .collection("bookings")
        )
        bookings_deleted = 0
        for snap in bookings_col.where("uid", "==", target_uid).stream():
            snap.reference.delete()
            bookings_deleted += 1

        try:
            fb_auth.delete_user(target_uid)
        except fb_auth.UserNotFoundError:
            log.warning("delete_user_permanently_auth_already_absent",
                        target_uid=target_uid)

        AuditRepository(ctx, self._client).write_event(
            event_type="user.deleted",
            actor_uid=caller_uid or "",
            actor_role="tenant_admin",
            booking_id="-",
            request_id=request_id,
            details={"target_uid": target_uid, "bookings_deleted": bookings_deleted},
        )

        repo.delete(target_uid)

        return {"uid": target_uid, "status": "deleted", "bookings_deleted": bookings_deleted}

    def reset_password(self, tenant_id: str, uid: str, request_id: str = "") -> dict:
        ref = (self._client.collection("tenants").document(tenant_id)
               .collection("users").document(uid))
        if not ref.get().exists:
            raise ProvisioningError(404, error_codes.USER_NOT_FOUND, f"User {uid!r} not found")
        password = generate_initial_password()
        fb_auth.update_user(uid, password=password, disabled=False)
        ref.update({
            "must_change_password": True,  # nosec B105 - Firestore field name, not a credential
            "temp_password_expires_at": temp_password_expires_at(),
        })
        AuditRepository(_ctx(tenant_id, self._caller_uid or "", self._caller_role or ""),
                        self._client).write_event(
            "user.password_reset", self._caller_uid or "", self._caller_role or "", uid,
            request_id, {})
        return {"uid": uid, "temp_password": password}

    def _cancel_future_bookings(self, tenant_id: str, uid: str, today: str) -> int:
        col = (
            self._client.collection("tenants")
            .document(tenant_id)
            .collection("bookings")
        )
        query = (
            col.where("uid", "==", uid)
            .where("status", "==", "confirmed")
            .where("date", ">=", today)
        )
        count = 0
        for snap in query.stream():
            snap.reference.update({
                "status": "cancelled",
                "cancelled_at": datetime.datetime.now(datetime.UTC),
            })
            count += 1
        return count
