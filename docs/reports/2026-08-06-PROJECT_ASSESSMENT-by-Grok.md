# SlotSense — Project Assessment Report

| Field | Value |
|-------|--------|
| **Product** | SlotSense (repo: `sport-slot-reservation` / workspace `slot-sense`) |
| **Owner** | Chandra Nakkalakunta · Chandra AI Labs |
| **Assessment date** | 2026-08-06 |
| **Assessment type** | Close-out / due-diligence style architecture & product review |
| **Evidence basis** | Repository state on `main` (and local working tree notes called out explicitly); live soak reports in repo root; ADRs 0001–0047; phase retros; backlog; security charter; DR drill Pass 1 |
| **Intended audience** | Advisor, potential co-founder, internal reference, architecture / diligence conversation |
| **Prior review** | Third-party snapshot 2026-07-15 (`docs/reviews/2026-07-15-PROJECT_REVIEW*.md`) — this report supersedes that snapshot for **current** posture where evidence has moved |

---

## Executive summary

SlotSense is a **multi-tenant SaaS for Indian residential community sports-facility booking**, differentiated by a **natural-language AI booking assistant** (text + voice) with a deliberate **propose → confirm → execute** safety model so the LLM never directly mutates booking state. The product surface is real: resident booking, policy, platform/tenant admin, branding, invoices, agent, and voice.

**Engineering maturity is unusually high for a pre-revenue, single-operator build.** Strengths that would survive diligence:

1. **Five-layer tenant isolation** (Firestore deny-all, repository `TenantContext`, JWT×host cross-check, automated cross-tenant tests, architecture CI gates) — ADR-0004.
2. **AI agent safety architecture** as first-class design (ADRs 0021–0027): tool orchestration over existing services, Redis pending actions with TTL, output/hallucination guards, deterministic Python guards.
3. **ADR discipline and honest backlog** (47 ADRs, phase retrospectives, explicit deferred residuals in ADR-0039).
4. **Keyless CI/CD** (Workload Identity Federation; no long-lived JSON keys by design) and progressive multi-env promotion (ADR-0045 / ADR-0046).
5. **Measured load evidence** on test (Aug 2026 soak / community-day profiles) with **zero double-book in lock-proof waves** and Cloud Run scaling observed to `maxScale` 10.
6. **Production-readiness build complete for Phase 17** (backup/PITR, observability baseline, budgets, Armor enforce, IAM codification) with a **successful empty-project rebuild drill** inside the 4h RTO target (machine time ~28 min; full RTO script still to capture cleanly).

**It is not yet “customer production ready” without closing a short list of P0 gaps.** The system is portfolio- and test-env capable; first paying tenant should not board until voice production gates, DPDP counsel check, SPA edge robustness, promote automation completeness, and operator succession risk are addressed.

### Scorecard (2026-08-06)

Scores are relative to **pre-revenue SaaS aiming for first real tenants**, not FAANG multi-region standards.

| Dimension | Score (1–5) | One-line judgment |
|-----------|-------------|-------------------|
| Product completeness (core booking + admin) | **4.3** | Core journeys exist; channels (WhatsApp/payments) still open |
| UX / operability | **4.0** | Design system + density work solid; IA is role-clear |
| Multi-platform (web/PWA/mobile web) | **3.8** | Strong PWA web; no native apps (acceptable for stage) |
| Accessibility | **3.7** | Automated axe suite; limited real AT / mobile a11y proof |
| i18n readiness | **2.5** | Architecture anticipates locales; English-only UI, INR-centric |
| Security | **4.0** | Isolation + WIF + Armor strong; CMEK/MFA/pen-test deferred by ADR |
| Scalability | **3.5** | Single-region, Redis BASIC SPOF accepted; soak proved headroom |
| Availability / DR | **3.7** | RTO/RPO defined; drill PASS; Redis HA deferred; 99% SLO doc-level |
| Performance | **3.4** | Measured baselines exist; p95 not yet a promote gate |
| Testability | **4.0** | Hermetic excellent; live S-FUNC + thin Playwright; promote path defined |
| Maintainability | **4.5** | Layering + ADRs are a standout |
| Observability | **3.6** | Baseline shipped (PR-2/3); SLO burn-rate API not wired; apply drift risk historically |
| Extensibility | **3.8** | Tenant/policy/catalog models extend well; new geos need residency plan |
| DevOps / promotion | **3.8** | Multi-env + same-SHA design; residual script/env parity issues |
| FinOps | **4.2** | Ceilings, budgets, env-power sleep/wake (ADR-0047) — rare discipline |
| Documentation | **4.7** | Among the strongest assets in the repo |
| Multi-tenancy maturity | **4.5** | Isolation model exemplary for stage |
| Compliance / DPDP | **3.0** | Intent documented; SEC-01 counsel check open; voice path geo nuance |
| AI/ML governance | **4.0** | Safety design strong; model/eval ops still thin |
| Business continuity (solo-op) | **2.0** | Single human SPOF — the dominant strategic risk |
| **Overall engineering** | **~4.2** | Same ballpark as Jul-15 review; ops evidence improved |
| **Customer-prod readiness** | **~3.2** | Up from ~2.8 (Jul-15) after Phase 17 + multi-env + soak; still pre-launch |

### Bottom line

**Build quality and architectural intentionality exceed typical early-stage SaaS.**  
**Go-to-market readiness is gated by ops completeness, compliance checkboxes, channel product work, and the fact that one person holds all keys, runbooks, and context.**

This report is written so a co-founder or advisor can use it as a diligence pack: each section states **current state (with evidence)**, **gaps**, **risks**, and **recommendations**. Section E prioritizes work for **pre-revenue solo** vs **post-launch scale**.

---

## How this assessment was conducted

