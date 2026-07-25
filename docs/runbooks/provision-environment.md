# Provision a new SlotSense environment

One-page operator card. Assumes minimal SlotSense context. The
authoritative technical reference is
`docs/runbooks/disaster-recovery.md`; this card tells you what
commands to run and what to do when they fail.

## What this does

`scripts/drill-bootstrap.sh` builds a fresh GCP project end-to-end:
project creation and billing link, API enablement, Terraform state
bucket, Firebase addition, the bootstrap-group Terraform apply (Redis,
Artifact Registry, Cloud Build SA/IAM, secret shells), a backend image
build, secret value population, the main Terraform apply, Firestore
rules/indexes, frontend build + Hosting deploy, and platform-admin
seeding, ending in an automated verification pass. Total run time is
roughly 45–60 minutes, most of it Redis instance creation (~9–10 min)
and operator review time on the main `terraform apply` (skip the
review with `--yes`). The result is a working Cloud Run backend +
Firebase Hosting frontend, missing only DNS and certificate issuance
(handled manually — see "Post-run manual tail" below).

## Prerequisites

- `gcloud`, `terraform`, `firebase` (CLI), `pnpm`, `uv` installed and
  on `PATH`.
- A Resend API key, retrieved from the password manager ahead of time
  (needed by Phase 5; interactive mode will prompt for it if not
  exported).
- Sufficient billing-account project quota. Google's default is 5
  projects per billing account, and **a project in `DELETE_REQUESTED`
  still counts against that quota for 30 days** — check current usage
  before you start if you've deleted a project recently:
  ```
  gcloud billing projects list --billing-account=<id> | wc -l
  ```

## Preflight

Run these five commands, in order, before invoking the script.

```
gcloud auth login
```
Interactive browser login for your own gcloud user credentials.
Expected: "You are now logged in as [you@example.com]."

```
gcloud auth application-default login
```
Sets up Application Default Credentials (ADC) — what Terraform and
most `gcloud` client libraries actually use. This is the credential
that expires and causes the most common failure (see "invalid_grant"
below).
Expected: "Credentials saved to file: [...application_default_credentials.json]".

```
gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"
```
Confirms the ADC token is actually valid right now, not just present
on disk. `drill-bootstrap.sh` runs this exact check itself at Phase 0
and hard-fails with the same fix if it's stale — running it yourself
first just saves you the round-trip.
Expected: `ADC OK`.

```
firebase login
```
Interactive browser login for the Firebase CLI (used in Phase 2 and
Phase 7).
Expected: "Success! Logged in as you@example.com".

```
export SLOTSENSE_RESEND_API_KEY=<value from password manager>
```
Only required if you intend to run `--non-interactive`; interactive
mode will prompt for this (input hidden, never echoed) at Phase 0
instead.

## Run

```
time scripts/drill-bootstrap.sh --project-id <new> --environment <env> --yes
```

`<new>` must match the naming rule in `terraform/variables.tf`:
`slot-sense-{dev|test|prod-XX}[-NN]` (e.g. `slot-sense-dev-03`,
`slot-sense-test-01`, `slot-sense-prod-india-01`). `<env>` is one of
`dev`, `test`, `prod-india`, `prod-uae`. `--yes` auto-approves
Terraform applies and confirmation prompts — omit it if you want to
review each apply's plan interactively (adds operator time to the
Phase 6 timing, not a functional difference).

Run `scripts/drill-bootstrap.sh --dry-run --project-id <new> --environment <env>`
first if you want to see the full plan with zero live calls.

## Known failures and one-line fixes

### "Cloud billing quota exceeded" in Phase 1

Google's per-billing-account project quota is exceeded. Projects in
`DELETE_REQUESTED` count against quota for 30 days.

Fix: request a quota increase at
https://support.google.com/code/contact/billing_quota_increase, OR
delete an older project you don't need. Check current usage:
```
gcloud billing projects list --billing-account=<id> | wc -l
```

### "invalid_grant" / "invalid_rapt" during terraform init in Phase 1

ADC token expired.

Fix:
```
gcloud auth application-default login
```
Then resume:
```
scripts/drill-bootstrap.sh --project-id <new> --start-phase 1 --yes
```
(Post-PR-I, this is caught by the Phase 0 preflight instead.)

### "SERVICE_DISABLED" for any googleapis.com API in Phase 3

Google API propagation lag. The API was enabled in the same apply
that tried to use it, and Google's serving stack hadn't caught up.

Fix: wait 60s, resume:
```
scripts/drill-bootstrap.sh --project-id <new> --start-phase 3 --yes
```
(Post-PR-I, Phase 3 is split into 3a/3b with a built-in 60s sleep to
prevent this.)

### "Unknown service account" or "storage.objects.get access denied" in Phase 4

`sa-cloud-build` or its IAM bindings weren't created in Phase 3.
Should not occur post-PR-I. If it does, Phase 3b was incomplete;
resume:
```
scripts/drill-bootstrap.sh --project-id <new> --start-phase 3 --yes
```

## Post-run manual tail

1. **Handle the manifest.** The run writes
   `bootstrap-output-<project>-<timestamp>.md` (gitignored). Copy the
   admin email and temp password into the password manager, then
   **delete the file**. (The manifest itself warns about this.)

2. **Add a `tf.sh` registry entry.** Copy the entry block from the
   manifest into `scripts/tf.sh` — add `"<env>"` to `ENV_NAMES` and
   the corresponding `case` arm. Commit as a small PR.

3. **Create DNS records at Namecheap** (values from the manifest):
   - A record: `rvrg-<env>.slotsense.chandraailabs.com` → LB IP (or
     `rvrg.slotsense.chandraailabs.com` for prod).
   - CNAME for cert renewal: `<name>` → `<value>` — **permanent, do
     not delete**.
   The wildcard `*.slotsense.chandraailabs.com` cert already covers
   `rvrg-dev`, `rvrg-test`, `rvrg` (one label under the wildcard) —
   no new certificate request is needed for a standard dev/test
   label.

4. **Wait for the cert to go ACTIVE** (~5–30 min after DNS
   propagates):
   ```
   gcloud certificate-manager certificates describe <cert-name> --project=<new>
   ```

5. **Verify end-to-end:**
   ```
   curl -sf https://rvrg-<env>.slotsense.chandraailabs.com/health
   ```
   Should return `{"status":"ok"}`. Environment is ready.

## When it fails partway

Every phase is idempotent. Resume from the failed phase with
```
scripts/drill-bootstrap.sh --project-id <new> --start-phase <N> --yes
```
The state cache (`.drill-bootstrap-state-<project>.env`) remembers
every input from the failed run; only `SLOTSENSE_RESEND_API_KEY`
needs to be re-supplied if resuming at or before Phase 5.

## Full technical reference

`docs/runbooks/disaster-recovery.md` §4.1 — every step the script
encodes, plus the manual fallback procedure.
