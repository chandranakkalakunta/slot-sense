# ADR-0043: Security Hardening

- **Status:** Accepted
- **Date:** 2026-07-21
- **Phase:** 17 — Production Readiness / PR-5 (split 5a + 5b)
- **Related:** ADR-0039 (accepted residuals), DOC-TRUTH (CI gates,
  charter reconciliation), baseline audit 2026-07-13 (findings #7, #9,
  #10), PROJECT_REVIEW 2026-07-15, docs/backlog.md (PR-5-SECURITY,
  WIF-LEAST-PRIV, SEC-HEADERS, CONTAINERREGISTRY-CLEANUP,
  CI-AUDIT-RATCHET)

## Context

The audit found the security posture claimed in docs outrunning what
is enforced: Cloud Armor non-enforcing everywhere (API policy
preview-only; frontend-edge policy with zero rules), CI scanning
limited to Bandit + (post-DOC-TRUTH) pip-audit/gitleaks, no container
or dependency scanning of the image, Binary Authorization off, no
secret rotation policy, the GitHub WIF principal holding project-level
storage.admin + run.admin, and a legacy containerregistry API enabled.
DOC-TRUTH already made the docs honest about these gaps; this ADR
closes the gaps themselves — the ones worth closing at this stage.

## Decision — split into two PRs by blast radius

### PR-5a — Low-risk hardening (code + CI + cleanup)

1. **Security headers** (SEC-HEADERS): server-side middleware adding
   HSTS, X-Content-Type-Options, X-Frame-Options/frame-ancestors CSP,
   Referrer-Policy, and a baseline Content-Security-Policy. Verified
   by test + live curl of response headers. Also audit and correct the
   charter's CORS claim (flagged in DOC-TRUTH).
2. **Container/dependency scanning in CI**: add Trivy (or equivalent)
   image scan on build; add frontend dependency audit (pnpm/npm audit)
   mirroring the pip-audit pattern. Non-blocking (warn) initially per
   the measured-gates principle; CI-AUDIT-RATCHET tracks flipping to
   blocking after a triage pass.
3. **containerregistry API cleanup** (CONTAINERREGISTRY-CLEANUP):
   disable the legacy containerregistry.googleapis.com (Artifact
   Registry is the real registry; no images in the legacy one —
   verify empty first).
4. **Secret rotation policy** (doc-level): a runbook section defining
   rotation cadence and procedure for redis-auth and resend-api-key,
   building on ADR-0038's recovery inventory. Policy + procedure, not
   automation.

### PR-5b — Risk-sensitive (Cloud Armor + WIF IAM)

1. **Cloud Armor enforcement decision** (finding #7): review the
   preview-mode logs on the API policy to confirm rules aren't
   false-positiving on legitimate traffic, THEN flip preview→enforce.
   The frontend-edge policy (currently zero rules) gets a baseline
   ruleset or is documented as intentionally pass-through. This is a
   traffic-affecting change — staged, with the preview-log review as
   the gate, and immediate rollback (flip back to preview) if
   legitimate traffic is blocked.

   **Outcome (2026-07-21, PR-5b review → PR-5c decision):** the
   preview-log review (`docs/reviews/2026-07-21-armor-preview-log-
   review.md`) found, over a complete 14-day window, that 100% of the
   75 preview-flagged-but-accepted requests were legitimate
   `/api/v1/agent/voice` traffic from a real tenant — large base64
   audio payloads false-positiving on the generic OWASP CRS SQLi/XSS
   body-inspection signatures. Zero attack traffic in the population.
   **Coordinator decision: option 2.** `terraform/cloud_armor.tf`
   (PR-5c) adds a higher-priority `allow` rule
   (`priority = 900`, matching `request.path.matches
   ('/api/v1/agent/voice')`) ahead of the SQLi rule (1000) and XSS
   rule (2000); Cloud Armor evaluates rules in priority order and
   stops at the first match, so a matching request never reaches the
   WAF rules. The two WAF rules then flip `preview = true` → enforcing
   (match expressions, priorities, and actions unchanged) — every
   other path gets real SQLi/XSS enforcement immediately.

   **ACCEPTED RESIDUAL, documented not silent:** the voice path is
   thereby exempt from WAF body inspection. Its SQLi/XSS defense is
   NOT the WAF but field-level input validation and safe sinks
   (Firestore is non-SQL; transcribed text is validated in code;
   the frontend escapes agent output before rendering). Closing that
   gap durably — auditing the voice→STT→agent path end to end and
   confirming every sink is safe — is tracked as backlog
   `VOICE-INPUT-VALIDATION`, scoped to the Phase 18 launch gate, not
   this PR.

   `frontend_edge` is unmodified: documented as intentional
   pass-through, not a baseline ruleset, because `CLOUD_ARMOR_EDGE`
   structurally cannot hold `evaluatePreconfiguredWaf` expressions
   (confirmed via a prior apply-time API error, PR-5b) — a baseline
   WAF ruleset there was never an available option, only the
   documented-pass-through half of the original "or" is real.
2. **WIF least-privilege** (WIF-LEAST-PRIV): tighten the GitHub WIF
   principal from project-level storage.admin + run.admin to the
   minimum the CI pipeline actually uses (bucket-scoped storage roles;
   run.developer or a custom role instead of run.admin). Derived from
   observed CI behavior, imported/changed as IAM — Coordinator runs
   every apply, full diff review.

### Explicitly deferred (already decided, not reopened here)

- **Binary Authorization**: remains a documented PR-5+ candidate, NOT
  implemented now. It requires an attestation pipeline (signing in CI,
  policy enforcement on deploy) that is disproportionate before a
  production launch; folded into Phase 18 launch-gate consideration.
  The charter already reflects this as "planned," corrected in
  DOC-TRUTH.
- **CMEK / VPC / MFA / pen test**: ADR-0039 residuals, untouched.

## Alternatives considered

1. One large PR-5 — rejected: mixes zero-risk CI/doc changes with
   traffic-affecting Armor enforcement; the split lets 5a merge fast
   and isolates 5b's blast radius for careful review.
2. Binary Authorization now — rejected (disproportionate; Phase 18).
3. Blocking CI scans from day one — rejected: measured-gates; warn,
   triage, then ratchet.

## Cost impact (§4.5)

CI scan minutes: negligible. Armor rules: already provisioned
(enforcement is a mode flip, not new infra). No new recurring cost.

## Consequences

- Finding #7 (Armor) closes as of PR-5c: the API policy's SQLi/XSS
  rules enforce, with the voice path's exemption and its residual
  risk explicitly documented and tracked (`VOICE-INPUT-VALIDATION`),
  not silently accepted. Finding #9 (CI scanning) closed at PR-5a;
  #10 (rotation) partially closes (policy defined; automation
  deferred).
- WIF blast radius shrinks from project-admin to task-scoped (PR-5b).
- Binary Authorization becomes the one named security item carried
  explicitly into Phase 18 rather than silently dropped.
- The security charter, already made honest in DOC-TRUTH, now has
  the enforcement behind its remaining claims.
- With PR-5c, this closes the last of the ten 2026-07-13 baseline
  audit findings — the DR drill (ADR-0038) is the one item left
  outstanding project-wide.
