# Create a SlotSense environment — step-by-step guide

**Audience:** Anyone who can follow written English instructions and use a
Mac/Linux terminal. You do **not** need to understand SlotSense internals.

**Goal:** After you finish every step in this document, a new environment
(dev, test, or prod) is **up and running**: you can open the website in a
browser, sign in as platform admin, and the backend health check returns OK.

**Time:** about **45–90 minutes** for a brand-new Google Cloud project
(most waiting is automatic). DNS can add **5–30 more minutes**.

**Related docs (shorter / deeper):**

| Document | When to use it |
|---|---|
| **This file** | Full walkthrough from zero → running environment |
| [`provision-environment.md`](./provision-environment.md) | One-page cheat sheet (commands only) |
| [`disaster-recovery.md`](./disaster-recovery.md) | Deep technical design, disaster classes, layer-by-layer recovery |

---

## 1. What you are building (plain English)

SlotSense runs in **Google Cloud**. Each “environment” is a **separate
Google Cloud project** with its own:

- database (Firestore)
- login system (Firebase Auth)
- backend API (Cloud Run)
- website files (frontend)
- load balancer and HTTPS certificate

One script builds almost everything:

```text
scripts/drill-bootstrap.sh
```

You still do a few **manual** things the script cannot do:

1. Log in to Google / Firebase on your computer  
2. Create DNS records at Namecheap (our domain registrar)  
3. Save the admin password into a password manager  
4. Commit one small code change (`scripts/tf.sh`) so the team can use Terraform later  

When those are done, the environment is live.

---

## 2. What you need before day-of

### 2.1 People and access

You need an account that can:

- Create projects in the **chandraailabs.com** Google Cloud organization  
- Link projects to the company **billing account**  
- Use **Firebase** on those projects  
- Log into **Namecheap** for DNS on `slotsense.chandraailabs.com`  
- Read the **Resend** API key from the company password manager  

If you do not have any of these, stop and ask the project owner (Coordinator)
before continuing.

### 2.2 Computer software

Work on **macOS or Linux**. Open the **Terminal** app.

You need these tools installed and available when you type their names:

| Tool | Purpose | Check command | Example healthy output |
|---|---|---|---|
| `git` | Download the code | `git --version` | `git version 2.x` |
| `gcloud` | Google Cloud CLI | `gcloud --version` | `Google Cloud SDK …` |
| `terraform` | Infrastructure automation | `terraform version` | `Terraform v1.…` |
| `firebase` | Firebase CLI | `firebase --version` | a version number |
| `node` + `pnpm` | Build the website | `node --version` / `pnpm --version` | Node 22+ recommended |
| `uv` | Run Python seed scripts | `uv --version` | `uv 0.…` |
| `jq` | JSON helper used by the script | `jq --version` | `jq-…` |
| `curl` | Health checks | `curl --version` | any modern curl |

**If a check command says “command not found”**, install that tool first
(ask a teammate, or use your normal install method: Homebrew on Mac is
typical). Do not continue until every check works.

### 2.3 Secrets you must have ready

| Secret | Where it comes from | How it is used |
|---|---|---|
| **Resend API key** | Password manager / Resend dashboard | Email sending (script Phase 5) |
| (Later) **Admin temp password** | Printed by the script once | First browser login — you save it |

Never put the Resend key or admin password into chat, email, or git commits.

### 2.4 Clean working tree (important for image build)

The script builds a backend container image tagged with the **current git
commit**. The build step **refuses to run** if you have uncommitted local
changes.

Before the real run:

```bash
cd /path/to/slot-sense
git status
```

Expected: clean working tree (`nothing to commit, working tree clean`),
or only files you intentionally leave out of the image build. If the tree
is dirty, **commit or stash** your work first.

---

## 3. Choose names (do this once on paper)

Fill in this table **before** you run anything. Use these values everywhere
below.