- **Primary evidence:** ADRs (`docs/adr/0001`–`0047`), security charter, REQUIREMENTS, TEST-STRATEGY, backlog, phase 17 close-out, DR drill Pass 1, soak/community JSON reports at repo root, Terraform modules, GitHub workflows, frontend a11y suite, Playwright e2e, functional tests inventory.
- **Not done in this pass:** formal pen-test, WCAG manual audit with AT users, live billing invoice pull, multi-region failover test, third-party legal opinion on DPDP.
- **Honesty rule:** where docs and code historically drifted, this report prefers **backlog/ADR “status corrected” language** and measured drill/soak artifacts over marketing claims in older README rows.
- **Local uncommitted note (2026-08-06):** SPA LB path rewrites for exact client routes were applied live on `slot-sense-test-03` and drafted in `terraform/load_balancer_routing.tf` / `load_balancer_backends.tf` but may not yet be on `origin/main` at report freeze — treat as **known fix in flight** under Performance / Availability.

---

# Section A — Product & Experience

## A.1 Operability (UI/UX, information architecture, workflow ergonomics)

### Current state (evidence)

- **Design system:** Tailwind v4 + shadcn/ui (Radix), Inter typeface, light/dark mode, ADR-0028 (design system/theming), Phase 10 retrospective and README claims of portfolio-quality UI.
- **IA by role:**
  - **Resident:** facilities → availability/date → book; my bookings; invoices; account; AI assistant (text/voice).
  - **Tenant admin:** facilities, branding, policies, users, daily overview, invoices.
  - **Platform admin:** tenant list, facility catalog, create tenant/user flows.
