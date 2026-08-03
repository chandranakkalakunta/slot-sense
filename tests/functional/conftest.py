"""Pytest fixtures for live-env S-FUNC (ADR-0045)."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Any

import httpx
import pytest

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class FuncConfig:
    base_domain: str
    admin_host: str
    tenant_slug: str
    project_id: str
    firebase_api_key: str
    resident_email: str
    resident_password: str
    facility_id: str
    expect_build_id: str
    skip_agent: bool
    skip_booking: bool

    @property
    def admin_origin(self) -> str:
        return f"https://{self.admin_host}"

    @property
    def tenant_origin(self) -> str:
        return f"https://{self.tenant_slug}.{self.base_domain}"

    @property
    def apex_origin(self) -> str:
        return f"https://{self.base_domain}"


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


@pytest.fixture(scope="session")
def cfg() -> FuncConfig:
    base = _env("FUNC_BASE_DOMAIN")
    if not base:
        pytest.skip(
            "FUNC_BASE_DOMAIN not set — copy tests/functional/.env.example "
            "to .env.local and source it (see tests/functional/README.md)"
        )
    return FuncConfig(
        base_domain=base,
        admin_host=_env("FUNC_ADMIN_HOST", f"admin.{base}"),
        tenant_slug=_env("FUNC_TENANT_SLUG", "marina-skies"),
        project_id=_env("FUNC_PROJECT_ID"),
        firebase_api_key=_env("FUNC_FIREBASE_API_KEY"),
        resident_email=_env("FUNC_RESIDENT_EMAIL"),
        resident_password=_env("FUNC_RESIDENT_PASSWORD"),
        facility_id=_env("FUNC_FACILITY_ID"),
        expect_build_id=_env("FUNC_EXPECT_BUILD_ID"),
        skip_agent=_env("FUNC_SKIP_AGENT") in ("1", "true", "yes"),
        skip_booking=_env("FUNC_SKIP_BOOKING") in ("1", "true", "yes"),
    )


@pytest.fixture(scope="session")
def http() -> httpx.Client:
    with httpx.Client(timeout=45.0, follow_redirects=True) as client:
        yield client


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


def firebase_id_token(api_key: str, email: str, password: str) -> str:
    """Exchange email/password for Firebase ID token (Identity Toolkit)."""
    url = (
        "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword"
        f"?key={api_key}"
    )
    r = httpx.post(
        url,
        json={
            "email": email,
            "password": password,
            "returnSecureToken": True,
        },
        timeout=30.0,
    )
    data = r.json()
    token = data.get("idToken")
    if not token:
        raise AssertionError(
            f"Firebase sign-in failed for {email}: "
            f"status={r.status_code} body={data}"
        )
    return token


@pytest.fixture(scope="session")
def resident_token(cfg: FuncConfig) -> str:
    if not cfg.firebase_api_key or not cfg.resident_email or not cfg.resident_password:
        pytest.skip(
            "FUNC_FIREBASE_API_KEY + FUNC_RESIDENT_EMAIL + FUNC_RESIDENT_PASSWORD required"
        )
    return firebase_id_token(
        cfg.firebase_api_key, cfg.resident_email, cfg.resident_password
    )


@pytest.fixture(scope="session")
def auth_headers(resident_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {resident_token}"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def api_get(
    client: httpx.Client,
    origin: str,
    path: str,
    headers: dict[str, str] | None = None,
) -> httpx.Response:
    return client.get(f"{origin}{path}", headers=headers or {})


def api_json(
    client: httpx.Client,
    origin: str,
    method: str,
    path: str,
    headers: dict[str, str] | None = None,
    **kwargs: Any,
) -> tuple[httpx.Response, Any]:
    r = client.request(method, f"{origin}{path}", headers=headers or {}, **kwargs)
    try:
        body = r.json()
    except Exception:
        body = r.text
    return r, body


def fetch_spa_index_js(client: httpx.Client, origin: str) -> str:
    """Download main SPA bundle text from origin (GCS via LB)."""
    html = client.get(f"{origin}/").text
    m = re.search(r'src="(/assets/index-[^"]+\.js)"', html)
    assert m, f"No index-*.js in SPA HTML from {origin}"
    return client.get(f"{origin}{m.group(1)}").text


def pick_facility_id(
    client: httpx.Client,
    origin: str,
    headers: dict[str, str],
    configured: str,
) -> str:
    if configured:
        return configured
    r, body = api_json(client, origin, "GET", "/api/v1/facilities", headers=headers)
    assert r.status_code == 200, body
    items = body.get("items") or body.get("facilities") or body
    if isinstance(items, dict):
        items = items.get("items", [])
    assert isinstance(items, list) and items, f"No facilities returned: {body}"
    # Prefer active
    for it in items:
        if it.get("active", True):
            return it["id"] if "id" in it else it.get("facility_id")
    return items[0].get("id") or items[0]["facility_id"]
