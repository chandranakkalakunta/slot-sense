# Environment power control (FinOps sleep / wake)

**ADR:** [ADR-0047](../adr/0047-environment-power-control-finops.md)  
**Script:** `scripts/env-power.sh`  
**Registry:** `infrastructure/env-power.json`  
**Nightly:** `.github/workflows/env-nightly-disable.yml` (23:00 Asia/Kolkata)

## What it does

| Action | Effect |
|--------|--------|
| **disable** | Delete Memorystore Redis, Cloud Run `min=0`, pause Cloud Scheduler, soft-pause uptime path |
| **enable** | Recreate Redis (~10–20 min), refresh `redis-auth`, patch Cloud Run Redis env, restore min, resume jobs/uptime |
| **hold** | Skip **nightly** disable until expiry (soak / multi-day tests) |
| **status** | Power state, redis present/absent, min instances, hold |

**Preserved while off:** LB, static IP, certs, DNS, Firestore, Auth users, frontend bucket, images.

**Residual cost while DISABLED:** global LB / IP + storage — not absolute ₹0 (ADR-0047 D1).

## Prerequisites

- `gcloud` authenticated to the target project (Coordinator ADC for manual use)
- `jq`, `python3`, `curl`
- After first merge: **`terraform apply`** on each env so `terraform/env_power.tf` creates `gs://<project>-env-power` and grants CI WIF Redis admin + related roles (needed for nightly GHA)

```bash
scripts/tf.sh test-03 apply -target=google_storage_bucket.env_power \
  -target=google_project_iam_member.ci_redis_admin \
  -target=google_project_iam_member.ci_cloudscheduler_admin \
  -target=google_project_iam_member.ci_monitoring_uptime_editor \
  -target=google_project_iam_member.ci_secretmanager_version_adder \
  -target=google_storage_bucket_iam_member.ci_env_power_object_admin
# or full apply
scripts/tf.sh test-03 apply
```

## Everyday use

```bash
# See all envs
make env-list
# or
scripts/env-power.sh list

# Morning — need the env
make env-enable ENV=test-03
# non-interactive:
scripts/env-power.sh enable --env test-03 --yes

# Done for the day (or let 23:00 IST job do it)
make env-disable ENV=test-03

# Soak overnight — do NOT let nightly kill the env
make env-hold ENV=test-03 DAYS=1 REASON="booking concurrency soak"
# or
scripts/env-power.sh hold --env test-03 --until 2026-08-07T23:59:59+05:30 --reason "soak"

# Clear hold early
scripts/env-power.sh release-hold --env test-03

# Inspect
make env-status ENV=test-03
```

## Nightly automation

- **Cron:** `30 17 * * *` UTC → **23:00 Asia/Kolkata**
- Matrix: every env in `env-power.json` with `"nightly_disable": true` **and** a `project_number` (for WIF)
- Skips env if `hold.json` is active (`reason=nightly` path inside the script)
- **Global kill-switch:** GitHub repo variable `ENV_POWER_NIGHTLY_DISABLED=true`
- **Manual run:** Actions → “Env nightly disable” → workflow_dispatch (optional single `env`)

### Adding `project_number`

Nightly WIF needs `project_number` on the env row (or a matching entry in `.github/deploy-environments.json`). Example:

```json
"test-03": {
  "project_id": "slot-sense-test-03",
  "project_number": "476524854130",
  "nightly_disable": true,
  ...
}
```

Get number: `gcloud projects describe PROJECT_ID --format='value(projectNumber)'`

### Prod with real customers

Set `"nightly_disable": false` for that env in `infrastructure/env-power.json` before go-live. Manual disable remains available for break-glass.

## Terraform while disabled

If Redis was deleted by env-power, the next `terraform plan` may show Redis recreate. That is expected. Prefer:

1. `env-power enable` (restores Redis + secret + Cloud Run env), **or**
2. `terraform apply` only if you intend to power the env back via TF (still run enable-style secret/host patch if deploy expects live Redis)

Do not leave an env half-woken (Redis up, Cloud Run still pointing at old host).

## Safety

- Interactive disable requires typing `DISABLE <env>` unless `--yes`
- Scripts never delete Firestore, Auth users, LB, or certs
- Scripts never disable the billing account (ADR-0042)

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Nightly skipped | hold active? `ENV_POWER_NIGHTLY_DISABLED`? missing `project_number`? |
| Enable stuck | Redis state: `gcloud redis instances describe sport-slot-redis --region=asia-south1` |
| Bookings 503 after enable | Redis host/auth: re-run `enable` or redeploy; confirm secret `redis-auth` latest |
| Permission denied in GHA | Apply `terraform/env_power.tf` IAM bindings for the WIF principal |
| Uptime still alerting | Soft-pause is best-effort path change; silence policy or re-run enable |
