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
    platform_admin_email: str
    platform_admin_password: str
    tenant_admin_email: str
    tenant_admin_password: str
    facility_id: str
    expect_build_id: str
    skip_agent: bool
    skip_booking: bool
    skip_mutations: bool
    skip_concurrency: bool
    skip_voice: bool
    concurrency_n: int

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


def _flag(name: str) -> bool:
    return _env(name) in ("1", "true", "yes")


@pytest.fixture(scope="session")
def cfg() -> FuncConfig:
    base = _env("FUNC_BASE_DOMAIN")
    if not base:
        pytest.skip(
            "FUNC_BASE_DOMAIN not set — run ./scripts/run_functional.sh "
            "or source tests/functional/.env.local"
        )
    n_raw = _env("FUNC_CONCURRENCY_N", "10")
    try:
        conc_n = max(2, min(int(n_raw or "10"), 30))
    except ValueError:
        conc_n = 10
    return FuncConfig(
        base_domain=base,
        admin_host=_env("FUNC_ADMIN_HOST", f"admin.{base}"),
        tenant_slug=_env("FUNC_TENANT_SLUG", "marina-skies"),
        project_id=_env("FUNC_PROJECT_ID"),
        firebase_api_key=_env("FUNC_FIREBASE_API_KEY"),
        resident_email=_env("FUNC_RESIDENT_EMAIL"),
        resident_password=_env("FUNC_RESIDENT_PASSWORD"),
        platform_admin_email=_env("FUNC_PLATFORM_ADMIN_EMAIL"),
        platform_admin_password=_env("FUNC_PLATFORM_ADMIN_PASSWORD"),
        tenant_admin_email=_env("FUNC_TENANT_ADMIN_EMAIL"),
        tenant_admin_password=_env("FUNC_TENANT_ADMIN_PASSWORD"),
        facility_id=_env("FUNC_FACILITY_ID"),
        expect_build_id=_env("FUNC_EXPECT_BUILD_ID"),
        skip_agent=_flag("FUNC_SKIP_AGENT"),
        skip_booking=_flag("FUNC_SKIP_BOOKING"),
        skip_mutations=_flag("FUNC_SKIP_MUTATIONS"),
        skip_concurrency=_flag("FUNC_SKIP_CONCURRENCY"),
        skip_voice=_flag("FUNC_SKIP_VOICE"),
        concurrency_n=conc_n,
    )


@pytest.fixture(scope="session")
def http() -> httpx.Client:
    with httpx.Client(timeout=60.0, follow_redirects=True) as client:
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


def firebase_sign_in_result(api_key: str, email: str, password: str) -> dict[str, Any]:
    """Full Identity Toolkit response (includes idToken or error)."""
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
    return r.json()


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


@pytest.fixture(scope="session")
def platform_admin_token(cfg: FuncConfig) -> str:
    if not cfg.firebase_api_key or not cfg.platform_admin_email or not cfg.platform_admin_password:
        pytest.skip(
            "FUNC_PLATFORM_ADMIN_EMAIL + FUNC_PLATFORM_ADMIN_PASSWORD required"
        )
    return firebase_id_token(
        cfg.firebase_api_key, cfg.platform_admin_email, cfg.platform_admin_password
    )


@pytest.fixture(scope="session")
def platform_headers(platform_admin_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {platform_admin_token}"}


@pytest.fixture(scope="session")
def tenant_admin_token(cfg: FuncConfig) -> str:
    if not cfg.firebase_api_key or not cfg.tenant_admin_email or not cfg.tenant_admin_password:
        pytest.skip(
            "FUNC_TENANT_ADMIN_EMAIL + FUNC_TENANT_ADMIN_PASSWORD required"
        )
    return firebase_id_token(
        cfg.firebase_api_key, cfg.tenant_admin_email, cfg.tenant_admin_password
    )


@pytest.fixture(scope="session")
def tenant_admin_headers(tenant_admin_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {tenant_admin_token}"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


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
    for it in items:
        if it.get("active", True):
            return it["id"] if "id" in it else it.get("facility_id")
    return items[0].get("id") or items[0]["facility_id"]


def require_mutations(cfg: FuncConfig) -> None:
    if cfg.skip_mutations:
        pytest.skip("FUNC_SKIP_MUTATIONS=1")
