"""Global facility-type catalog (ADR-0015).

GET is available to any authenticated user (tenants pick types when
creating instances). Write operations are platform-admin only.
"""
from __future__ import annotations

import re
from typing import Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from sport_slot.api import error_codes
from sport_slot.api.errors import ApiError
from sport_slot.auth.context import TenantContext
from sport_slot.auth.dependency import get_tenant_context
from sport_slot.auth.roles import require_platform_admin
from sport_slot.dependencies import get_firestore_client

router = APIRouter(tags=["facility-catalog"])

_TYPE_ID_RE = re.compile(r"^[a-z][a-z0-9-]{1,62}[a-z0-9]$")


class CatalogTypeCreate(BaseModel):
    type_id: str = Field(..., min_length=2, max_length=64)
    name: str = Field(..., min_length=1, max_length=120)
    sport: str = Field(..., min_length=1, max_length=64)


class CatalogTypeUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    sport: str | None = Field(default=None, min_length=1, max_length=64)


def _validate_type_id(type_id: str) -> None:
    if not _TYPE_ID_RE.match(type_id):
        raise ApiError(
            422,
            error_codes.VALIDATION_FAILED,
            "type_id must be lowercase alphanumeric with hyphens "
            "(e.g. badminton, turf-football)",
        )


@router.get("/facility-catalog")
async def list_facility_catalog(
    ctx: TenantContext = Depends(get_tenant_context),
    client=Depends(get_firestore_client),
):
    items = [d.to_dict() for d in client.collection("facility_catalog").stream()]
    # Stable order for UI
    items.sort(key=lambda x: (x or {}).get("name") or (x or {}).get("type_id") or "")
    return {"items": items}


@router.post("/admin/facility-catalog", status_code=201)
async def create_catalog_type(
    body: CatalogTypeCreate,
    ctx: TenantContext = Depends(require_platform_admin),
    client=Depends(get_firestore_client),
):
    _validate_type_id(body.type_id)
    ref = client.collection("facility_catalog").document(body.type_id)
    if ref.get().exists:
        raise ApiError(
            409,
            error_codes.CATALOG_TYPE_EXISTS,
            f"Catalog type {body.type_id!r} already exists",
        )
    doc: dict[str, Any] = {
        "type_id": body.type_id,
        "name": body.name.strip(),
        "sport": body.sport.strip().lower(),
    }
    ref.set(doc)
    return doc


@router.patch("/admin/facility-catalog/{type_id}")
async def update_catalog_type(
    type_id: str,
    body: CatalogTypeUpdate,
    ctx: TenantContext = Depends(require_platform_admin),
    client=Depends(get_firestore_client),
):
    ref = client.collection("facility_catalog").document(type_id)
    snap = ref.get()
    if not snap.exists:
        raise ApiError(
            404,
            error_codes.CATALOG_TYPE_NOT_FOUND,
            f"Catalog type {type_id!r} not found",
        )
    updates: dict[str, Any] = {}
    if body.name is not None:
        updates["name"] = body.name.strip()
    if body.sport is not None:
        updates["sport"] = body.sport.strip().lower()
    if not updates:
        raise ApiError(422, error_codes.VALIDATION_FAILED, "No fields to update")
    ref.update(updates)
    data = snap.to_dict() or {}
    data.update(updates)
    data["type_id"] = type_id
    return data


@router.delete("/admin/facility-catalog/{type_id}", status_code=204)
async def delete_catalog_type(
    type_id: str,
    ctx: TenantContext = Depends(require_platform_admin),
    client=Depends(get_firestore_client),
):
    ref = client.collection("facility_catalog").document(type_id)
    if not ref.get().exists:
        raise ApiError(
            404,
            error_codes.CATALOG_TYPE_NOT_FOUND,
            f"Catalog type {type_id!r} not found",
        )
    ref.delete()
    return None
