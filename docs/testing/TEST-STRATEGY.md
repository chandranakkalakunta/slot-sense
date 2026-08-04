# SlotSense test strategy & environment promotion

**Status:** Living runbook  
**Governing ADR:** [ADR-0045](../adr/0045-test-strategy-and-environment-promotion.md)  
**Last updated:** 2026-08-03  
**Environments:** local · `slot-sense-dev-*` · `slot-sense-test-*` · prod  

Normative decisions (suite names, promote gates, backlog order) live in
**ADR-0045**. This file holds **commands, checklists, and interim
operator procedures**.

This document answers:

1. What test suites exist **today** (ground truth)  
2. Target suites (smoke / regression / functional / performance / others)  
3. How to run them against **test**  
4. How builds promote **dev → test → prod** based on results  

---

## 1. Assessment — what exists today

### 1.1 Continuous integration (every PR + every push to `main`)

| Suite | Location | What it covers | Gate |
|---|---|---|---|
| **Backend unit + API (hermetic)** | `backend/tests/` (~50 modules, ~690 tests) | Auth, booking, facilities, provisioning, agent, voice, invoicing, architecture layering, password policy, catalog, etc. | `pytest --cov=src --cov-fail-under=90` |
| **Backend static analysis** | CI | `ruff check`, `bandit -r src/` | Fail on issues |
| **Architecture guard** | `backend/tests/test_architecture.py` | Handlers must not import Firestore (ADR-0008) | pytest fail |
| **Frontend unit + component** | `frontend/src/**/*.test.ts(x)` | Routes, auth gates, pages, hooks, a11y audit subset | `pnpm test` |
| **Frontend lint + build** | CI | `pnpm lint`, `pnpm build` | Fail on errors |

**Characteristics:** Fast, mocked Firestore/Firebase, no real GCP, no browser E2E against live env.

### 1.2 Coordinator / manual / ad-hoc

| Suite | Location | What it covers | Automated in CI? |
|---|---|---|---|
| **Local tool smoke** | `scripts/verify_toolchain.sh` | gcloud, terraform, firebase, pnpm, uv on PATH | No |
| **Concurrency / lock stress** | `scripts/concurrency_test.py` | N parallel booking POSTs → exactly one 201 | No (needs live API + token) |
| **Voice / STT probes** | `scripts/voice/*` | Model probes, live STT checks | No |
| **Deploy pipeline smoke** | `docs/runbooks/*`, post-bootstrap | `curl /health`, login, cert ACTIVE | Documented manual |
| **DR bootstrap verification** | `drill-bootstrap.sh` Phase 8 | Cloud Run Ready, frontend projectId, terraform plan, LB health | In bootstrap only |

### 1.3 Explicitly **missing** (or incomplete)

| Desired suite | Status |
|---|---|
| **Smoke (deployed env)** | Informal only (`curl /health`, manual login) — not a versioned suite in CI |
| **Regression (product paths)** | Overlaps hermetic unit/API tests; **no** live multi-step regression pack |
| **Functional / E2E (browser)** | Called out as OPEN (Playwright) in project review; **not implemented** |
| **Performance / load** | Only concurrency proof script; no k6/Locust baseline or SLO harness |
| **Security suite** | Bandit + policy tests only; no DAST / dependency audit gate documented as a suite |
| **Contract / OpenAPI** | No published OpenAPI contract tests |

---

## 2. Target test suite model

Map current assets into named suites and fill gaps over time.

```text
┌─────────────────────────────────────────────────────────────┐
│  PR gates (CI)                                              │
│  regression-unit = backend pytest + frontend vitest         │
│  static = ruff + bandit + lint + architecture               │
└───────────────────────────┬─────────────────────────────────┘
                            │ green
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Deploy candidate → environment                             │
│  smoke-env        = health + auth project + admin login     │
│  functional-env   = critical user journeys (E2E)            │
│  performance-env  = concurrency + latency sample            │
└───────────────────────────┬─────────────────────────────────┘
                            │ green + approval
                            ▼
                   promote to next env
```

### 2.1 Smoke suite (deployed environment)

**Purpose:** “Is this environment alive and basically usable?” (~5 minutes)