| Field | How to choose | Example (dev) | Example (test) | Your value |
|---|---|---|---|---|
| **Environment type** | One of: `dev`, `test`, `prod-india`, `prod-uae` | `dev` | `test` | |
| **Project ID** | Must match pattern: `slot-sense-{dev\|test\|prod-XX}[-NN]` | `slot-sense-dev-04` | `slot-sense-test-01` | |
| **Region** | Default `asia-south1` (use unless told otherwise) | `asia-south1` | `asia-south1` | |
| **Platform admin host** | Auto from env (no tenant name) | `admin-dev.slotsense.chandraailabs.com` | `admin-test.slotsense.chandraailabs.com` | |
| **Tenant hosts** | Created later when you add a tenant — not by bootstrap | e.g. `myclub-dev.…` | e.g. `myclub-test.…` | |

**Project ID rules (must match exactly):**

- Allowed: `slot-sense-dev-04`, `slot-sense-test-01`, `slot-sense-prod-india-01`  
- Not allowed: random names, uppercase, spaces  
- Legacy only (existing): `sport-slot-dev` — do **not** create a new project with this name  

**Host defaults (script chooses these unless you override):**

| Environment type | Platform admin + health (no tenant) |
|---|---|
| `dev` | `admin-dev.slotsense.chandraailabs.com` |
| `test` | `admin-test.slotsense.chandraailabs.com` |
| `prod-india` or `prod-uae` | `admin.slotsense.chandraailabs.com` |

Bootstrap does **not** create a demo tenant hostname. After go-live, each
tenant gets `{slug}.slotsense…` DNS → **this env’s** LB IP.

**Do not** point `*.slotsense…` at a single LB if dev/test/prod must all
run — use explicit A records per env host to each project’s IP.

> **Tip:** Write your Project ID and admin host on a sticky note.

---

## 4. Get the code on your machine

```bash
# If you do not already have the repo:
git clone https://github.com/chandranakkalakunta/slot-sense.git
cd slot-sense

# If you already have it:
cd /path/to/slot-sense
git checkout main
git pull
```

Confirm you are in the repo root (you should see folders `scripts/`,
`terraform/`, `frontend/`, `backend/`):

```bash
ls scripts/drill-bootstrap.sh terraform frontend backend
```

Expected: those paths exist (no “No such file” errors).

---

## 5. Preflight checklist (run in order)

Do **not** skip these. Most failures are expired logins.

### Step 5.1 — Google Cloud user login

```bash
gcloud auth login
```

- A browser window opens. Sign in with the Google account that has org access.  
- **Success looks like:** `You are now logged in as [you@example.com].`

### Step 5.2 — Application Default Credentials (ADC)

Terraform and many scripts use ADC, not only `gcloud auth login`.

```bash
gcloud auth application-default login
```

- Browser login again if asked.  
- **Success looks like:** `Credentials saved to file: ...application_default_credentials.json`

### Step 5.3 — Prove ADC works right now

```bash
gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"
```

- **Success:** `ADC OK`  
- **Failure:** repeat Step 5.2

### Step 5.4 — Firebase CLI login

```bash
firebase login
# If it says credentials are no longer valid:
firebase login --reauth
```

- **Success:** `Success! Logged in as …`  
- Prove it:

```bash
firebase projects:list
```

- You should see a table of projects (not an authentication error).

### Step 5.5 — Resend API key (optional before run)

**Interactive run (recommended first time):** the script will ask for the
key later and hide what you type. You can skip exporting it.

**Non-interactive run:** export it first:

```bash
export SLOTSENSE_RESEND_API_KEY='paste-key-here'
```

(Do not commit this. Do not leave it in shell history on a shared machine
if you can avoid it.)

### Step 5.6 — Billing project quota (if you create projects often)

Google limits how many projects attach to one billing account. Deleted
projects still count for ~30 days.

```bash
# Replace with your billing account id if different
gcloud billing projects list --billing-account=014A8C-586310-DE4575 | wc -l
```

