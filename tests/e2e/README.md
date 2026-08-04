# Browser E2E (Playwright) — S-FUNC UI layer

Minimal browser journeys against a **deployed** tenant host.

## Setup

```bash
cd tests/e2e
pnpm install
pnpm exec playwright install chromium
```

## Run

```bash
export E2E_BASE_URL=https://marina-skies.slotsense-test.chandraailabs.com
export E2E_EMAIL=...
export E2E_PASSWORD=...
pnpm test
```

Or reuse functional env:

```bash
set -a && source ../functional/.env.local && set +a
export E2E_BASE_URL=https://${FUNC_TENANT_SLUG}.${FUNC_BASE_DOMAIN}
export E2E_EMAIL=$FUNC_RESIDENT_EMAIL
export E2E_PASSWORD=$FUNC_RESIDENT_PASSWORD
pnpm test
```

## Coverage

| Spec | Journey |
|---|---|
| `signin-availability.spec.ts` | Sign-in → facilities home → open facility availability |

API-level S-FUNC remains in `tests/functional/` (preferred for CI promote).
