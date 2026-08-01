# Provision a new SlotSense environment

One-page operator card (commands + failure table).

**Prefer the full walkthrough if this is your first time:**
[`create-environment-step-by-step.md`](./create-environment-step-by-step.md)
— plain-English, start-to-finish checklist so a non-expert can bring an
environment fully online (automated script + DNS + first login).

Technical depth: [`disaster-recovery.md`](./disaster-recovery.md).

## What this does

`scripts/drill-bootstrap.sh` builds a fresh GCP project end-to-end for
**any** environment (`dev` / `test` / `prod-india` / `prod-uae`):

project creation and billing link → API enablement → Terraform state
bucket → Firebase project + **WEB app + public SDK config** →
bootstrap-group Terraform apply (Redis, Artifact Registry, Cloud Build
SA/IAM, secret shells, Email/Password Auth) → backend image build →
secret value population → main Terraform apply → corrective Cloud Run
deploy (project-scoped env vars) → Firestore rules/indexes →
**frontend build with `VITE_FIREBASE_*` for the target project**
(verified in `dist` and in GCS) → Hosting + frontend bucket sync →
platform-admin seed against `--project` → `scripts/tf.sh` registry
entry → automated verification.

Total run time is roughly 45–60 minutes for a cold project (most of it
Redis ~9–10 min); a resume or re-run on an existing project is much
faster. Use `--yes` to skip interactive Terraform review. The result
is a working Cloud Run backend + SPA that authenticates against **this
project's** Firebase Auth — missing only DNS at the external registrar
(see "Post-run manual tail").

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

### "Authentication Error / Your credentials are no longer valid" (Firebase CLI)

Firebase CLI tokens expire faster than gcloud ADC (~1 hour idle). This
can hit mid-run — on the dev-03 drill it killed Phase 7's
`firebase deploy` about 30 minutes in. Post-PR-J, a Phase 0 preflight
(`firebase projects:list`) catches this before the run starts; if you
still hit it mid-run (token expired during a long-running phase):

Fix:
```
firebase login --reauth
```
Then resume from the phase that failed:
```
scripts/drill-bootstrap.sh --project-id <new> --start-phase <N> --yes
```

## What is automatic vs still manual

| Step | Owner |
|---|---|
| GCP project, billing, APIs, state bucket | Script |
| Firebase project + Email/Password provider | Script (+ Terraform) |
| Firebase **WEB app** + SDK config | Script (Phase 2) |
| Redis, secrets shells + values, Artifact Registry, IAM, LB, Cloud Run | Script |
| Frontend build **wired to target Firebase project** | Script (Phase 7; fails if wrong `projectId` in dist) |
| Hosting + `gs://<project>-frontend` sync | Script |
| Platform admin seed (`--project` explicit) | Script |
| `scripts/tf.sh` registry entry | Script (auto-edits; **commit** the diff) |
| Namecheap DNS A + cert CNAME | **Manual** (external registrar) |
| Password-manager capture of temp admin password | **Manual** |
| GitHub Actions `deploy.yml` target project | **Manual** until CI is multi-env |

Default hosts (overridable with flags). **No tenant name in bootstrap** —
platform admin only. Tenants get their own `{slug}.<base>` DNS later.

| `--environment` | Platform admin + health host |
|---|---|
| `dev` | `admin-dev.<base>` |
| `test` | `admin-test.<base>` |
| `prod-india` / `prod-uae` | `admin.<base>` |

**Multi-env DNS:** do **not** point `*.slotsense…` at a single LB IP.
Each env has its own LB; use explicit A records (`admin-test` → test IP,
`admin-dev` → dev IP). The wildcard is for the **TLS certificate**, not
one shared A record.

## Post-run manual tail

1. **Handle the manifest.** The run writes
   `bootstrap-output-<project>-<timestamp>.md` (gitignored). Copy the
   admin email and temp password into the password manager, then
   **delete the file**. (The manifest itself warns about this.)

2. **Commit the `scripts/tf.sh` registry edit** the script made (if this
   was a brand-new env name). No manual copy-paste of case arms.

3. **Create DNS records at Namecheap** (exact values are in the
   manifest):
   - A: platform admin host (e.g. `admin-test.slotsense.chandraailabs.com`)
     → **this env’s** LB IP only
   - Later, per tenant: A `{slug}.slotsense…` → **same** env LB IP
   - CNAME for cert renewal: `<name>` → `<value>` — **permanent, do
     not delete**.
   Do **not** use one global `*.slotsense → one IP` if dev/test/prod
   must all stay up (that would pin every subdomain to one project).

4. **Wait for the cert to go ACTIVE** (~5–30 min after DNS
   propagates):
   ```
   gcloud certificate-manager certificates describe slotsense-wildcard-cert --project=<new>
   ```

5. **Verify end-to-end:**
   ```
   curl -sf https://admin-test.slotsense.chandraailabs.com/health   # example for test
   ```
   Should return `{"status":"ok"}`. Then sign in at the **admin** host
   with the seeded platform-admin credentials (fresh browser session).

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
