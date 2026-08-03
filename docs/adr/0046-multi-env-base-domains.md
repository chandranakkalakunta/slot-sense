# ADR-0046: Multi-Environment Base Domains & Per-Env Wildcard Certificates

- **Status:** Accepted
- **Date:** 2026-08-03
- **Deciders:** Coordinator (Chandra)
- **Phase:** post-17 multi-env ops
- **Supersedes (host naming only):** Pattern B shared-zone convention
  (`rvrg-dev` / `rvrg-test` under one `*.slotsense` A) documented in
  DNS-PATTERN-B / bootstrap defaults — **not** the LB/wildcard technology
  of ADR-0031.
- **Related:** ADR-0031 (LB + Certificate Manager wildcards);
  ADR-0004 (tenant isolation via subdomain); ADR-0045 (promote per env);
  ADR-0012 (host-derived tenant slug)

## Context

Multiple GCP projects (dev / test / prod) each have their **own** global
HTTPS load balancer and static IP. Tenant isolation in the app uses the
**hostname left-label** as `tenant_slug`.

### Failed shared-zone approach

A single DNS zone `*.slotsense.chandraailabs.com` → **one** A target can
only point at **one** LB IP. Overrides like `admin-test.slotsense` hit
test while `rvrg-test.slotsense` still matched the wildcard and hit
**dev** (live 2026-08-03: `*.slotsense` → `34.54.228.224` = sport-slot-dev;
`admin-test.slotsense` → `136.110.201.125` = test). Result: tenant
sign-in on “test” URLs authenticated against the wrong Firebase project
and host/claim mismatch redirects (`rvrg-test` host vs `rvrg` claim).

Encoding env into the slug (`rvrg-test`) does not scale and still needs
per-name DNS if the wildcard points at the wrong IP.

### Requirements

- No per-tenant DNS records (wildcard A per environment only).
- No forced slug suffixes (`rvrg` valid on every env).
- Same app binary pattern: host → slug; project isolation via deploy target.
- Certificate Manager wildcards (ADR-0031) remain the TLS mechanism.

## Decision

### D1 — One base domain per environment

| Environment | `base_domain` |
|---|---|
| dev (new standing) | `slotsense-dev.chandraailabs.com` |
| test | `slotsense-test.chandraailabs.com` |
| prod | `slotsense.chandraailabs.com` |

Legacy `sport-slot-dev` may keep `slotsense.chandraailabs.com` until
retired; new envs use the table above.

### D2 — Per-env DNS (exactly three A-class patterns per env)

For each env with LB IP `L`:

| Record | Purpose |
|---|---|
| `A  *.<base_label>  → L` | All tenant hosts (and other one-label hosts) |
| `A  <base_label>  → L` | Env apex (optional admin/marketing) |
| `A  admin.<base_label>  → L` | Platform admin host (recommended) |
| `CNAME  _acme-challenge.<base_label>` | Certificate Manager DNS authorization (**permanent**) |

No A records for individual tenants (`rvrg`, `acme`, …).

Namecheap **Host** fields (domain = `chandraailabs.com`):

- `*.slotsense-test` → test LB  
- `slotsense-test` → test LB  
- `admin.slotsense-test` → test LB  
- `_acme-challenge.slotsense-test` → Google auth target  

### D3 — Per-env Certificate Manager cert

Each GCP project issues:

```text
domains = [ var.base_domain, "*.${var.base_domain}" ]
dns_authorization.domain = var.base_domain
```

No sharing of one cert or one ACME CNAME across projects.

### D4 — Platform admin and tenants

| Role | Host pattern | Example (test) |
|---|---|---|
| Platform admin | `admin.${base_domain}` | `admin.slotsense-test.chandraailabs.com` |
| Tenant | `{slug}.${base_domain}` | `rvrg.slotsense-test.chandraailabs.com` |

`tenant_slug` in Firestore/JWT is **only** the community id (e.g. `rvrg`),
identical naming allowed across envs because projects differ.

### D5 — Application configuration

- Backend: `SPORTSLOT_BASE_DOMAIN` / `SPORTSLOT_ADMIN_HOST` per env (already).
- Frontend: **`VITE_BASE_DOMAIN`** (and admin host via branding/API as needed)
  must equal that env’s `base_domain` so host↔claim checks and redirects
  stay on the correct zone (no hardcoded prod apex in multi-env builds).
- Terraform: certificate + URL map **hosts** derived from `var.base_domain`
  (no hardcoded `slotsense.chandraailabs.com` in managed resources).
- CI registry (`.github/deploy-environments.json`): `base_domain`,
  `admin_host`, `health_url` per env.

### D6 — Migration order (test first)

1. Ship code (this ADR + TF + frontend apex).  
2. Apply Terraform on **test** with new `base_domain`; create ACME + wildcard A
   records for `slotsense-test`.  
3. Wait cert ACTIVE; redeploy frontend with `VITE_BASE_DOMAIN`.  
4. Use tenants as `https://{slug}.slotsense-test.…`.  
5. Recreate/cleanup **dev** on `slotsense-dev.…` when ready.  
6. Point legacy `*.slotsense` only at **prod** when prod exists; remove
   Pattern-B hosts (`rvrg-test`, `admin-test` under old zone) after cutover.

## Consequences

### Positive

- Scalable multi-tenant DNS (one wildcard A per env).  
- Natural slug names; no env suffix convention.  
- Clear isolation: wrong zone cannot “accidentally” hit another env’s LB
  via a shared `*.slotsense` record.  
- Separate ACME CNAMEs end multi-project cert auth conflicts.

### Negative

- More DNS names and certs to manage (3 bases).  
- One-time migration of bookmarks and any seeded tenant URLs.  
- Frontend must never ship a build with the wrong `VITE_BASE_DOMAIN`.

### Risks

| Risk | Mitigation |
|---|---|
| Cert stuck PROVISIONING | ACME CNAME permanent; wait multi-perspective validation |
| Old `*.slotsense` still catches leftover Pattern-B hosts | Delete obsolete A/CNAME after cutover; dig-verify |
| Redirect to wrong zone | `VITE_BASE_DOMAIN` fail-closed in CI (same as Firebase projectId) |

## Alternatives rejected

- **Shared `*.slotsense` + per-tenant A overrides** — does not scale.  
- **Slug suffixes only (`rvrg-test`)** — still needs correct wildcard IP;
  confuses product language.  
- **Single shared LB for all envs** — breaks project isolation / DR model.

## References

- Live incident 2026-08-03: `rvrg-test` → dev LB via `*.slotsense` A.  
- [ADR-0031](0031-load-balancer-wildcard-subdomains.md)  
- [ADR-0045](0045-test-strategy-and-environment-promotion.md)  
- Operator DNS cutover: `docs/runbooks/multi-env-dns-cutover.md`
