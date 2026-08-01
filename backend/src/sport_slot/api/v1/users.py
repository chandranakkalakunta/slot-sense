import firebase_admin.auth as fb_auth
import structlog
from fastapi import APIRouter, Depends
from google.cloud import firestore
from pydantic import BaseModel

from sport_slot.api import error_codes
from sport_slot.api.errors import ApiError
from sport_slot.auth.context import TenantContext
from sport_slot.auth.credentials import is_temp_password_expired
from sport_slot.auth.dependency import get_tenant_context
from sport_slot.auth.password_policy import validate_password
from sport_slot.dependencies import get_firestore_client
from sport_slot.repositories.user_profiles import UserProfileRepository

log = structlog.get_logger()
router = APIRouter(prefix="/users", tags=["users"])


def _platform_admin_profile(client, uid: str) -> dict | None:
    snap = client.collection("platform_admins").document(uid).get()
    if not snap.exists:
        return None
    data = snap.to_dict() or {}
    data.setdefault("uid", uid)
    data.setdefault("role", "platform_admin")
    return data


@router.get("/me")
async def get_me(
    ctx: TenantContext = Depends(get_tenant_context),
    client=Depends(get_firestore_client),
):
    # Platform admins live in platform_admins/{uid}, not tenants/{id}/users.
    if ctx.role == "platform_admin":
        profile = _platform_admin_profile(client, ctx.uid)
        if profile is None:
            raise ApiError(
                404,
                error_codes.USER_PROFILE_NOT_FOUND,
                "Authenticated user has no profile (not provisioned)",
            )
        return profile

    profile = UserProfileRepository(ctx, client).get(ctx.uid)
    if profile is None:
        raise ApiError(
            404,
            error_codes.USER_PROFILE_NOT_FOUND,
            "Authenticated user has no profile (not provisioned)",
        )
    return profile


class ChangePasswordBody(BaseModel):
    new_password: str


@router.post("/me/change-password")
async def change_password(
    body: ChangePasswordBody,
    ctx: TenantContext = Depends(get_tenant_context),
    client=Depends(get_firestore_client),
):
    # Load profile for expiry check when force-change is pending
    profile: dict | None = None
    platform_ref = None
    tenant_ref = None

    if ctx.role == "platform_admin":
        platform_ref = client.collection("platform_admins").document(ctx.uid)
        snap = platform_ref.get()
        if snap.exists:
            profile = snap.to_dict() or {}
    elif ctx.tenant_id:
        tenant_ref = (
            client.collection("tenants")
            .document(ctx.tenant_id)
            .collection("users")
            .document(ctx.uid)
        )
        snap = tenant_ref.get()
        if snap.exists:
            profile = snap.to_dict() or {}

    if profile and profile.get("must_change_password"):
        expires = profile.get("temp_password_expires_at")
        if is_temp_password_expired(expires):
            try:
                fb_auth.update_user(ctx.uid, disabled=True)
            except Exception as exc:  # noqa: BLE001 - best-effort disable
                log.warning(
                    "temp_password_disable_failed",
                    uid=ctx.uid,
                    error=str(exc),
                )
            raise ApiError(
                403,
                error_codes.TEMP_PASSWORD_EXPIRED,
                "Temporary code expired — ask an admin to re-issue credentials",
            )

    result = await validate_password(body.new_password)
    if not result.ok:
        raise ApiError(422, error_codes.WEAK_PASSWORD, " ".join(result.errors))
    fb_auth.update_user(ctx.uid, password=body.new_password)

    clear_fields = {
        "must_change_password": False,  # nosec B105 - Firestore field name
        "temp_password_expires_at": firestore.DELETE_FIELD,
    }
    if platform_ref is not None and platform_ref.get().exists:
        platform_ref.update(clear_fields)
    elif tenant_ref is not None and tenant_ref.get().exists:
        tenant_ref.update(clear_fields)

    return {"status": "ok"}
