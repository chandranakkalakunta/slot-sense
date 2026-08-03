# ADR-0045: Test Strategy & Environment Promotion

- **Status:** Accepted
- **Date:** 2026-08-02
- **Deciders:** Coordinator (Chandra)
- **Phase:** post-17 — multi-env ops (dev / test / prod readiness)
- **Related:** ADR-0018 (CI/CD security / WIF); ADR-0008 (architecture
  test guard); ADR-0039 (production-hardening residuals); ADR-0041
  (availability / Redis residuals); docs/testing/TEST-STRATEGY.md
  (living runbook); PROJECT_REVIEW 2026-07-15 (P2.3 Playwright OPEN)

## Context

SlotSense now has multiple GCP environments (legacy `sport-slot-dev`,
`slot-sense-dev-*`, `slot-sense-test-*`, future prod). Delivery quality
depends on two questions that were previously only partly answered:

1. **What must be tested, and at which layer?**  
2. **When may a build move from dev → test → prod?**

### Current state (as of 2026-08-02)

| Strength | Gap |
|---|---|
| Hermetic backend pytest (~690 tests, ≥90% coverage gate) | No progressive multi-env deploy CI |
| Frontend Vitest + lint + build | Deploy workflow hardcodes `sport-slot-dev` |
| ruff + bandit; architecture test (no Firestore in handlers) | No automated post-deploy **smoke** |
| DR bootstrap Phase 8 checks; concurrency script (manual) | No browser **E2E / functional** pack (Playwright OPEN) |
| Living doc `docs/testing/TEST-STRATEGY.md` | No **Accepted ADR** binding promotion rules |
| | No stored **performance** baselines / promote gate |
| | No mandatory release evidence for prod |

Without an ADR, suite names and promote rules stay informal: operators
cannot tell whether a green CI run alone authorizes a test or prod
cutover, and automation work has no ordered mandate.

### Requirements

- R1 — Named suites with clear purpose and run location (PR vs
  deployed env).
- R2 — Same immutable artifact (git SHA / image tag) promotes upward.
- R3 — Higher environments require **more** evidence, not less.
- R4 — Prod requires human approval in addition to automated gates.
- R5 — Secrets and per-env config never promote with the artifact.
- R6 — Cost and stage-appropriate: do not block all progress on a
  full k6 farm or pen-test before first multi-env pipeline exists.

### Constraints

- Single-operator / pre-revenue posture still applies (ADR-0039) for
  some security residuals; that does **not** excuse missing smoke or
  multi-env promotion once test/prod projects exist.
- Keyless WIF remains mandatory (ADR-0018); progressive CI must not
  reintroduce static keys.
- Hermetic unit tests remain the primary fast feedback loop; live-env
  suites must stay thin and deterministic.

## Options considered

### Option A — CI unit/static only; promote by trust

Keep today’s model: green PR/main CI ⇒ deploy wherever the Coordinator
points gcloud. Document suites optionally.

**Strengths:** Minimal process; already implemented.  
**Weaknesses:** Cross-env mistakes (wrong Firebase project, broken
DNS, failed force-password) only found by humans; cannot scale to
test/prod discipline.

### Option B — Full matrix: every suite on every PR against every env

PR runs unit + smoke + E2E + load against live projects.

**Strengths:** Maximum confidence.  
**Weaknesses:** Slow, flaky, expensive; blocks iteration; violates
hermetic-first feedback; fails R6.

### Option C — Layered suites + progressive promotion (chosen)

- **PR:** hermetic regression + static only.  
- **Deployed env:** smoke (always after deploy); functional E2E and
  perf on **test** before prod.  
- **Promote:** same SHA; explicit promote steps; GitHub Environment
  protection for prod.  
- Living runbook for commands; ADR for binding decisions.

**Strengths:** Matches industry progressive delivery; reuses existing
CI strength; scopes automation work.  
**Weaknesses:** Requires multi-env CI work; manual functional pack
until Playwright lands.

## Decision

**Adopt a layered test-suite model and a progressive, same-SHA
promotion path from CI → dev → test → prod.**  
`docs/testing/TEST-STRATEGY.md` is the **operational runbook** for
this ADR (commands, checklists, evidence template). This ADR is the
**normative** source for suite definitions and promote gates.

### D1 — Named suites (canonical)

