# Multi-env DNS + certificate cutover (ADR-0046)

**Audience:** Coordinator  
**When:** Moving test (then dev) off the shared `*.slotsense` zone onto per-env bases.  
**Related:** [ADR-0046](../adr/0046-multi-env-base-domains.md), [ADR-0031](../adr/0031-load-balancer-wildcard-subdomains.md)

## Why

One `*.slotsense` A record can only target **one** LB IP. Dev and test each have
their own LB; shared-zone overrides (`admin-test` → test IP while `*.slotsense` →
dev IP) sent tenant hosts like `rvrg-test` to the **wrong** project.

## Target hostnames (test first)

| Role | Host | Points at |
|---|---|---|
| Apex | `slotsense-test.chandraailabs.com` | test LB `136.110.201.125` |
| Wildcard tenants | `*.slotsense-test.chandraailabs.com` | same |
| Platform admin | `admin.slotsense-test.chandraailabs.com` | same |
| ACME (permanent) | `_acme-challenge.slotsense-test.chandraailabs.com` | Certificate Manager CNAME target |

Tenant example: `https://rvrg.slotsense-test.chandraailabs.com` (slug = `rvrg`, not `rvrg-test`).

Later: `slotsense-dev.…` for a recreated dev; keep `slotsense.…` for prod / legacy until prod cutover.

## Order of operations (test)

### 1. Ship code

Merge ADR-0046 changes:

- Terraform: cert domains + URL map hosts from `var.base_domain`
- Frontend: `VITE_BASE_DOMAIN` for slug / redirects
- Registry: `.github/deploy-environments.json` test row → `slotsense-test.chandraailabs.com`
- CI: inject + fail-closed on `VITE_BASE_DOMAIN` at frontend build

### 2. Update Terraform vars on test project

In the test env tfvars (`slot-sense-test-01.tfvars` or equivalent):

```hcl
base_domain = "slotsense-test.chandraailabs.com"
admin_host  = "admin.slotsense-test.chandraailabs.com"
```

Apply (from repo root, with ADC for the right project):

```bash
./scripts/tf.sh test-01 plan   # or your registry key for slot-sense-test-01
./scripts/tf.sh test-01 apply
```

Expect:

- DNS authorization domain = `slotsense-test.chandraailabs.com`
- Certificate domains = apex + `*.slotsense-test.chandraailabs.com` (may go `PROVISIONING`)
- URL map hosts updated
- Uptime check host = `probe.slotsense-test.chandraailabs.com`
- Cloud Run env: `SPORTSLOT_BASE_DOMAIN` / `SPORTSLOT_ADMIN_HOST` updated (next deploy if ignore_changes on image)

### 3. Namecheap DNS (domain = `chandraailabs.com`)

After apply, fetch the exact ACME CNAME:

```bash
gcloud certificate-manager dns-authorizations describe slotsense-dns-auth \
  --project=slot-sense-test-01 \
  --format='yaml(dnsResourceRecord)'
```

| Type | Host | Value |
|---|---|---|
| A | `*.slotsense-test` | `136.110.201.125` |
| A | `slotsense-test` | `136.110.201.125` |
| A | `admin.slotsense-test` | `136.110.201.125` |
| CNAME | `_acme-challenge.slotsense-test` | *(from gcloud describe — keep forever)* |

Confirm LB IP if unsure:

```bash
gcloud compute addresses describe slotsense-lb-ip --global \
  --project=slot-sense-test-01 --format='value(address)'
```

### 4. Wait for certificate ACTIVE

```bash
gcloud certificate-manager certificates describe slotsense-wildcard-cert \
  --project=slot-sense-test-01 \
  --format='yaml(managed.status,managed.domainStatus)'
```

Do not proceed to user-facing cutover while status is `PROVISIONING` without SSL working.

### 5. Redeploy test frontend + backend

Promote the ADR-0046 commit to test (workflow_dispatch → `slot-sense-test-01`):

- Frontend must embed `VITE_BASE_DOMAIN=slotsense-test.chandraailabs.com`
- Backend must have `SPORTSLOT_BASE_DOMAIN` / `SPORTSLOT_ADMIN_HOST` matching

If Cloud Run image was not re-pushed, re-run deploy so env vars from Terraform/script match.

### 6. Verify

```bash
dig +short admin.slotsense-test.chandraailabs.com
dig +short rvrg.slotsense-test.chandraailabs.com
# both → 136.110.201.125

curl -sf https://admin.slotsense-test.chandraailabs.com/health
curl -sf https://rvrg.slotsense-test.chandraailabs.com/health
# {"status":"ok"}
```

Browser:

1. Open `https://admin.slotsense-test.chandraailabs.com` — platform admin sign-in (test Firebase).
2. Open `https://rvrg.slotsense-test.chandraailabs.com` — tenant slug `rvrg` (recreate tenant if old Pattern-B seed used `rvrg-test` as slug).
3. Confirm no redirect to `*.slotsense` (prod/dev zone).

### 7. Retire Pattern-B names (after test stable)

Optional cleanup under the **old** zone (do not break legacy dev yet if still using it):

- Remove `admin-test.slotsense` A when operators no longer use that bookmark
- Remove any explicit `rvrg-test.slotsense` A if present
- Leave `*.slotsense` → dev LB until dev is recreated on `slotsense-dev` or prod owns that zone

## Dev cleanup (after test works)

1. Recreate or re-bootstrap dev with  
   `base_domain=slotsense-dev.chandraailabs.com`  
   `admin_host=admin.slotsense-dev.chandraailabs.com`
2. Namecheap: `*.slotsense-dev`, `slotsense-dev`, `admin.slotsense-dev`, ACME CNAME
3. Point apps at `https://{slug}.slotsense-dev.chandraailabs.com`
4. Then decide who owns legacy `*.slotsense` (prod or temporary dev)

## Failure modes

| Symptom | Likely cause |
|---|---|
| Cert stuck PROVISIONING | ACME CNAME wrong/missing; multi-perspective DNS lag |
| Wrong Firebase / “check credentials” | SPA still built with old Firebase or wrong zone still hits old LB |
| Host/claim redirect to wrong zone | `VITE_BASE_DOMAIN` not set at build |
| dig shows old IP | TTL / wrong host name (still using `rvrg-test.slotsense`) |

## Checklist (copy/paste)

- [ ] Code merged (TF + frontend + registry + CI)
- [ ] test tfvars `base_domain` / `admin_host` updated
- [ ] `tf apply` on test
- [ ] Namecheap A + ACME for `slotsense-test`
- [ ] Cert ACTIVE
- [ ] Deploy test (frontend embeds new base domain)
- [ ] dig + health + login on admin + one tenant
- [ ] (Later) recreate dev on `slotsense-dev`