| # | Check | How |
|---|---|---|
| S1 | HTTPS health | `curl -sf https://admin-<env>.…/health` → `{"status":"ok"}` |
| S2 | Version/build | `curl -sf https://admin-<env>.…/version` (if exposed) |
| S3 | Frontend project isolation | Hosted JS embeds correct `projectId` (bootstrap Phase 8 check) |
| S4 | Platform admin sign-in | Login with known admin; optional force-password if seeded |
| S5 | Auth project | Firebase project matches env (not cross-env) |

**Runbook script (operator):** see §4.1  
**CI target (future):** post-deploy job per environment.

### 2.2 Regression suite

**Purpose:** “Did we break existing behaviour?”

| Layer | Content | When |
|---|---|---|
| **R1 — Unit/API regression** | Full `backend` pytest + `frontend` vitest | Every PR (already) |
| **R2 — Product regression pack** | Curated list of API/UI scenarios that previously failed (password gate, tenant isolation, booking cancel, invoice agent, catalog) | Before promote test→prod; expand over time |
| **R3 — Architecture regression** | `test_architecture.py` | Every PR (already) |

R1 is **mandatory green** before any env deploy.  
R2 starts as a **documented checklist** until E2E automation exists.

### 2.3 Functional suite

**Purpose:** “Does the product do what we claim end-to-end?”

| Journey | Actors | Priority |
|---|---|---|
| F1 | Platform admin: seed → force password change → facility catalog CRUD | P0 |
| F2 | Platform admin: create tenant + tenant admin user | P0 |
| F3 | Tenant admin: create facility from catalog, set schedule | P0 |
| F4 | Tenant admin: provision resident (6-digit code) | P0 |
| F5 | Resident: sign-in → force password → view availability → book → cancel | P0 |
| F6 | Tenant admin: daily overview / invoices (as applicable) | P1 |
| F7 | Agent text book/cancel (if Vertex enabled in env) | P1 |
| F8 | Voice turn (if STT/TTS enabled) | P2 |

**Automated S-FUNC (live env, API + SPA scrape):** `tests/functional/` (~25 tests)  
Run: `./scripts/run_functional.sh` (interactive prompts + defaults).  

| Area | Coverage |
|---|---|
| Env wiring | SPA projectId / `VITE_BASE_DOMAIN`, health build meta, TLS, host isolation |
| Booking | availability, horizon, Redis lock, book→cancel, concurrency N→1 |
| Admin | facility catalog CRUD, create tenant + temp password + force-change |
| Tenant admin | daily overview (resident forbidden) |
| Agent | text (Vertex not fallback-only); voice optional |
| Identity | `/users/me` |

**Browser Playwright:** `tests/e2e/` (sign-in + facilities smoke).  
**CI:** Actions → Functional (S-FUNC) workflow_dispatch (secrets required).  
**R2 list:** `docs/testing/R2-REGRESSION-PACK.md`.

### 2.4 Performance suite

**Purpose:** “Does the env meet basic capacity / contention expectations?”

| # | Check | Tool | Pass criteria |
|---|---|---|---|
| P1 | Slot lock concurrency | `scripts/concurrency_test.py` | Exactly one 201; rest 409/422 |
| P2 | Health latency sample | `curl` / simple loop | p95 &lt; env SLO (document target e.g. 500 ms) |
| P3 | Booking create under light load | Future k6 | TBD after baseline measurement |

**Do not** run destructive load against prod without change window.

### 2.5 Other relevant suites

| Suite | Purpose | Status |
|---|---|---|
| **Security** | bandit, password policy, no secrets in git | Partial (CI) |
| **A11y** | `a11y.audit.test.tsx` | Partial (frontend) |
| **DR / resilience** | `drill-bootstrap.sh` rebuild | Manual / drill |
| **Contract** | OpenAPI / schema freeze | Not started |

---

## 3. Mapping: suite → commands (local / CI)

| Suite ID | Command (local) | CI today |
|---|---|---|
| R1 backend | `cd backend && uv run pytest --cov=src --cov-fail-under=90 -q` | Yes |
| R1 frontend | `cd frontend && pnpm test` | Yes |
| Static | `uv run ruff check src/ tests/` · `uv run bandit -r src/` · `pnpm lint` | Yes |
| Smoke-env | §4.1 script + subset of `tests/functional` | Partial (deploy health) |
| Functional | `./scripts/run_functional.sh` + §4.2 manual for provisioning | **Automated** live pack in `tests/functional/` |
| Performance P1 | §4.3 concurrency | No |

---

## 4. Execute against **test** environment

Replace hosts/project with your test values.

**Example test-01:**

