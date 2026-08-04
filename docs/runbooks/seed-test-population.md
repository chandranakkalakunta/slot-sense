# Seed test population (multi-tenant load data)

**Audience:** Coordinator  
**Env:** `slot-sense-test-03` (or any test project)  
**Script:** `scripts/seed_test_population.py`

## What it creates

| Resource | Spec |
|---|---|
| Tenants | 20 (includes `marina-skies`, `rvrg` + 18 new) |
| Flats / tenant | Random **250–2000** |
| Members / flat | Random **2–6** |
| Emails | `{slug}.resident.{n}@example.com` (global counter) |
| Password | `ResidentPass143$` (`must_change_password=false`) |
| Facilities | Delete+recreate; **1–3 per catalog type** by tenant size |
| Policies | horizon 7 days, window 06:00 (new tenants) |
| Cloud Run | Optional `--set-min-instances=1` |

Existing Auth users on marina-skies/rvrg are **kept** (email conflict → password reset + claims refresh). Facilities are **recreated** by default.

**Scale:** mid ~80k residents; high up to ~240k. Full run can take **hours**. Resumable via `.seed-test-population-state.json`.

## Prerequisites

```bash
gcloud auth application-default login
gcloud config set project slot-sense-test-03
# ADC user needs Firebase Auth Admin + Firestore on the project
```

## Smoke (recommended first)

```bash
cd backend
uv run python ../scripts/seed_test_population.py \
  --project slot-sense-test-03 \
  --max-flats 5 \
  --max-users-per-tenant 20 \
  --dry-run

uv run python ../scripts/seed_test_population.py \
  --project slot-sense-test-03 \
  --max-flats 5 \
  --max-users-per-tenant 20
```

## Full seed

```bash
cd backend
uv run python ../scripts/seed_test_population.py \
  --project slot-sense-test-03 \
  --set-min-instances 1
```

Interrupt anytime; re-run the same command to **resume**.

## Terraform (min instances, durable)

In `terraform/slot-sense-test-03.tfvars` (local):

```hcl
cloud_run_min_instances = 1
cloud_run_max_instances = 10
```

```bash
./scripts/tf.sh test-03 apply
```

## Perf after seed

```bash
# Token for any seed resident
export SPORTSLOT_WEB_API_KEY=$(jq -r .apiKey infrastructure/firebase-web-configs/slot-sense-test-03.json)
TOKEN=$(./scripts/get_dev_token.sh 'marina-skies.resident.1@example.com' 'ResidentPass143$')

# Pick a facility id from tenant admin UI or Firestore, then:
cd backend
TOKEN="$TOKEN" uv run python ../scripts/concurrency_test.py \
  --base https://marina-skies.slotsense-test.chandraailabs.com \
  --facility <FACILITY_ID> \
  --date YYYY-MM-DD \
  --start HH:MM \
  --n 30
```

## Notes

- Does **not** use HTTP bulk import (500/req + Cloud Run timeout); same data model as bulk create with final password for load testing.
- No welcome emails enqueued (avoids Resend flood).
- State file is gitignored (`.seed-test-population-state.json`).
