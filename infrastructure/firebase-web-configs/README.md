# Firebase web app configs (public client IDs)

These are **public** SPA identifiers (same class as `frontend/.env.production`),
not secrets. Committed so CI can build the frontend for each GCP project
without console scraping.

| File | Project |
|---|---|
| `sport-slot-dev.json` | Legacy standing dev |
| `slot-sense-test-01.json` | Test environment |

When bootstrap creates a new env, copy the Phase-2 SDK config here as
`<project_id>.json` and add a row to `.github/deploy-environments.json`.