```text
PROJECT=slot-sense-test-01
ADMIN_URL=https://admin-test.slotsense.chandraailabs.com
```

### 4.1 Smoke suite (run after every deploy to test)

```bash
# S1
curl -sf "$ADMIN_URL/health" && echo

# S3 (optional, gcloud)
ASSET=$(gcloud storage ls "gs://${PROJECT}-frontend/assets/index-*.js" | head -1)
gcloud storage cat "$ASSET" | grep -oE 'projectId:"[^"]+"' | head -1
# expect: projectId:"slot-sense-test-01"

# S4 — browser: open ADMIN_URL, sign in as platform admin
# If freshly seeded: expect force-password with 6-digit code, then set real password
```

**Pass:** S1 green + S4 succeeds + S3 shows correct projectId.

### 4.2 Functional pack

#### Automated (S-FUNC) — run after every promote to test

```bash
cp tests/functional/.env.example tests/functional/.env.local
# set FUNC_* credentials for a resident on the target tenant
set -a && source tests/functional/.env.local && set +a
./scripts/run_functional.sh
```

**Pass:** all non-skipped tests green. Skips print reason (missing creds / no bookable slot).

#### Manual (provisioning journeys until Playwright)

Use a private browser window. Record pass/fail in a sheet or PR comment.

| ID | Steps | Pass |
|---|---|---|
| F1 | Re-seed or use admin with `must_change_password` → forced change → `/admin` | ☐ |
| F1b | `/admin/facility-catalog` → add type → edit → delete (or leave one) | ☐ |
| F2 | Create tenant with slug e.g. `demo` under env base domain → tenant_admin + 6-digit code | ☐ |
| F3 | Tenant admin login on `{slug}.{base}` → add facility from catalog | ☐ |
| F4–F5 | Create resident → force password → book → cancel (also covered partially by automated pack) | ☐ |

### 4.3 Performance P1 (concurrency)

```bash
# Obtain resident/token for test tenant (scripts/get_dev_token.sh adapted, or console)
export TOKEN='...'
cd backend
uv run python ../scripts/concurrency_test.py \
  --base "$ADMIN_URL" \
  --facility <FACILITY_ID> \
  --date YYYY-MM-DD \
  --start HH:MM \
  --n 20
```

**Pass:** exactly one HTTP 201.

---

## 5. Build promotion: dev → test → prod

### 5.1 Principles

1. **Same artifact** promotes upward (same image digest / same frontend commit SHA).  
2. **Gates increase** with environment risk (prod needs human approval).  
3. **No direct push to prod** without green test-env smoke (+ functional pack for major releases).  
4. **Config/secrets stay per env** (never promote Secret Manager values).

### 5.2 Target mechanism (recommended)

| Stage | Trigger | Deploy target | Required gates |
|---|---|---|---|
| **Build** | PR merge to `main` | Artifact Registry image + built frontend assets (immutable tag = git SHA) | R1 + static CI |
| **Dev** | Auto on `main` **or** manual workflow_dispatch | `slot-sense-dev-*` / legacy `sport-slot-dev` | CI green |
| **Test** | Manual “Promote to test” (workflow_dispatch) with **image tag / SHA** input | `slot-sense-test-*` | CI green + optional smoke on previous env |
| **Prod** | Manual “Promote to prod” + **GitHub Environment approval** | prod project | Smoke + functional pack on **test** recorded green |

```text
  main merge
      │
      ▼
  CI gates (R1 + static)
      │
      ├──► publish image :${GIT_SHA}
      │
      ▼
  [optional auto] deploy DEV
      │
      ▼
  workflow_dispatch: promote TEST (sha)
      │     run smoke-env on test
      │     run functional pack (manual or future E2E)
      ▼
  workflow_dispatch: promote PROD (sha)
        requires reviewer + smoke/functional evidence
```

### 5.3 Current state vs target

| Capability | Today | Target |
|---|---|---|
| CI gates on PR/main | Yes | Keep |
| Deploy on main | **Parameterized** `deploy.yml` (option A) | Keep; add prod when ready |
| Auto-deploy standing dev | `push` → `sport-slot-dev` (**build** image) | Keep |
| Promote by SHA | **`workflow_dispatch`** + env + optional `git_sha` | Keep |
| Same API image digest | **`promote_from` + `promote_image.sh`** (copy AR→AR) | Keep; fail if source missing |
| Frontend per env | Rebuild with target `VITE_*` | Keep (env config baked) |
| Registry | `.github/deploy-environments.json` + firebase web configs | Extend per new env |
| S-SMOKE after deploy | Health curl with retries | Optional login smoke later |
| GitHub Environments | Jobs use `dev` / `test` | Required reviewers in Settings |
| Test evidence for prod | Informal until prod exists | ADR-0045 D5 checklist |

