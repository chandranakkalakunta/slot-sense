"""S-PERF latency sample — measure health p95 (no aspirational gate)."""

from __future__ import annotations

import statistics
import time

import httpx
import pytest

pytestmark = pytest.mark.functional


def test_health_latency_sample(http: httpx.Client, cfg) -> None:
    """Record N health samples; always pass but print p50/p95 for baseline.

    ADR-0045: measure first, gate later. Fail only on hard errors (non-200).
    """
    n = 15
    samples_ms: list[float] = []
    url = f"{cfg.admin_origin}/health"
    for _ in range(n):
        t0 = time.perf_counter()
        r = http.get(url)
        dt = (time.perf_counter() - t0) * 1000
        assert r.status_code == 200, r.text
        samples_ms.append(dt)

    samples_ms.sort()
    p50 = statistics.median(samples_ms)
    # nearest-rank p95
    idx = min(len(samples_ms) - 1, max(0, int(round(0.95 * (len(samples_ms) - 1)))))
    p95 = samples_ms[idx]
    p99_idx = min(len(samples_ms) - 1, max(0, int(round(0.99 * (len(samples_ms) - 1)))))
    p99 = samples_ms[p99_idx]
    print(
        f"\n[S-PERF] health latency n={n} "
        f"p50={p50:.1f}ms p95={p95:.1f}ms p99={p99:.1f}ms "
        f"min={samples_ms[0]:.1f}ms max={samples_ms[-1]:.1f}ms"
    )
    # Soft sanity: p95 under 5s (infra dead, not SLO)
    assert p95 < 5000, f"health p95 too high: {p95:.1f}ms"
