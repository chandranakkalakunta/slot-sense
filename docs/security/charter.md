# Security Charter — SportSlot Reservation

**Version:** 1.6 | **Date:** 2026-07-21 | **Author:** Chandra Nakkalakunta

## Principles

1. **Defense-in-Depth** — No single control trusted alone. Tenant isolation has 5 layers (ADR-0004). Auth checks both JWT and URL.
2. **Least Privilege** — 4 separate service accounts, each scoped to its function. Permissions added per phase, never "just in case."
3. **Secure by Default** — Firestore starts deny-all. Endpoints require auth by default. Org policy blocks JSON key creation.
4. **Zero Static Credentials** — No JSON keys anywhere. ADC for local dev, WIF for CI/CD, attached SA for Cloud Run.
5. **Privacy by Design** — No PII in logs. SHA-256 hashed IDs in analytics. Per-country data residency. DPDP Act compliant.
6. **Fail Closed** — Redis down → bookings pause (not bypass). Auth fails → 401 (not anonymous access).
7. **Verify, Don't Trust** — Every phase independently validated. JWT verified every request. CI gates block unverified deploys.

When principles conflict: Privacy > Fail Closed > Defense-in-Depth > Zero Credentials > Least Privilege > Secure by Default > Verify.

## Identity & Credential Model

- **admin@chandraailabs.com** — sole human cloud-management identity (gcloud, GCP Console, org administration). MFA hardening is a Phase 17 accepted residual — see [ADR-0039](../adr/0039-accepted-production-hardening-residuals.md) (status corrected 2026-07-16, DOC-TRUTH; was "Phase 8").
- **chandra.n@chandraailabs.com** — email and git identity (commits, correspondence). No cloud credentials.
- **Application credentials** — never a human identity. Local development uses ADC via service account impersonation (sa-firebase-admin); CI/CD uses WIF (sa-cloud-build); runtime uses the attached service account (sa-cloud-run). A development server never holds org-admin powers.

## Threat Model

**In scope (Tier 1+2):** Curious residents manipulating URLs, disgruntled users hoarding slots, tenant admins trying cross-tenant access, credential stuffing, API scraping, OWASP Top 10, compromised dependencies, DDoS during peak booking.

**Noted but not exhaustively defended (Tier 3):** Organized cybercrime, supply chain attacks (mitigated by Bandit SAST + pip-audit [warn-only] + Gitleaks secret scanning [blocking]; Binary Authorization planned — Phase 17 PR-5) (status corrected 2026-07-16, DOC-TRUTH).

**Out of scope (Tier 4):** Nation-state / APT. SportSlot is residential community SaaS, not critical infrastructure.

