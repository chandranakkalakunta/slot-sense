"""Voice agent smoke (F8) — optional; needs resident + audio fixture."""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest

pytestmark = pytest.mark.functional

_REPO = Path(__file__).resolve().parents[2]
_DEFAULT_WAV = _REPO / "resources" / "voice_fixtures" / "synthetic_tone.wav"


def test_voice_endpoint_accepts_audio(
    http: httpx.Client, cfg, auth_headers: dict[str, str]
) -> None:
    """POST /agent/voice with a tiny wav — expect not LOCK_UNAVAILABLE / not 401.

    Synthetic tone may fail STT gracefully; we only assert env wiring
    (auth, route, Speech/Vertex reachable enough to return structured error or reply).
    """
    if cfg.skip_voice:
        pytest.skip("FUNC_SKIP_VOICE=1")
    if not _DEFAULT_WAV.is_file():
        pytest.skip(f"missing voice fixture {_DEFAULT_WAV}")

    audio = _DEFAULT_WAV.read_bytes()
    # Resident-only endpoint
    files = {"audio": ("tone.wav", audio, "audio/wav")}
    r = http.post(
        f"{cfg.tenant_origin}/api/v1/agent/voice",
        headers=auth_headers,
        files=files,
        timeout=90.0,
    )
    if r.status_code == 403:
        # Role may be tenant_admin in FUNC_RESIDENT_* — skip
        try:
            code = r.json().get("code")
        except Exception:
            code = None
        pytest.skip(f"voice requires resident role ({code})")

    if r.status_code == 503:
        try:
            code = r.json().get("code")
        except Exception:
            code = None
        assert code != "LOCK_UNAVAILABLE", r.text

    # 200 with body, or 422/400 STT failure still proves route is wired
    assert r.status_code in (200, 400, 422, 500), r.text
    if r.status_code == 200:
        body = r.json()
        assert "reply_text" in body or "transcript" in body, body