If this number is at or above your quota (often 5), **stop** and free a
project or request a quota increase before continuing.

### Step 5.7 — Dry-run (safe rehearsal, no cloud changes)

Replace the example values with **your** Project ID and environment type:

```bash
cd /path/to/slot-sense

scripts/drill-bootstrap.sh \
  --project-id slot-sense-dev-04 \
  --environment dev \
  --dry-run \
  --non-interactive
```

**Success looks like:**

- A summary table of project_id, hosts, etc.  
- Messages saying `[dry-run] would …` for each phase  
- Final line: `Dry run complete — no gcloud/terraform/firebase calls were made.`

If dry-run fails on **invalid project_id** or **invalid environment**, fix
your names (Section 3) and try again.

---

## 6. Run the automated installer

### Step 6.1 — Start the real build

From the repo root, with a **clean git tree**:

```bash
cd /path/to/slot-sense

time scripts/drill-bootstrap.sh \
  --project-id slot-sense-dev-04 \
  --environment dev \
  --yes
```

What the flags mean:

| Flag | Meaning |
|---|---|
| `--project-id` | The new Google Cloud project name (must not already be someone else’s) |
| `--environment` | `dev` / `test` / `prod-india` / `prod-uae` |
| `--yes` | Auto-approve Terraform (no manual “yes” on each plan). Still fails if something errors. |

Without `--yes`, the script pauses for Terraform review (slower, fine for
learning).

### Step 6.2 — First interactive prompts (if not using `--non-interactive`)

You may be asked:

1. **Summary confirmation:** type exactly `BUILD` and press Enter  
2. **Resend API key:** paste the key (characters will not show) and press Enter  

### Step 6.3 — What you will see while it runs

The script prints large banners. Approximate order and wait times:

| Phase | Banner name | What it does | Typical wait |
|---|---|---|---|
| 0 | Inputs | Confirms settings | seconds |
| 1 | Project foundation | Creates GCP project, billing, state bucket | 1–3 min |
| 2 | Firebase | Enables Firebase + creates web app config | 1–2 min |
| 3 | Bootstrap-group apply | APIs, Redis, build SA, secret shells | **~10–15 min** (Redis is slow) |
| 4 | Image build | Builds backend container | 2–5 min |
| 5 | Secret values | Writes Redis auth + Resend key into Secret Manager | ~1 min |
| 6 | Main apply + deploy | Full Terraform + Cloud Run deploy | 5–15 min |
| 7 | Application enablement | Rules, frontend (correct Firebase project), admin user | 2–5 min |
| 8 | Verification | Automated checks | 1–3 min |
| 9 | Output manifest | Writes a results file with password + DNS values | seconds |

**Do not close the terminal** until you see:

```text
DONE
Environment build complete. See …/bootstrap-output-….md for the full manifest.
```

### Step 6.4 — If the script stops with an error

