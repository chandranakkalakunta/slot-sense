# Design: Same-SHA backend image promote (dev → test → prod)

**Status:** Proposed implementation (pairs with ADR-0045 R2 / D3)  
**Date:** 2026-08-03  
**Scope:** GitHub Actions `deploy.yml` + Artifact Registry cross-project copy  
**Non-goals:** Shared multi-project AR factory; frontend artifact promote (SPA is env-config baked)

## Problem

Today every promote target runs `scripts/build_push.sh` in the **target** GCP
project. That rebuilds the API image from the same git SHA into a different
Artifact Registry. It is:

- Slow (Cloud Build every promote)
- Not the same **digest** as what ran on dev (drift risk if build tools change)
- Contradicts ADR-0045 “same immutable artifact promotes upward”

Frontend rebuild per env remains correct (`VITE_FIREBASE_*`, `VITE_BASE_DOMAIN`).

## Decision

| Stage | API image | Frontend |
|---|---|---|
| **Build / deploy standing dev** (`push` main → `sport-slot-dev`) | **Build once** into that project’s AR; tag = short git SHA | Build with **dev** Vite env |
| **Promote** (workflow_dispatch → test/prod) | **Copy** image from `promote_from` env AR → target AR (same tag); **no rebuild** | **Rebuild** with target Vite env |
| Config / secrets | Always target-project (Cloud Run env, Secret Manager) | n/a |

Registry field (`.github/deploy-environments.json`):

```json
"promote_from": null | "<env_key>"
```

- `null` / omitted → **build** path (dev, or a cold standalone env).
- `"sport-slot-dev"` → **promote** path: copy from that env’s `project_id` + `artifact_repo`.

## Image identity

- Tag: `git rev-parse --short <git_sha>` (same as `build_push.sh`).
- Image name: `sport-slot-api` (matches `deploy_cloud_run.sh`).
- Full URI:

  ```text
  {region}-docker.pkg.dev/{project}/{artifact_repo}/sport-slot-api:{short_sha}
  ```

- Copy preserves layers; destination tag points at the **same content** as source
  (verify with `gcloud artifacts docker images describe` digests when debugging).

## IAM (required once per source → target pair)

Promote CI authenticates as the **target** project’s WIF principal
(`principalSet` for this repo on the target pool). That principal already has
`roles/artifactregistry.writer` on the **target** project.

It also needs **read** on the **source** Artifact Registry repository:

```hcl
# On the SOURCE project (e.g. sport-slot-dev) — Terraform
variable "artifact_registry_reader_members" { type = list(string) default = [] }

resource "google_artifact_registry_repository_iam_member" "external_readers" {
  for_each   = toset(var.artifact_registry_reader_members)
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.sport_slot_repo.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
```

Member value for a target env (example test):

```text
principalSet://iam.googleapis.com/projects/543027201830/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/chandranakkalakunta/slot-sense
```

(`project_number` from the **target** row in `deploy-environments.json`.)

Coordinator applies this on **standing dev** after test exists (or after recreate).

## Workflow shape

```text
resolve (env_key, git_sha, promote_from → source project/repo)
  → gates (same as today; defense in depth)
  → deploy:
       if promote_from set:
         promote_image.sh  (copy SRC → DEST, write .last_image_tag)
       else:
         build_push.sh
       deploy_cloud_run.sh <tag>
       rebuild frontend with target VITE_*
       hosting + GCS
  → smoke
```

**Fail closed:** if promote path cannot find the source image, **do not** silently
rebuild. Error must say “deploy this SHA to promote_from first.”

## Operator procedure (after test recreate)

1. Merge ADR-0046 + this promote change.  
2. On **dev** tfvars: set `artifact_registry_reader_members` to test’s principalSet; `tf apply` on dev.  
3. Ensure the candidate SHA is **already on main** and has been deployed to
   **sport-slot-dev** (image exists under short SHA).  
4. Actions → Deploy → `slot-sense-test-01` + `git_sha`.  
5. Confirm logs show `promote_image` / copy, not Cloud Build for the API.  
6. Frontend still builds in the job (expected).

## Alternatives rejected

| Option | Why not |
|---|---|
| Shared AR project for all envs | Cleaner long-term; more org IAM + bootstrap change than needed now |
| Rebuild but pin by SBOM | Still not same digest; slower |
| Promote frontend dist as tarball | Breaks env-specific Vite inject; rebuild is correct |
| Silent rebuild fallback on missing image | Hides broken promote path |

## Implementation checklist

- [x] Design doc (this file)  
- [x] `scripts/promote_image.sh`  
- [x] Registry `promote_from` + resolve outputs  
- [x] `deploy.yml` branch build vs promote  
- [x] Terraform `artifact_registry_reader_members` on source AR  
- [x] TEST-STRATEGY / CHANGELOG update  
- [ ] Coordinator: apply reader IAM on dev after test project number known  
- [ ] First green promote after test recreate  

## References

- [ADR-0045](../adr/0045-test-strategy-and-environment-promotion.md)  
- [ADR-0046](../adr/0046-multi-env-base-domains.md)  
- [TEST-STRATEGY.md](../testing/TEST-STRATEGY.md) §5  