**Acceptable risks:** Google-managed encryption. CMEK, VPC + Cloud NAT for Cloud Run, and admin MFA are deferred as accepted residual risk — see [ADR-0039](../adr/0039-accepted-production-hardening-residuals.md) (status corrected 2026-07-16, DOC-TRUTH; supersedes this section's prior "Phase 8" framing). No MFA for residents in v1. No dedicated SOC (alerts + runbooks are proportionate). Up-to-1-hour stale JWT custom claims on non-sensitive endpoints (ADR-0007, Decision 3).

## Security Controls by Phase

### Already Done (Phase 1)
- Zero JSON keys (org policy enforced)
- 4 least-privilege service accounts
- Workload Identity Federation (main branch only)
- Firebase Auth (Email/Password + Google OAuth)
- Firestore deny-all security rules
- ADC authentication pattern

### Phase 2 — Backend Foundation
- Security headers (HSTS, CSP, X-Frame-Options, X-Content-Type-Options)
  — **Implemented** (`SecurityHeadersMiddleware`,
  `backend/src/sport_slot/middleware/security_headers.py`; ADR-0043
  PR-5a, `SEC-HEADERS`) (status corrected 2026-07-21, PR-5a)
- ~~CORS strict policy (subdomain-aware)~~ — **corrected, not a gap**
  (verified 2026-07-21, PR-5a): no `CORSMiddleware` exists, and none
  is needed. The load balancer routes `*.slotsense.chandraailabs.com`
  path-based — `/api/*`, `/health`, `/readyz`, `/version` to the
  Cloud Run backend, everything else to the frontend bucket
  (`terraform/load_balancer_routing.tf`, Phase 8b) — so the browser
  sees frontend and API as the **same origin** per tenant subdomain.
  A same-origin architecture is a stronger posture than a CORS policy
  would add, not a missing control; this line was aspirational
  framing predating the Phase 8b routing design, not a real gap.
- Rate limiting (per-user, per-IP, per-tenant)
- JWT validation middleware with tenant cross-check
- PII redaction in logs (no emails, no JWT contents)
- Request ID on every response for tracing
- Pydantic input validation on all endpoints
- Repository pattern enforcing tenant_id (ADR-0004 Layer 2)
- Firestore Security Rules with tenant_id enforcement (ADR-0004 Layer 1)

### Phase 3 — Booking Engine
- Per-user/household booking quotas (anti-hoarding)
- Redis distributed lock (anti-double-booking, ADR-0002)
- Booking cancellation rate limiting
- Audit logging for all booking mutations

### Phase 5 — CI/CD

Status corrected 2026-07-16 (DOC-TRUTH) — this section previously
claimed all items below as a single undifferentiated "Phase 5" plan;
only some have actually been built:

- Bandit SAST for Python — **Implemented** (`.github/workflows/pr-gates.yml`)
- pip-audit for Python CVE scanning — **Implemented, warn-only** (`continue-on-error`; ratchets to blocking per backlog `CI-AUDIT-RATCHET`)
- Secret scanning (Gitleaks) — **Implemented, blocking**
- Binary Authorization (deploy-time image verification) — Planned — Phase 17 PR-5
- KMS signing in Cloud Build pipeline — Planned — Phase 17 PR-5
- pnpm audit for Node CVE scanning — Planned — Phase 17 PR-5
- Container vulnerability scanning (gate before deploy) — Planned — Phase 17 PR-5

PASS-before-merge applies today to the implemented gates above
(Bandit, Gitleaks); pip-audit is warn-only and the remaining planned
scans are not yet deploy-blocking.

### Phase 7 — Performance
- Cloud Armor Standard (DDoS protection)
- WAF rules (OWASP pre-configured rules)
- Geographic restrictions (India-only for India deployment)
- Edge rate limiting

### Phase 8 — Production Readiness

Status corrected 2026-07-16 (DOC-TRUTH) — "Production Readiness" work
did not land at Phase 8 as originally planned; it is actually
underway now as Phase 17 (ADR-0038, ADR-0039):

- Delete protection enabled on Firestore — **Implemented** (ADR-0038, PR-1a)
- Point-in-time recovery enabled — **Implemented** (ADR-0038, PR-1a)
- CMEK for Firestore, Secret Manager, Cloud Storage; VPC for Cloud Run + Cloud NAT; MFA for tenant_admin/platform_admin; penetration testing — **Deferred accepted residuals**, see [ADR-0039](../adr/0039-accepted-production-hardening-residuals.md)
- Incident response runbook — not yet written (see this charter's own Incident Response section for the interim process)
- DPDP Act compliance formalization — pending (Phase 16 DPDP self-assessment, backlog `SEC-01`)

## DPDP Act Compliance

**Data we collect:** Name, email, phone, flat number, booking history.

**What we commit to:**
- Data stored in India (asia-south1) for Indian residents
- No PII in analytics — SHA-256 hashed identifiers only
- Right to deletion — resident can request account + data deletion
- Right to export — resident can download their data
- Consent at signup — clear terms before account creation
- Breach notification — within 72 hours per DPDP requirements
- No data sold or shared with third parties

## Incident Response

**Severity levels:**
- **SEV-1:** Cross-tenant data leak, credential compromise, data breach → Respond within 1 hour
- **SEV-2:** Single-tenant disruption, auth system failure → Respond within 4 hours
- **SEV-3:** Rate limiting triggered, suspicious activity detected → Respond within 24 hours
- **SEV-4:** Non-critical security finding, dependency CVE → Respond within 1 week

**Response process:** Detect → Contain → Investigate → Remediate → Document → Review.

**Communication:** SEV-1/2 notify affected tenants. SEV-1 triggers DPDP breach notification if PII involved.

## Org-Policy Exceptions

| Constraint | Scope | Setting | Rationale | Review |
|------------|-------|---------|-----------|--------|
| iam.allowedPolicyMemberDomains | project sport-slot-dev only | allowAll | Public booking API requires allUsers run.invoker; app-layer JWT auth + deny-all Firestore stand behind it | At PROD setup: PROD project decides fresh, with Cloud Armor fronting (status corrected 2026-07-16, DOC-TRUTH; was "Phase 8") |

Org default remains restrictive for all other projects. Granting
roles/orgpolicy.policyAdmin to admin@ (org-level, 2026-06-11) is
recorded as part of the identity model.

## Accepted Exposures (time-boxed)

| Exposure | Risk | Mitigation in place | Closure |
|----------|------|---------------------|---------|
| Cloud Run service (sport-slot-api) accepts public unauthenticated ingress at its run.app URL, bypassing Firebase Hosting | Infrastructure-layer abuse (DoS, error-surface probing) not gated by the Hosting CDN/edge | App-layer enforces Firebase JWT auth + tenant isolation on every endpoint; JWT is the authoritative tenant source so X-Forwarded-Host spoofing on direct calls cannot cross tenants (ADR-0007, ADR-0012 §2) | Phase 7: Global External Load Balancer + Cloud Armor; set Cloud Run ingress to internal-and-cloud-load-balancing so traffic must transit the LB. Interim option logged: Hosting-injected shared-secret header checked by the backend. |
| Platform-admin tokens accepted on any host in DEV (no admin-host segregation) | A leaked platform-admin token could be replayed against any host | Route+role gating (require_platform_admin) enforces authorization; platform tokens carry tenant_id=null and cannot act within a tenant's data path | Phase 9: dedicated admin host + host-segregation in the cross-check (ADR-0007 original intent), behind the load balancer |

## Review Schedule

- **Quarterly:** Review charter for currency
- **After incidents:** Update based on lessons learned
- **Before major releases:** Verify new features satisfy principles
- **When compliance requirements change:** Update DPDP section

## Related Documents

- ADR-0004: Tenant Isolation Strategy (5-layer defense-in-depth)
- ADR-0002: Database Technology (distributed locks, per-country deployment)
- ADR-0005: Cost Baseline (budget for security infrastructure)
- ADR-0006: API Design Patterns (error envelope, request ID tracing)
- ADR-0007: Authentication & Authorization (JWT verification, claims staleness, admin isolation, rate limiting)
- Phase-specific ADRs will reference this charter

## Changelog

- **1.6 (2026-07-21, PR-5a):** Security headers claim flipped
  Planned → Implemented (`SecurityHeadersMiddleware`; `SEC-HEADERS`
  closed). CORS strict-policy claim corrected: no `CORSMiddleware`
  exists or is needed — the load balancer's path-based routing
  (`terraform/load_balancer_routing.tf`, Phase 8b) puts frontend and
  API on the same origin per tenant subdomain, a stronger posture
  than a CORS policy would add. ADR-0043.
- **1.5 (2026-07-16, DOC-TRUTH):** Reconciled Phase 5/8 control claims
  with actual CI/infra enforcement — Bandit, pip-audit (warn-only),
  and Gitleaks (blocking) are implemented; Binary Auth, KMS signing,
  pnpm audit, and container scanning downgraded to "Planned — Phase
  17 PR-5"; CMEK/VPC+NAT/admin MFA/pen test point to ADR-0039
  (accepted residuals) instead of a stale "Phase 8" claim; Firestore
  delete protection + PITR marked implemented (ADR-0038, PR-1a).
  Phase 2's "security headers" claim downgraded to Planned — grepped
  the app middleware stack (`backend/src/sport_slot/main.py`) and
  found no HSTS/CSP/X-Frame-Options implementation; tracked as
  backlog `SEC-HEADERS`.
- **1.4 (2026-06-14):** Accepted Exposures — admin-host segregation deferred to Phase 9; route+role gating (require_platform_admin) is the DEV authorization layer per ADR-0014 §1.
- **1.3 (2026-06-13):** Accepted Exposures section — Cloud Run direct ingress logged; Phase 7 LB closure path documented.
- **1.2 (2026-06-12):** Org-policy exceptions section (domain-restricted-sharing override for sport-slot-dev); corrects fabricated v1.2 content from interrupted session.
- **1.1 (2026-06-11):** Added Identity & Credential Model section; recorded accepted claims-staleness risk; added ADR-0006/0007 references.
- **1.0 (2026-06-10):** Initial charter.