Design detail: [docs/design/same-sha-image-promote.md](../design/same-sha-image-promote.md).

### 5.4 Promote to **test** (primary path — GitHub Actions)

1. Commit is on **`main`** (WIF only allows `refs/heads/main`).  
2. That SHA must already have been **built on standing dev** (image tag =
   short SHA in `sport-slot-dev` / `sport-slot-repo`).  
3. On **dev** Terraform: `artifact_registry_reader_members` includes the test
   WIF `principalSet` (one-time IAM; see design doc).  
4. Open **Actions → Deploy → Run workflow**.  
5. Branch: **main**.  
6. Inputs:  
   - **environment:** `slot-sense-test-01`  
   - **git_sha:** full SHA to promote, or empty for current branch tip  
7. Wait for `resolve` → `gates` → `deploy` → `smoke`.  
   Deploy logs should show `image_mode=promote` and **no** Cloud Build for the API.  
8. Confirm health on the env base domain, e.g.  
   `https://admin.slotsense-test.chandraailabs.com/health` (ADR-0046).

**Once per repo:** Settings → Environments → create **`dev`** and **`test`**  
(names must match `github_environment` in `deploy-environments.json`).

**Add a new env:** firebase web JSON + row in `deploy-environments.json`
(`promote_from` for non-build envs) + workflow choice option + AR reader IAM on source.

### 5.5 Manual deploy fallback (if Actions unavailable)

```bash
# Prefer promote (same digest as dev) after test recreate:
export SLOTSENSE_PROJECT=slot-sense-test-01
export SLOTSENSE_REGION=asia-south1
export SLOTSENSE_ARTIFACT_REPO=slot-sense-repo
export SLOTSENSE_SOURCE_PROJECT=sport-slot-dev
export SLOTSENSE_SOURCE_ARTIFACT_REPO=sport-slot-repo
export SLOTSENSE_BASE_DOMAIN=slotsense-test.chandraailabs.com
export SLOTSENSE_ADMIN_HOST=admin.slotsense-test.chandraailabs.com
export CI=true
./scripts/promote_image.sh <git-sha>
./scripts/deploy_cloud_run.sh "$(cat .last_image_tag)"
# frontend: VITE_BASE_DOMAIN + VITE_FIREBASE_* from
# infrastructure/firebase-web-configs/slot-sense-test-01.json
# + deploy_hosting_rest + GCS sync (same as workflow)
```

### 5.6 Remaining backlog

| ID | Work |
|---|---|
| GH-ENVIRONMENTS-PROTECTION | Required reviewers on `test` / `prod` Environments |
| PROD-REGISTRY-ROW | Add prod project to `deploy-environments.json` when live |
| E2E-PLAYWRIGHT | Automate F1–F5 against test |
| PERF-BASELINE | Concurrency + p95 baselines then gate |

---

## 6. Release evidence template (paste into PR or release note)

```text
Release candidate: <git sha>
Image: <region>-docker.pkg.dev/<project>/slot-sense-repo/sport-slot-api:<sha>

CI (R1 + static): PASS / FAIL — <link>
Smoke test env:   PASS / FAIL — date, admin URL, health output
Functional pack:  PASS / FAIL — F1..F5 checkboxes
Performance P1:   PASS / FAIL / SKIP — concurrency result
Approver (prod):  <name>
```

---

## 7. Summary

| Question | Answer |
|---|---|
| What suites exist? | Strong **hermetic** backend + frontend regression in CI; ad-hoc concurrency + DR bootstrap; **no** full smoke/E2E/perf product suites yet |
| What should we have? | Smoke / Regression / Functional / Performance (+ security, a11y, DR) as in §2 |
| How to run on test? | §4 — smoke now; functional checklist; concurrency when tenant exists |
| How to promote? | Same SHA upward; CI → dev; manual promote to test with smoke; prod with approval + test evidence (§5) |

**Related:** `docs/runbooks/create-environment-step-by-step.md`, `docs/runbooks/provision-environment.md`, ADR-0008 (architecture tests), project review action plan P2.3 (Playwright).