- **Co-branding hierarchy (ADR-0029):** tenant brand primary in header; SlotSense secondary (“powered by”).
- **Workflow ergonomics:** force-password gate on first login; 6-digit initial credentials (ADR-0044); bulk user provision; catalog-driven facilities reduce free-text chaos.
- **Density/list UX:** iterative Phase 10.6 work + later admin natural sort / denser rows (PR #199 lineage) — shows product care for operational screens, not only marketing UI.

### Gaps

- Some residual UX polish items remain open in backlog (e.g. facility name header on availability page `RES-01`).
- WhatsApp/SMS as **primary resident channel** (REQUIREMENTS) is not the live UX path — email + web/PWA is.
- No formal UX research / usability sessions with society managers documented in-repo.

### Risks

- Society managers expect WhatsApp-native flows; web-only can slow adoption even if engineering is excellent.
- Force-password + seed credential flows are operationally correct but easy to misconfigure in new envs (functional suite covers part of this).

### Recommendations

- **P1:** One scripted “day in the life” video or checklist for tenant admin + resident (onboarding friction test).
- **P2:** Close cosmetic backlog items before demos; treat density/sort as done unless regressions appear.
- **Post-launch:** society-manager interviews before investing in native apps.

---

## A.2 Multi-platform support

### Current state

| Surface | Status | Evidence |
|---------|--------|----------|
| Responsive web | Yes | Phase 10; mobile/tablet/desktop layout work in retros |
| PWA install | Yes | `vite-plugin-pwa`, icons, Workbox, ADR-0029/PWA cache strategy in CHANGELOG |
| iOS/Android home-screen | Supported via PWA | Install prompts claimed; not separately automated in CI |
| Native iOS/Android apps | **No** | Out of scope for current phase set |
| Desktop browser | Yes | Playwright Chromium smoke |

### Gaps

- No App Store / Play Store presence; push notification channel is not a first-class product surface.
- PWA offline is limited (booking is online-first by nature); SW strategy optimizes cache correctness more than offline UX.
- Browser E2E is Chromium-only (`tests/e2e/playwright.config.ts`).

### Risks

- Enterprise societies may ask for “the app”; PWA education is required in sales materials.
- iOS PWA quirks (storage, install, notifications) are not systematically regression-tested.

### Recommendations

- **Pre-revenue:** Keep PWA; document install steps per platform in a one-pager for tenants.
- **P1:** Add WebKit/Firefox smoke later only if field bugs appear — not a launch blocker.
- **Post-launch scale:** Revisit native only if offline, push, or store distribution becomes a deal-breaker.

---

## A.3 Accessibility

### Current state

- **Automated suite:** `frontend/src/a11y.audit.test.tsx` — axe-core via jest-axe across key pages, light + dark (README: 28 scans / 14 pages × 2 modes; zero serious/critical in that suite’s design intent).
- **Component-level axe** also appears (e.g. assistant `MessageBubble`).
- **Radix primitives** improve keyboard and focus behavior relative to bespoke widgets; ConfirmDialog focus-trap called out in README.
- Slot state is not color-only (text labels + Radix).

### Gaps

- jsdom axe **does not fully prove CSS contrast or real screen-reader behavior** (file itself notes Playwright not used for a11y).
- No documented NVDA/VoiceOver pass.
- No WCAG 2.2 AA formal conformance statement.
- Voice UI (mic, barge-in, audio replies) has additional a11y surface (captions, alternative text path) only partially covered.

### Risks

- Accessibility debt surfaces late in institutional sales (RWAs / larger developers).
- Dark-mode contrast regressions possible when tokens change without axe ratchet.

### Recommendations

- **P1:** Keep axe suite green as CI gate (already in frontend tests path).
- **P1:** One manual AT pass on Sign-in → Book → Cancel and Assistant before first real tenant.
- **P2:** Expand axe pages as new admin screens ship; add Playwright a11y only if jsdom gaps bite.

---

## A.4 Internationalization / localization readiness

### Current state

- **Product market:** India-first, INR-oriented requirements and cost ADRs (₹ ceilings).
- **i18n architecture (ADR-0013):** error presentation chain designed as  
  `tenant_override → locale_catalog → english_catalog → raw code`  
  with English-only catalog shipped; resolver accepts locale for future files.
- **Timezones:** `zoneinfo` / per-tenant timezone awareness in stack description.
- **Voice languages (ADR-0037):** multi-language *intent* (up to 3 langs per tenant); currently staged with hardcoded `en-IN` resolution path; Indic STT auto-detect blocked (`VOICE-ML` backlog).
- **Currency / billing:** invoicing architecture (ADR-0035) is India-community shaped; multi-currency not first-class.

### Gaps

- UI copy is English-only (no `hi`/`te` catalogs).
- No ICU message formatting framework (react-i18next etc.) beyond error catalogs.
- Voice non-English path blocked on STT detection limits.
- Multi-country data residency is architecturally anticipated (per-country deployment in early ADRs) but **not operated** as multi-region product.

### Risks

- Expanding to UAE/other geos without residency and currency design will force rework.
- Selling Hindi/Telugu “voice booking” before STT validation creates support load.

### Recommendations

- **Pre-revenue India:** English UI + en-IN voice is acceptable if marketed honestly.
- **P1:** Keep error-code catalogs as the expansion path; do not hardcode user-visible strings in new code.
- **Post-launch:** Locale packs only after 1–2 paying tenants request them; prioritize Hindi/Telugu for **voice** with real-speech validation, not UI first.

---

# Section B — Architecture Quality Attributes

## B.1 Security

### Current state

| Control | Evidence |
|---------|----------|
| Zero static JSON keys | Org policy + WIF (ADR-0018, security charter) |
| Tenant isolation (5 layers) | ADR-0004; architecture tests; middleware JWT×subdomain |
| AuthN/Z | Firebase Auth; roles; password policy v2 (ADR-0044) |
| Edge / WAF | Cloud Armor enforce with scoped `/agent/voice` exemption (PR-5c, ADR-0043); preview-log review documented |
| Secrets | Secret Manager shells in TF; values runbook-reissuable (ADR-0038 L2) |
| SAST / secrets in CI | Bandit, Gitleaks (blocking), pip-audit/pnpm audit/Trivy (warn-only ratchet open) |
| Security headers | Middleware shipped PR-5a |
| Same-origin API via LB | No CORS needed — documented correction in charter |
| Deferred residuals | CMEK, full VPC+NAT isolation, admin MFA, pen-test — **ADR-0039 accepted** with revisit triggers |

### Gaps

- **VOICE-INPUT-VALIDATION** open: voice path exempt from WAF; durable validation/sanitization audit required before resident prod.
- **VOICE-PROD-GATE** open: feature flag removed; voice unconditionally live where deployed.
- **CI-AUDIT-RATCHET** open: dependency/container scans not fully blocking.
- Binary Authorization deferred (Phase 18 / ADR-0043).
- No DAST (OWASP ZAP etc.) suite.
- Admin MFA deferred until second human or real tenant admin (ADR-0039).

### Risks

| Risk | Severity | Notes |
|------|----------|-------|
| Voice path abuse / cost | High | ≈₹/turn class cost surface historically; counters exist; hard rate limits incomplete |
| WAF-exempt audio body | Medium | Mitigated by non-SQL sinks + need for validation audit |
| Solo admin identity | High | `admin@chandraailabs.com` is cloud SPOF |
| Residual encryption (CMEK) | Low–Med at stage | Acceptable pre-PII; revisit on first real tenant |

### Recommendations

- **P0 pre-prod:** VOICE-INPUT-VALIDATION + restore a production kill-switch or rate limit for voice; SEC-01 DPDP check.
- **P0 on second operator / real tenant admin:** MFA.
- **P1:** Ratchet Trivy/pip-audit/pnpm audit to blocking after triage.
- **P2:** Formal pen-test after attack surface freeze (post voice validation).

---

## B.2 Scalability

### Current state

- **Compute:** Cloud Run, `minScale` 0 (cost), `maxScale` 10 (ADR-0041); soak observed instances 4→10 under load.
- **Data:** Single Firestore database, logical multi-tenancy (ADR-0004 Option A) — correct cost/ops tradeoff at hundreds of tenants per country.
- **Locks / pending actions:** Memorystore Redis BASIC 1 GB (ADR-0009, ADR-0041) — **SPOF accepted** with documented HA triggers.
- **Edge:** Global external HTTPS LB, wildcard certs, CDN on frontend bucket.
- **Measured load (test, 2026-08-06):**
  - **Realistic soak ~2h:** 20 tenants, 500 actors, ~35.7k bookings created / ~35.6k cancelled; lock_proof **25/25 pass, 0 double-book**; latency p50 **803 ms**, p95 **1960 ms**, p99 **2972 ms** (`soak-report.json`).
  - **Community-day ~30m:** 20 tenants, 500 actors paced; 1060 creates; p50 **240 ms**, p95 **3195 ms**, p99 **4179 ms** (`perf-community-report.json`).
- **Multi-region:** Not operated; asia-south1 primary. BigQuery federation noted as future for cross-country reporting.

### Gaps

- Firestore write hotspots / composite indexes need ongoing discipline as query patterns grow.
- Redis BASIC will not meet stricter availability or multi-AZ stories.
- No autoscaling policy documentation tied to booking-window rush (08:00 community behavior) beyond maxScale cap.
- Frontend SPA deep-link fallback historically flaky on custom-error path (see B.4).

### Risks

- 08:00 rush is the real scale event; community profile shows p95 > 3s under that shape — **product OK if honest**, bad if marketed as “instant.”
- Noisy-neighbor tenant can contend locks; quotas mitigate hoarding more than CPU isolation.

### Recommendations

- **P1:** Store soak percentiles as **formal S-PERF baseline** in TEST-STRATEGY and promote gates (measure-first — already project culture).
- **P1:** Document Redis HA upgrade triggers in runbook (already in ADR; operationalize checklist).
- **Post-launch:** Only move STANDARD HA Redis when SLO burn or multi-tenant blast radius demands it.

---

## B.3 Availability & reliability

### Current state

- **SLO (doc-level):** 99% monthly availability (ADR-0041); ~7.3 h/month error budget; Monitoring SLO API resources **not** created yet.
- **DR targets:** RTO 4h, RPO 4h (ADR-0038). Firestore PITR 7d + daily backups + delete protection; GCS versioning; TF rebuild path.
- **DR drill Pass 1:** Empty project rebuild **PASS** — 111 resources; machine time ~28 min; elapsed with debugging ~2.5 h — **inside 4h RTO** (`docs/runbooks/DRILL-pass1-report.md`).
- **Failure modes (designed):**
  - Redis down → bookings **fail closed** (no silent unlock).
  - Auth fail → 401.
  - Agent mutations → only via pending action confirm.
- **Redundancy:** Single region; single Redis; Cloud Run multi-instance within region under load.

### Gaps

- Clean **scripted uninterrupted RTO** not yet recorded as the official number.
- Backup **absence** alert (no successful backup in 36h) still open.
- CI vs Terraform historically fought on `max-instances` (drill finding — must stay fixed).
- SPA custom-error empty-body issue can present as “site down” for client routes without path rewrite.

### Risks

- Redis SPOF: total booking write outage until Redis restored (enable path ~10–20 min if deleted via env-power).
- Solo operator during incident extends effective RTO beyond infrastructure RTO.

### Recommendations

- **P0:** Keep env-power hold during soaks; never nightly-disable prod once real tenants exist (ADR-0047).
- **P1:** Complete timed DR Pass 2 (DNS/cert + data/auth layers) and publish measured RTO.
- **P1:** BACKUP-ABSENCE-ALERT.
- **P1:** Land SPA exact-route rewrites in Terraform for all envs (test hotfix demonstrated).

---

## B.4 Performance

### Current state

- **Culture:** “No aspirational gates — measure first” (Coordinator non-negotiable; ADR-0045 S-PERF).
- **Evidence-based latency (test, Aug 2026):** see B.2 tables — p50 sub-second in community profile; p95 multi-second under rush/soak.
- **Correctness under contention:** lock proofs pass; concurrency script exists (`scripts/concurrency_test.py`).
- **Resource efficiency:** min instances 0 in design; soak often held ~4 warm instances under continuous load.
- **Frontend performance:** hashed assets immutable cache; `index.html` no-cache; CDN USE_ORIGIN_HEADERS.

### Gaps

- p95 not yet wired as **promote gate** (alert threshold provisional p95 > 2.5s in ADR-0040).
- Agent/voice latency not broken out in soak reports (booking API dominated).
- Max latency outliers >30–45s observed — need error-budget / timeout policy clarity.
- SPA LB custom error returning **Content-Length: 0** for client routes was a **user-visible performance/availability bug** (blank page); mitigated on test via path rewrite to `/index.html` for exact SPA routes.

### Risks

- Treating multi-second p95 as failure without product context (rush contention is expected).
- CDN + custom-error interaction can poison UX independently of API health.

### Recommendations

- **P0:** Commit SPA routing fix to all environments via Terraform.
- **P1:** Publish “performance expectations” one-pager: interactive book p95 target after baseline; rush may degrade.
- **P2:** Separate agent/voice latency SLIs on Ops dashboard.

---

## B.5 Testability

### Current state

| Suite | Scale (approx.) | Automation |
|-------|-----------------|------------|
| Backend hermetic pytest | ~50 modules, ~600+ `test_*` functions; **≥90% coverage gate** | PR CI |
| Frontend Vitest | ~52 files, ~470 test cases | PR CI |
| Static | ruff, bandit, eslint, architecture test | PR CI |
| S-FUNC live | `tests/functional/` ~13 modules / ~33 tests | GHA `functional.yml` workflow_dispatch |
| Playwright browser | **2 tests / 1 file** | Local / manual |
| Soak / community | `scripts/soak_test.py` | Coordinator manual |
| DR | `drill-bootstrap.sh` | Manual drill |

Governing model: **ADR-0045** layered suites + same-SHA promote; living runbook `docs/testing/TEST-STRATEGY.md`; R2 pack documented.

### Gaps

- Playwright covers only resident sign-in + facilities smoke (second test often skips if no facility links / force-password).
- S-FUNC not on every PR (correct cost choice) but promote discipline still partially operator-driven.
- No OpenAPI contract suite.
- Frontend coverage threshold not enforced like backend’s 90%.
- mypy scoped (e.g. voice services), not whole backend.

### Risks

- UI regressions in admin IA slip past hermetic tests.
- Env wiring bugs (wrong `projectId` / base domain) are the class of bug that unit tests cannot catch — smoke/S-FUNC must stay mandatory before prod.

### Recommendations

- **P1:** Expand Playwright to F5 journey (book → cancel) once seed data guaranteed.
- **P1:** Require S-SMOKE + S-FUNC green evidence artifact before prod promote (checklist already in ADR-0045).
- **P2:** Frontend coverage floor after measuring baseline (same non-aspirational rule).

---

## B.6 Maintainability

### Current state

- **Backend layering:** routes → services → repositories; architecture test forbids Firestore in handlers (ADR-0008).
- **ADR trail:** 47 decision records — primary institutional memory.
- **Retrospectives** after major phases; CHANGELOG with PR-level detail.
- **Tooling:** uv, ruff, pytest, pnpm, Vite, Terraform modules split by concern.
- **Technical debt:** tracked in `docs/backlog.md` with IDs and statuses (not a sticky-note culture).

### Gaps

- README phase table can lag ADR/backlog (historically fixed in DOC-TRUTH; residual vigilance needed).
- Some scripts historically hardcoded `sport-slot-dev` (multi-env parameterization in progress via deploy registry).
- Python package still named `sport_slot` under product rename — low risk, mild confusion.

### Risks

- Without co-founder, ADR quality erodes if velocity replaces ceremony.
- Import/lifecycle `ignore_changes` on Cloud Run image is correct for CI ownership but confuses newcomers.

### Recommendations

- **P0 process:** “merge ≠ applied” checklist for infra PRs (Phase 17 lesson).
- **P1:** Keep backlog as single source of open work; archive completed with PR refs.
- **P2:** Optional rename package only if it pays for churn.

---

## B.7 Observability

### Current state

- **ADR-0040 / PR-2:** uptime check(s), alert policies (5xx rate, p95 latency, uptime, backup failure), email (+ SMS channel model), Error Reporting, voice/agent turn counters — `terraform/observability.tf`.
- **Ops dashboard:** “SlotSense Ops” (`terraform/dashboard.tf`) — turns, 5xx, p95, uptime, instance count.
- **Structured JSON logging** with request IDs; PII redaction principle in charter.
- **Runbook:** `docs/runbooks/observability.md`.

### Gaps

- Monitoring **SLO objects / burn-rate alerts** not implemented (explicitly deferred until measured traffic).
- Alert thresholds provisional; need post-soak tuning (`ALERT-THRESHOLD-TUNE`).
- Historical “pending apply” drift between merged TF and live projects — operators must verify per env.
- No distributed tracing (Cloud Trace) as first-class product.

### Risks

- Alerts that never fire or fire noise → ignored pages (solo-op alert fatigue).
- Backup alert may miss “schedule never runs” without absence detection.

### Recommendations

- **P1:** Per-environment apply confirmation + channel fire-test after every env bootstrap.
- **P1:** Tune thresholds using soak distributions.
- **P2:** OpenTelemetry/Trace only if latency debugging cost exceeds log-based debugging.

---

## B.8 Extensibility

### Current state

| Extension | Ease today | Why |
|-----------|------------|-----|
| New tenant (same region) | High | Admin create tenant + slug subdomain; policy overrides |
| New facility type | High | Platform facility catalog |
| New policy knobs | Medium | Policy service + ADR-0010 patterns |
| New notification channel | Medium–Hard | Cloud Tasks worker + provider; WhatsApp not built |
| New country / region | Hard | Data residency, Firebase project, LB domain (ADR-0046), legal |
| New agent tool | Medium | Tools + guards + tests; must not bypass services |
| New tenant “type” (e.g. club vs society) | Medium | Mostly policy/branding; may need model fields |

### Gaps

- Payments / UPI not in architecture as first-class.
- WhatsApp Business integration absent despite REQUIREMENTS mention of gateways.
- Multi-currency and multi-language UI catalogs not shipped.

### Recommendations

- **Pre-revenue:** Prefer configuration (policy, catalog, branding) over code for each new society.
- **Post-launch:** Treat WhatsApp and payments as product epics with their own ADRs, not drive-by features.

---

# Section C — Delivery & Operations

## C.1 DevOps (CI/CD, environments, promotion)

### Current state

- **PR gates:** hermetic tests + static (`.github/workflows/pr-gates.yml`); no GCP from PRs (WIF restricted to main).
- **Deploy:** progressive multi-env (`deploy.yml`) with registry, same-SHA image promote design (`docs/design/same-sha-image-promote.md`); frontend rebuild per env (Vite env).
- **Functional:** `functional.yml` workflow_dispatch against test/dev.
- **Env power:** `env-nightly-disable.yml` (ADR-0047) at 23:00 IST.
- **Environments:** standing legacy `sport-slot-dev`, multi `slot-sense-dev-*` / `slot-sense-test-*`; prod path designed, not necessarily fully populated.
- **Bootstrap:** `drill-bootstrap.sh` + extensive runbooks for empty project create.

### Gaps

- Promote evidence trail still partly manual.
- Residual hardcoding / drift lessons from DR drill (deploy scripts vs TF scaling ownership).
- Smoke not automatically post-deploy for every environment.
- Prod GitHub Environment protection depends on registry population + reviewers setup.

### Risks

- Wrong-env deploy (Firebase project bleed) — mitigated by SPA projectId checks in functional/bootstrap but still a class of high-severity mistakes.
- Nightly disable without hold ruins soaks (hold marker exists — discipline required).

### Recommendations

- **P0:** Hold markers for any multi-hour test; document in soak runbook (exists).
- **P1:** Automated post-deploy S-SMOKE job per env.
- **P1:** Ensure deploy scripts never override Terraform-owned scaling knobs.

---

## C.2 FinOps

### Current state

- **Ceilings:** DEV ≤ ₹5k/mo; per-tenant prod target ≤ ₹2k/mo (ADR-0005).
- **Dominant cost:** Memorystore Redis ~₹2.5–3k/mo **per project**.
- **Budgets:** billing budget + graduated thresholds (ADR-0042); alert-only (no auto billing disable).
- **Env power (ADR-0047):** delete Redis + scale-to-zero + pause scheduler/uptime nightly; manual enable/disable; hold for soaks — **high maturity FinOps actuator**.
- **Voice cost visibility:** turn counters (ADR-0040 D12).

### Gaps

- Per-tenant unit economics not yet measured from real revenue (pre-revenue).
- Budget filters historically scoped to specific projects; each new env needs its own budget (`TEST-PROJECT-BUDGET` class work).
- Residual LB/IP costs remain when “disabled.”

### Risks

- Multiple parallel test projects with Redis always-on will breach ceilings quickly without env-power.
- Voice at scale can dominate variable cost.

### Recommendations

- **P0 solo:** Enforce nightly disable on all non-prod; one warm env max when idle.
- **P1:** Budget per standing project; monthly cost review tied to Ops dashboard + billing export.
- **Post-launch:** Revisit Redis tier and min instances with revenue-backed SLOs.

---

## C.3 Release management

### Current state

- CHANGELOG is detailed; PR-linked history.
- Same-SHA promote intent (ADR-0045): config/secrets do not ride the artifact.
- Rollback: redeploy previous image tag; Firestore PITR for data mistakes; frontend object versioning/CDN invalidate.
- Feature flags: historically `SPORTSLOT_VOICE_ENABLED` **removed** — weaker runtime flag posture now.

### Gaps

- No general-purpose feature-flag service (LaunchDarkly-style) — env vars only.
- Prod approval workflow depends on GitHub Environments configuration maturity.
- Release evidence template exists in strategy docs but may not be filled every promote.

### Risks

- Voice always-on increases blast radius of bad agent/STT deploys.
- Missing evidence makes postmortems harder.

### Recommendations

- **P0:** Reintroduce kill-switches for voice and optionally agent on prod.
- **P1:** Lightweight promote checklist (SHA, S-SMOKE, S-FUNC, S-PERF summary, approver).
- **P2:** Flag framework only when multiple concurrent experiments exist.

---

## C.4 Incident readiness

### Current state

- Alerts + email/SMS model; Ops dashboard.
- DR runbook, observability runbook, env-power runbook, soak runbook.
- Security charter includes interim incident process notes.
- Phase retros document failure patterns (valuable institutional memory).

### Gaps

- **No formal on-call rotation** (solo operator).
- Incident response runbook still thin vs DR rebuild runbook.
- Postmortem culture exists in retros but not as mandatory incident template for prod SEVs.
- No status page for tenants.

### Risks

- Solo-op is the real RTO multiplier.
- Alert storms during soaks if checks not paused (env-power pauses uptime — good).

### Recommendations

- **P0:** One-page SEV ladder (SEV1 booking down / SEV2 degraded / SEV3 cosmetic) with first actions.
- **P1:** Before first tenant: shared break-glass procedure with a trusted second person (even unpaid advisor) for cloud account recovery.
- **Post-launch:** Status page + quarterly game day.

---

# Section D — Business & Strategic

## D.1 Multi-tenancy maturity

### Current state

- Logical isolation in one Firestore DB with defense-in-depth — appropriate and cost-effective.
- Subdomain branding and zero tenant DNS burden (wildcard).
- Onboarding: platform creates tenant + admin; catalog facilities; bulk users.
- Blast radius: shared Redis/Cloud Run — noisy neighbor possible; quotas reduce booking hoarding.
- Test seed supports ~20 tenants for load realism (`seed_test_population`, soak config).

### Gaps

- No per-tenant rate isolation beyond app-level limits.
- Soft-delete / DPDP erasure paths exist (ADR-0034) but operational playbooks for tenant offboarding should stay current.
- Custom domains explicitly not Phase 1.

### Risks

- A platform bug in repository filtering is existential — mitigated by layers + tests, still highest-impact class.
- Tenant admin compromised → tenant-scoped damage (expected); platform admin compromised → global.

### Recommendations

- **P0:** Never weaken JWT×host check or repository construction rules for convenience.
- **P1:** Annual (or pre-launch) cross-tenant penetration style test (manual).
- **Post-launch:** Consider per-tenant export/offboarding SLA.

---

## D.2 Compliance & data governance

### Current state

- Security charter DPDP commitments: India storage intent, no PII in analytics (hashed IDs), deletion/export rights, breach 72h target.
- Voice STT/TTS region nuance documented; **SEC-01** blocked on counsel verification for cross-border processing.
- Backups: Firestore schedule + PITR; secrets re-issuable not value-backed up.
- Retention/deletion: ADR-0017, ADR-0034.

### Gaps

- Formal DPDP assessment / privacy notice legal review not closed.
- CMEK deferred.
- Data processing agreements with Resend / Google not documented in-repo for customer paper trail.
- Resident consent UX not assessed in this report as legal-complete.

### Risks

- Shipping voice without SEC-01 is a compliance risk for India launches.
- Customer enterprise questionnaires will ask for pen-test, MFA, CMEK — need answer sheets (defer with ADR-0039 is honest if stage-appropriate).

### Recommendations

- **P0 before real PII:** SEC-01 counsel check; privacy notice; processing map (Auth, Firestore, STT, TTS, email).
- **P1:** Customer-facing security one-pager derived from charter + ADR-0039.
- **Post-launch:** Pen-test + MFA + revisit CMEK if contracts require.

---

## D.3 Documentation quality

### Current state

- **Standout asset:** 47 ADRs, REQUIREMENTS, security charter, testing strategy, runbooks (create env, DR, observability, soak, env-power, DNS cutover), phase reports/retros, honest backlog.
- Portfolio article `docs/SLOTSENSE_ARTICLE.md` for narrative positioning.

### Gaps

- Some docs still say “pending apply” after work shipped — readers must check dates.
- Private “Three-Agent Protocol” methodology is outside repo (by design) — onboarding a co-founder requires exporting it.
- Architecture diagrams limited relative to prose volume.

### Risks

- Doc drift returns under time pressure (already once fixed in DOC-TRUTH).
- Knowledge concentration: docs mitigate but do not replace a second brain.

### Recommendations

- **P0 for close-out:** This assessment + pointer from README “Key documents.”
- **P1:** Quarterly doc drift audit (claims vs CI vs Terraform).
- **P1:** Co-founder onboarding pack = ADRs index + runbooks + this report + protocol export.

---

## D.4 Vendor lock-in / portability

### Current state

| Component | Lock-in | Abstraction |
|-----------|---------|-------------|
| Firestore | High | Repository pattern helps but queries are Firestore-shaped |
| Firebase Auth | High | Auth dependency isolatable with effort |
| Cloud Run | Medium | Containerized FastAPI — portable runtime |
| Memorystore Redis | Medium | Standard Redis protocol |
| Vertex AI | High | Agent tools call services; model swap possible with rewrite |
| Cloud Tasks / Scheduler | Medium | Interfaceable |
| GCS + LB | Medium–High | Static frontend portable; LB config less so |
| Terraform GCP | High | IaC is cloud-specific by nature |
| Resend | Low–Medium | Email provider interface exists (fake provider in tests) |

### Risks

- Multi-cloud is not realistic short-term; **GCP region dual-run** is the realistic portability story.
- Firestore modeling choices (document paths per tenant) are durable — good for GCP, costly to leave.

### Recommendations

- Accept GCP commitment for v1; keep **provider interfaces** for email and (later) SMS/WhatsApp.
- Avoid dual-writing to a second DB “for portability” pre-revenue — pure cost.

---

## D.5 AI/ML posture

### Current state

- Agent is **orchestration over existing booking services**, not a separate system of record (ADR-0021).
- Safety stack: propose-confirm-execute (0023), output guard (0024), pending store (0025), deterministic guards (0026), cancel disambiguation (0027).
- Voice I/O (0036/0037): STT/TTS with language strategy; production hardening items open.
- Tests: extensive agent/voice hermetic tests in backend.
- Cost: turn counters; budget awareness.

### Gaps

- No continuous evaluation harness (golden transcripts, booking-success rate online).
- Model identity docs sometimes lag (Flash vs Pro naming historically).
- Voice always-on without hard cost circuit breaker is a business risk.
- Hallucination guard is necessary but not sufficient for UX trust — needs telemetry.

### Risks

- LLM provider/model deprecations.
- Prompt injection / tool abuse — mitigated by resident-scoped tools and confirm gate; still needs monitoring.
- Support load if agent over-promises availability.

### Recommendations

- **P0:** Voice/agent kill-switch + cost anomaly alert.
- **P1:** Offline eval set of N booking dialogues with expected tool traces.
- **Post-launch:** Human review sampling of agent sessions (privacy-safe).

---

## D.6 Business continuity (solo-operator risk)

### Current state

- Single Coordinator owns GCP org admin, product decisions, deploys, DR, customer narrative.
- Documentation partially compensates; **execution still requires Chandra**.
- No deputy with verified break-glass access documented.

### Gaps / risks (strategic)

| Risk | Impact |
|------|--------|
| Operator unavailable during outage | Extended downtime beyond infra RTO |
| Laptop / 2FA loss | Account recovery delay |
| Knowledge not transferred | Project value drops sharply in diligence or sale |
| Bus factor = 1 | Co-founder/investor concern |

### Recommendations

- **P0 for “project close” if meaning pause:** Ensure env-power leaves non-prod **disabled**; document how to re-enable; store this report + DR runbook offline.
- **P0 for launch:** Second person with limited break-glass (billing + org recovery) + password manager emergency kit.
- **P1:** Record 30-min loom: “how to deploy, how to disable env, how to restore Redis, how to seed admin.”
- **Post-launch:** Hire or co-found ops/engineering before multi-city expansion.

---

# Section E — Improvement roadmap

## E.1 Priority legend

| Priority | Meaning |
|----------|---------|
| **P0** | Must before real resident PII / paying tenant / public prod |
| **P1** | Should within next active engineering cycle |
| **P2** | Nice-to-have; schedule after P0/P1 |

Effort × impact is qualitative: **S** small (<1–2 days), **M** medium (≤1–2 weeks), **L** large (multi-week epic).

---

## E.2 Pre-revenue / solo phase (now → first tenant)

Goal: **keep costs low, keep system demonstrable, do not accumulate silent prod risk.**

| ID | Item | Pri | Effort | Impact | Notes |
|----|------|-----|--------|--------|-------|
| PRS-1 | Land SPA exact-route rewrites in TF all envs + CDN invalidate runbook note | P0 | S | High | Fixes blank `/signin` class failures |
| PRS-2 | Voice kill-switch + input validation audit (VOICE-INPUT-VALIDATION) | P0 | M | High | Backlog HIGH |
| PRS-3 | SEC-01 DPDP counsel / processing map for voice regions | P0 | S–M | High | Legal, not code |
| PRS-4 | Enforce env-power nightly + budgets on every standing project | P0 | S | High | FinOps survival |
| PRS-5 | Promote checklist + S-SMOKE/S-FUNC evidence before any “prod” | P0 | S | High | ADR-0045 already defines |
| PRS-6 | Break-glass second human + SEV one-pager | P0 | S | High | Bus factor |
| PRS-7 | Expand Playwright to book/cancel (seed-dependent) | P1 | M | Med | Thin E2E today |
| PRS-8 | Soak baselines → written S-PERF gate (document, then automate) | P1 | S | Med | p50/p95 from Aug reports |
| PRS-9 | BACKUP-ABSENCE-ALERT + threshold tune | P1 | S | Med | ADR-0040 residual |
| PRS-10 | CI audit ratchet (Trivy/pip-audit/pnpm) | P1 | S | Med | After triage |
| PRS-11 | Admin MFA when second operator exists | P0* | S | High | *Trigger-based (ADR-0039) |
| PRS-12 | Tenant-admin voice language UI (TADM-01) | P2 | M | Low now | Blocked on VOICE-ML |
| PRS-13 | WhatsApp / payments | P2 | L | High commercially | Product epic, not hygiene |
| PRS-14 | Native apps | P2 | L | Low now | PWA sufficient |
| PRS-15 | CMEK / full VPC / pen-test | P2* | L | Med | *Revisit triggers ADR-0039 |

### Solo-phase operating posture (recommended)

1. **One warm environment max** when actively developing; others disabled (ADR-0047).
2. **Demo on test** with seeded tenants; never improvise against prod.
3. **Do not market multi-language voice** until VOICE-ML unblocked.
4. **Monthly:** cost review, backup success check, dependency CVE glance.

---

## E.3 Post-launch / scale phase (first paying tenants → multi-city)

Goal: **reliability, compliance paperwork, channels, team.**

| ID | Item | Pri | Effort | Impact |
|----|------|-----|--------|--------|
| PLS-1 | Pen-test + remediate | P0 | M–L | High |
| PLS-2 | Admin MFA mandatory; resident MFA optional evaluation | P0 | S–M | High |
| PLS-3 | Status page + on-call (even founder + contractor) | P0 | M | High |
| PLS-4 | Redis HA when SLO burn / multi-tenant critical mass | P1 | M | High |
| PLS-5 | WhatsApp (or dominant local channel) integration | P1 | L | High commercial |
| PLS-6 | Payments / UPI if monetizing beyond society fee | P1 | L | High |
| PLS-7 | Formal Monitoring SLO + burn-rate alerts | P1 | M | Med |
| PLS-8 | Multi-region / second country only with residency ADR | P1 | L | Strategic |
| PLS-9 | Agent online eval + sampling review | P1 | M | Trust |
| PLS-10 | CMEK if customer contracts require | P1 | M | Sales enablement |
| PLS-11 | i18n UI packs on demand | P2 | M | Expansion |
| PLS-12 | Binary Authorization / stronger supply chain | P2 | M | Security maturity |
| PLS-13 | Hire eng/ops; transfer runbooks | P0 org | L | Continuity |

---

## E.4 What “project close” should mean (for this checkpoint)

If the intent is to **pause active build** and freeze a portfolio/diligence baseline:

1. Check in this assessment report.
2. Merge/PR any outstanding SPA LB Terraform so test hotfix is not snowflake-only.
3. Disable non-essential GCP environments via env-power; leave one demo env if needed.
4. Tag git (`assessment-2026-08-06` or release tag) and note soak report filenames in CHANGELOG.
5. Freeze backlog statuses with date; do not delete history.
6. Store break-glass instructions offline.

If the intent is **prepare for first tenant**, execute **E.2 P0 table** before signing.

---

# Appendix A — Evidence index

| Topic | Primary sources |
|-------|-----------------|
| Product scope | `docs/REQUIREMENTS.md`, `README.md`, `docs/SLOTSENSE_ARTICLE.md` |
| Tenant isolation | `docs/adr/0004-tenant-isolation.md` |
| AI safety | `docs/adr/0021`–`0027` |
| Security | `docs/security/charter.md`, `docs/adr/0039`, `0043` |
| DR / RTO | `docs/adr/0038`, `docs/runbooks/disaster-recovery.md`, `DRILL-pass1-report.md` |
| Observability | `docs/adr/0040`, `docs/runbooks/observability.md`, `terraform/observability.tf` |
| Cost / FinOps | `docs/adr/0005`, `0042`, `0047`, `terraform/cost.tf`, `env_power.tf` |
| Testing / promote | `docs/adr/0045`, `docs/testing/TEST-STRATEGY.md`, `tests/functional/`, `tests/e2e/` |
| Multi-env DNS | `docs/adr/0046` |
| Load evidence | `soak-report.json`, `perf-community-report.json`, `docs/runbooks/soak-test.md` |
| Open work | `docs/backlog.md` |
| Prior external review | `docs/reviews/2026-07-15-PROJECT_REVIEW*.md` |
| Phase 17 | `docs/retrospectives/phase-17-closeout.md` |

---

# Appendix B — Measured performance snapshot (test, 2026-08-06)

### Realistic soak (~2h, 20 tenants, 500 actors)

| Metric | Value |
|--------|-------|
| Bookings created / cancelled | 35,710 / 35,596 |
| Lock proof | 25 pass, 0 double-book |
| Latency p50 / p95 / p99 | 803 / 1960 / 2972 ms |
| Cloud Run instances | min 4, max 10 observed |

### Community-day profile (~30m)

| Metric | Value |
|--------|-------|
| Bookings created | 1,060 |
| Latency p50 / p95 / p99 | 240 / 3195 / 4179 ms |
| Rush contenders / winners | 500 / 20 |
| Cloud Run instances | scaled to 10 during rush |

*Interpretation:* Correctness under contention is strong. Latency under rush is multi-second at the tail — set product and alert expectations accordingly; do not invent sub-second SLOs without re-architecture.

---

# Appendix C — Test inventory (approx., assessment date)

| Layer | Count |
|-------|-------|
| Backend test modules | ~50 |
| Backend `test_*` functions | ~600+ |
| Frontend test files | ~52 |
| Frontend test cases (it/test) | ~470 |
| Live functional tests | ~33 |
| Playwright tests | **2** |
| ADRs | **47** |
| CI workflows | PR gates, Deploy, Functional, Env nightly disable |

---

# Appendix D — Scorecard change vs 2026-07-15 review

| Dimension | Jul 15 | Aug 6 | Delta driver |
|-----------|--------|-------|--------------|
| Production readiness | ~2.8 | ~3.2 | Phase 17 build, multi-env, soak, Armor enforce |
| Observability | weak | baseline live (design) | PR-2/3 |
| DR | unbounded RPO risk | RTO drill PASS | ADR-0038 + drill |
| E2E browser | none | 2 Playwright tests | Still thin |
| FinOps actuator | budgets only | + env-power | ADR-0047 |
| Doc/code consistency | 3/5 | improved | DOC-TRUTH; ongoing |

---

## Closing statement

SlotSense is a **credible, diligence-ready engineering artifact**: multi-tenant isolation, AI safety, IaC, cost control, and documentation are at a level many funded startups lack.  

The remaining gap to a **revenue-bearing production service** is not “rewrite the platform.” It is a **short, boring list**: production kill-switches, compliance sign-off, edge SPA robustness everywhere, promote discipline, and reducing solo-operator risk.

Treat this document as the freeze baseline for project close or as the kickoff backlog for launch — not both without re-prioritizing Section E.

---

*Report prepared from repository evidence on 2026-08-06 for Chandra AI Labs / SlotSense close-out assessment.*