| Suite ID | Name | Purpose | Primary location |
|---|---|---|---|
| **S-STATIC** | Static analysis | Lint, security scan, architecture rules | Every PR + main |
| **S-REG-UNIT** | Unit / API regression | Hermetic backend + frontend tests | Every PR + main |
| **S-SMOKE** | Environment smoke | Deployed env is alive and wired to the correct project | After every deploy to an env |
| **S-FUNC** | Functional / E2E | Critical user journeys end-to-end | Against **test** before prod; optional on dev |
| **S-PERF** | Performance | Contention + latency sample vs baseline | Against **test** before prod (or skip with reason) |
| **S-SEC** | Security (extended) | Beyond bandit: deps, future DAST | Progressive; not all P0 |
| **S-DR** | Disaster recovery | Rebuild / restore drills | Scheduled / event-driven (ADR-0038) |

**S-REG-UNIT** and **S-STATIC** are **mandatory green** before any
environment may receive a new candidate build from CI.

### D2 — What each suite must cover (minimum content)

**S-SMOKE (deployed):**

1. `GET /health` → success over the env’s public HTTPS host.  
2. Frontend artifact embeds the **target** Firebase/GCP `projectId`
   (no cross-env Auth bleed).  
3. Platform admin can complete sign-in on the env admin host (and
   force-password if seed requires it).  
4. Optional: `/version` or build id matches promoted SHA when exposed.

**S-FUNC (critical journeys — automate over time):**

1. Platform admin: force-change password path; facility catalog CRUD.  
2. Platform admin: create tenant + tenant admin (6-digit initial code).  
3. Tenant admin: create facility from catalog.  
4. Resident: force-change → availability → book → cancel.  
5. Optional P1: invoices / agent / voice when enabled in that env.

**S-PERF (minimum):**

1. Slot-lock concurrency: N parallel book attempts → exactly one 201
   (existing `scripts/concurrency_test.py` or successor).  
2. Documented latency sample (e.g. health or book p95) against a
   stored baseline once measured — **no aspirational thresholds**
   (Coordinator non-negotiable: measure first, then gate).

**S-REG-UNIT:** full existing pytest + vitest + architecture test;
coverage floor remains the measured-policy gate (≥90% backend as of
this writing; adjust only after re-measure).

### D3 — Progressive promotion model

```text
  PR → S-STATIC + S-REG-UNIT
         │ green
         ▼
  Build immutable artifacts (image tag = git SHA; frontend commit SHA)
         │
         ▼
  DEV    deploy candidate (auto or low-friction)
         │ S-SMOKE (required after deploy)
         ▼
  TEST   promote same SHA (explicit action)
         │ S-SMOKE required
         │ S-FUNC required before first prod cutover of a release train;
         │          thereafter required for major/risk changes
         │ S-PERF required when booking/lock paths change; else skip+note
         ▼
  PROD   promote same SHA (explicit action + human approval)
         │ S-SMOKE after deploy
         │ Evidence: test-env S-SMOKE (+ S-FUNC/S-PERF per rules above)
```

**Rules:**

1. **Same SHA** (or same Artifact Registry digest) only — rebuilds for
   prod are forbidden unless the new SHA re-runs the full chain.  
2. **Config/secrets are per-env** — never copy Secret Manager values
   between projects as part of promote.  
3. **Prod requires a human approver** (GitHub Environment protection
   or equivalent out-of-band sign-off recorded in the release note).  
4. **Dev may lag or lead** for experiments, but **prod may only be
   fed by a SHA that has passed the test-env gates** applicable to
   that release.  
5. **Fail closed on smoke:** a deploy that fails S-SMOKE is not
   “promoted”; rollback or fix-forward with a new SHA.

### D4 — Implementation order (binding backlog)

Work is ordered so each step unblocks the next:

| Priority | Work item | Closes |
|---|---|---|
| **P0** | Multi-env / progressive CI: parameterize deploy; promote-to-test by SHA (WIF, no keys) | D3 path to test — **DONE 2026-08** (`deploy.yml` option A + `deploy-environments.json`) |
| **P0** | Automated S-SMOKE job post-deploy (at least health + projectId) | D2 smoke — **PARTIAL** (health curl); projectId checked in deploy job pre-GCS |
| **P1** | GitHub Environments `test` / `prod` + required reviewers on prod | D3 approval — workflow ready; Coordinator enables protection in repo Settings |
| **P1** | Playwright (or equivalent) S-FUNC against test for journeys D2 | D2 functional |
| **P2** | S-PERF baselines measured then gated; concurrency in promote path | D2 perf |
| **P2** | S-SEC extended (dependency audit gate); contract tests if OpenAPI published | D1 extended |
| **P3** | Nightly S-FUNC on test; S-DR drill cadence (already ADR-0038) | Hardening |