1. Read the last 20–30 lines. Note the phase number (`FATAL (Phase N): …`).  
2. Fix the cause using [Section 10 — Troubleshooting](#10-troubleshooting).  
3. Resume **from the failed phase** (do not start over unless instructed):

```bash
scripts/drill-bootstrap.sh \
  --project-id slot-sense-dev-04 \
  --start-phase N \
  --yes
```

Replace `N` with the phase number from the error message.

The script remembers your earlier choices in a local file:

```text
.drill-bootstrap-state-<project-id>.env
```

You usually do **not** need to re-type region/environment.  
If you resume at Phase 5 or earlier, you may need the Resend key again
(`export SLOTSENSE_RESEND_API_KEY=…` or answer the prompt).

---

## 7. Immediately after the script succeeds (critical)

### Step 7.1 — Open the manifest file

The script creates a file like:

```text
bootstrap-output-slot-sense-dev-04-20260726T153000Z.md
```

in the **repo root**. It is **gitignored** (must never be committed).

```bash
ls -la bootstrap-output-*.md
```

Open the newest one in any text editor.

### Step 7.2 — Save the admin password (do this first)

In the manifest, find:

- **Email** (usually `admin@chandraailabs.com`)  
- **Temp password**  

1. Copy both into the **company password manager** (1Password, Bitwarden, etc.).  
2. Label them clearly: e.g. `SlotSense slot-sense-dev-04 platform admin`.  
3. **Delete the manifest file** after saving:

```bash
rm bootstrap-output-slot-sense-dev-04-*.md
```

If you lose the password before saving it, re-seed (creates a new temp password):

```bash
cd backend
uv run python scripts/seed_platform_admin.py --project slot-sense-dev-04
```

Copy the new printed password into the password manager immediately.

### Step 7.3 — Note the DNS values from the manifest

From the same file (or re-run only Phase 9 is not separate — if you already
deleted the file, read LB IP with):

```bash
gcloud compute addresses describe slotsense-lb-ip \
  --global --project=slot-sense-dev-04 \
  --format='value(address)'
```

```bash
gcloud certificate-manager dns-authorizations describe slotsense-dns-auth \
  --project=slot-sense-dev-04 \
  --format='yaml(dnsResourceRecord)'
```

You need:

| Record purpose | Type | Name (host) | Value |
|---|---|---|---|
| Public website | **A** | e.g. `rvrg-dev` | LB IP from manifest |
| Admin site | **A** | e.g. `admin-dev` | **same** LB IP |
| Certificate proof (keep forever) | **CNAME** | from manifest (`_acme-challenge…`) | from manifest |

---

## 8. Manual DNS at Namecheap

These steps are outside Google Cloud. The environment is **not fully usable
in a browser over HTTPS** until DNS is correct (health via LB IP may work
earlier with special tools, but operators use the public hostnames).

### Step 8.1 — Sign in to Namecheap

1. Open Namecheap and sign in.  
2. Open the domain **`chandraailabs.com`** (or the account that holds
   `slotsense.chandraailabs.com`).  
3. Go to **Advanced DNS** (wording may vary slightly).

### Step 8.2 — Create the A records

Add (or update) records:

**Public host example (dev):**

| Type | Host | Value | TTL |
|---|---|---|---|
| A Record | `rvrg-dev.slotsense` | `<LB_IP from manifest>` | Automatic or 5 min |

(Namecheap “Host” fields vary: sometimes you enter `rvrg-dev.slotsense`
under domain `chandraailabs.com`. The full name must resolve to
`rvrg-dev.slotsense.chandraailabs.com`.)

**Admin host example (dev):**

| Type | Host | Value | TTL |
|---|---|---|---|
| A Record | `admin-dev.slotsense` | **same** `<LB_IP>` | Automatic or 5 min |

Use the **exact** hostnames from **your** manifest (test/prod differ).

### Step 8.3 — Create the certificate CNAME (permanent)

| Type | Host | Value | TTL |
|---|---|---|---|
| CNAME Record | value of `dnsResourceRecord.name` from gcloud (often `_acme-challenge.slotsense`) | value of `dnsResourceRecord.data` | Automatic |

**Do not delete this CNAME later.** It is required for HTTPS certificate
renewal.

### Step 8.4 — Wait for DNS

From your terminal:

```bash
dig +short rvrg-dev.slotsense.chandraailabs.com A
```

**Success:** prints your LB IP (same as the manifest).  
If empty or wrong, wait a few minutes and try again (or check the Host
field spelling in Namecheap).

---

## 9. Prove the environment is up

### Step 9.1 — Certificate active (HTTPS)

```bash
gcloud certificate-manager certificates describe slotsense-wildcard-cert \
  --project=slot-sense-dev-04 \
  --format='yaml(managed.state,managed.authorizationAttemptInfo)'
```

**Success:** `state: ACTIVE` (or managed state showing ACTIVE).  
If still provisioning, wait 5–30 minutes after DNS is correct and re-check.

### Step 9.2 — Health check over the public hostname

```bash
curl -sf https://rvrg-dev.slotsense.chandraailabs.com/health
echo
```

**Success:** exactly (or JSON equivalent of):

```json
{"status":"ok"}
```

**Failure cases:**

- Timeout / connection error → DNS not pointing at LB yet, or wrong IP  
- Certificate error → cert not ACTIVE yet; wait and retry  
- 404/502 → note the status and ask a teammate; script Phase 8 may have warned  

### Step 9.3 — Open the website and sign in

1. Open a **private/incognito** browser window (avoids old login sessions).  
2. Go to: `https://rvrg-dev.slotsense.chandraailabs.com`  
   (use **your** public host).  
3. Sign in with:
   - Email from password manager  
   - Temp password from password manager  
4. If the app asks you to **change password**, do so and store the new
   password in the password manager.  
5. You should land in the platform admin area (or be able to open `/admin`).

**If login fails with “wrong password”:**

- Confirm you are on the **new** host (not the old `admin.slotsense…` that
  may still point at an old project).  
- Re-seed (Section 7.2) and try again in a fresh private window.  

### Step 9.4 — Commit the Terraform registry edit

The script may have edited `scripts/tf.sh` so future Terraform commands
know this environment.

```bash
cd /path/to/slot-sense
git status
git diff scripts/tf.sh
```

If `scripts/tf.sh` changed:

```bash
git add scripts/tf.sh
git commit -m "chore(infra): register <your-env> in tf.sh"
# push via your normal PR process
```

Test the registry:

```bash
scripts/tf.sh --list
scripts/tf.sh dev-04 plan    # use the registry key shown in the manifest
```

(Registry key is usually the project suffix, e.g. `dev-04` for
`slot-sense-dev-04`.)

---

## 10. Troubleshooting

### 10.1 Common errors and fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| `project_id does not match … validation` | Bad project name | Fix naming (Section 3) |
| `Cloud billing quota exceeded` | Too many projects on billing account | Delete unused project or request quota increase |
| `invalid_grant` / `invalid_rapt` | ADC expired | `gcloud auth application-default login` then resume |
| `Authentication Error` (Firebase) | Firebase CLI token expired | `firebase login --reauth` then resume |
| `SERVICE_DISABLED` in Phase 3 | Google API not ready yet | Wait 60s; resume `--start-phase 3` |
| `working tree not clean` in Phase 4 | Uncommitted git changes | Commit or stash; resume `--start-phase 4` |
| Phase 7: frontend does not embed `projectId` | Script bug or wrong config | Re-run `--start-phase 7`; do not ignore this failure |
| Login works with **old** password, not new seed | Browser still talking to old Firebase project | Confirm URL host; hard-refresh; re-run Phase 7 |
| `curl` health times out | DNS not updated | Fix Namecheap A record; `dig +short …` |

### 10.2 How to resume (always the same pattern)

```bash
scripts/drill-bootstrap.sh \
  --project-id <YOUR_PROJECT_ID> \
  --start-phase <N> \
  --yes
```

Optional if Resend needed again:

```bash
export SLOTSENSE_RESEND_API_KEY='…'
```

### 10.3 Safe practice dry-run any time

```bash
scripts/drill-bootstrap.sh \
  --project-id <YOUR_PROJECT_ID> \
  --environment <ENV> \
  --dry-run \
  --non-interactive
```

Makes **zero** live changes.

### 10.4 Do not do these things

- Do **not** re-use an old project’s Firebase web config for a new project.  
- Do **not** commit `bootstrap-output-*.md` (contains passwords).  
- Do **not** commit `.drill-bootstrap-state-*.env` or
  `.drill-firebase-web-config-*.json`.  
- Do **not** paste admin passwords into Slack/email.  
- Do **not** delete the certificate CNAME after go-live.  

---

## 11. End-to-end checklist (print and tick)

Copy this list and tick as you go.

**Prepare**

- [ ] Access confirmed (GCP org, billing, Firebase, Namecheap, Resend key)  
- [ ] Tools installed (`gcloud`, `terraform`, `firebase`, `pnpm`, `uv`, `jq`)  
- [ ] Project ID + environment type chosen and written down  
- [ ] Repo cloned / updated; `git status` clean  

**Preflight**

- [ ] `gcloud auth login`  
- [ ] `gcloud auth application-default login`  
- [ ] `ADC OK`  
- [ ] `firebase login` / `firebase projects:list` works  
- [ ] Dry-run completed successfully  

**Automated install**

- [ ] `drill-bootstrap.sh … --yes` finished with `DONE`  
- [ ] Manifest file exists  

**Secrets**

- [ ] Admin email + temp password saved in password manager  
- [ ] Manifest file deleted  

**DNS**

- [ ] A record for public host → LB IP  
- [ ] A record for admin host → LB IP  
- [ ] CNAME for certificate (permanent)  
- [ ] `dig +short <public-host>` returns LB IP  

**Verify**

- [ ] Certificate ACTIVE  
- [ ] `curl -sf https://<public-host>/health` → `{"status":"ok"}`  
- [ ] Private browser login works with seeded admin  
- [ ] `scripts/tf.sh` change committed (if the script edited it)  

**Environment is UP** when the four **Verify** boxes are ticked.

---

## 12. Worked example (dev)

Illustrative only — use **your** IDs.

```bash
# Prep
cd ~/code/slot-sense
git checkout main && git pull
git status   # must be clean for Phase 4

# Logins
gcloud auth login
gcloud auth application-default login
gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"
firebase login --reauth

# Rehearsal
scripts/drill-bootstrap.sh \
  --project-id slot-sense-dev-04 \
  --environment dev \
  --dry-run \
  --non-interactive

# Real run (~45–60+ minutes)
time scripts/drill-bootstrap.sh \
  --project-id slot-sense-dev-04 \
  --environment dev \
  --yes

# After success: save password from bootstrap-output-*.md, then delete it

# DNS at Namecheap: A for rvrg-dev + admin-dev, CNAME for ACME
dig +short rvrg-dev.slotsense.chandraailabs.com A

# Health
curl -sf https://rvrg-dev.slotsense.chandraailabs.com/health && echo

# Browser: https://rvrg-dev.slotsense.chandraailabs.com  (private window)
```

---

## 13. Optional later work (not required for “up”)

These are **not** required for first login and health OK:

| Item | Why optional |
|---|---|
| Wire GitHub Actions `deploy.yml` to the new project | CI deploys still target the previous project until someone updates the workflow |
| SMS alert channel in Google Monitoring | New envs are email-only by default |
| Populate real tenant data / facilities | Fresh env starts empty except platform admin |
| Retire an old project (e.g. `sport-slot-dev`) | Separate, careful cutover — see backlog `SPORT-SLOT-DEV-RETIRE` |

---

## 14. Who to ask when stuck

1. Re-read the error line and [Section 10](#10-troubleshooting).  
2. Check `docs/runbooks/provision-environment.md` for short command fixes.  
3. For design-level questions (RTO, backup layers), read
   `docs/runbooks/disaster-recovery.md`.  
4. Escalate to the Coordinator with: project ID, phase number, full error
   text, and whether dry-run succeeded.

---

## Document control

| | |
|---|---|
| **Status** | Living operator procedure |
| **Script** | `scripts/drill-bootstrap.sh` |
| **Last aligned with** | PR-L single-touch multi-env bootstrap (Firebase web app + frontend wiring) |
| **Success definition** | Public host `/health` returns ok **and** platform admin can sign in on that host with the seeded (or rotated) password |