Primary promote path: Actions → **Deploy** → Run workflow (see
`docs/testing/TEST-STRATEGY.md` §5.4). Manual gcloud fallback remains §5.5.

### D5 — Evidence for a production promote

A prod promote record (PR comment, release note, or checklist) MUST
include:

- Candidate **git SHA** and image digest/tag  
- Link to green **S-STATIC + S-REG-UNIT** CI  
- **S-SMOKE** result on **test** (pass + timestamp + admin URL)  
- **S-FUNC** result when required by D3 (pass/fail/N-A with reason)  
- **S-PERF** result when required by D3 (or explicit skip reason)  
- Approver name/date  

Template: `docs/testing/TEST-STRATEGY.md` §6.

### D6 — Explicit non-goals / residuals (this ADR)

Not required to Accept this ADR or to run first multi-env promotes:

- Full load-test platform (k6 cloud, multi-region soak)  
- DAST / formal pen-test (see ADR-0039 revisit triggers)  
- 100% E2E coverage of every UI state  
- Mutating performance tests against prod  

These may be added later without superseding D1–D5 unless a decision
conflicts.

## Rationale

- **Hermetic-first PR gates** preserve fast, reliable developer
  feedback (already proven at ≥90% backend coverage).  
- **Smoke on every deploy** catches the class of bugs unit tests cannot
  (wrong project wiring, DNS/cert, broken revision).  
- **Functional + perf on test before prod** matches progressive
  delivery without Option B’s cost.  
- **Same-SHA promote** prevents “works on test rebuild” drift.  
- **Ordered backlog (D4)** avoids boiling the ocean: progressive CI
  and smoke before Playwright and perf gates.

## Consequences

### Positive

- Shared vocabulary (S-SMOKE, S-FUNC, …) for operators and CI jobs.  
- Clear bar for “may we ship to prod?”  
- TEST-STRATEGY.md has a governing ADR to point at.  
- Implementation work is prioritised (D4).

### Negative / trade-offs

- Until progressive CI exists, compliance is partly manual.  
- S-FUNC remains checklist-heavy until Playwright is built.  
- Prod discipline adds Coordinator latency (intentional).

### Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Promote without evidence | Medium | D5 checklist; later Environment protection (D4 P1) |
| Flaky live E2E blocks ships | Medium | Keep S-FUNC thin; quarantine flakes; hermetic R1 remains merge gate |
| Wrong env Firebase in frontend | High historically | S-SMOKE projectId check mandatory (D2) |
| Aspirational perf gates | Medium | D2: measure baseline before threshold |

## Alternatives rejected

- **Option A** — insufficient once test/prod exist.  
- **Option B** — too slow/expensive for this stage (R6).  
- **Separate product repos per env** — rejected earlier (single repo,
  multi-project); promotion stays SHA-based in one repo.

## Implementation notes (non-normative)

- Prefer GitHub Actions `workflow_dispatch` inputs: `environment`,
  `git_sha` / `image_tag`.  
- Reuse WIF (ADR-0018); one pool/provider per project or documented
  multi-project bindings.  
- S-SMOKE may start as a shell job (`curl`, `gcloud storage cat` for
  projectId) before full Playwright login smoke.  
- Do not lower backend coverage floor without re-measure + ADR amend
  or new ADR.

## References

- [docs/testing/TEST-STRATEGY.md](../testing/TEST-STRATEGY.md) — commands, checklists, interim promote  
- [ADR-0018](0018-cicd-security-model.md) — keyless WIF  
- [ADR-0008](0008-data-layout-and-repository-contract.md) — architecture test  
- [ADR-0038](0038-backup-and-disaster-recovery.md) — DR drills (S-DR)  
- [ADR-0039](0039-accepted-production-hardening-residuals.md) — security residuals  
- Project review 2026-07-15 — Playwright smoke E2E OPEN (P2.3)

## Related ADRs

- **ADR-0018** — CI auth model this progressive pipeline must extend.  
- **ADR-0038** — S-DR suite ownership of rebuild proof.  
- **ADR-0041** — Redis/availability residuals; S-PERF may cite SLO later.  
- **ADR-0044** — password/initial credential behaviour covered by S-FUNC journeys.
