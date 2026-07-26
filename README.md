# SlotSense

Multi-tenant SaaS for Indian residential community sports facility
booking, with an AI booking assistant residents talk to in natural
language. Built by [Chandra AI Labs](https://chandraailabs.com) as a
production-grade reference implementation: every architectural decision
documented, every phase independently validated.

The repo name remains `sport-slot-reservation` (URL stability); the
product was renamed to SlotSense during Phase 9.

**Status:** Phase 10 complete — portfolio-quality UI with Tailwind v4/shadcn
design system, PWA installability, dark mode, and verified accessibility
layered on top of the Phase 9 AI agent. Phase 8 (production hardening: CMEK,
VPC, MFA, pen testing) remains deferred.

## What this is

In Indian residential communities, booking shared sports facilities —
tennis courts, badminton courts, the cricket nets — is usually handled
through WhatsApp groups, paper rosters, or third-party operators who
take 50–75% of booking revenue. SlotSense is a multi-tenant platform
that lets communities run their own bookings, keeping the revenue and
giving residents a real product.

The differentiator is the AI agent. Residents can say "book my usual
tennis slot tomorrow" instead of navigating a calendar grid; the agent
proposes a structured booking with a confirm-or-cancel card, and only
executes when the resident explicitly confirms. The propose-confirm-execute
gate (see [`docs/adr/0023`](docs/adr/0023-propose-confirm-execute-gate.md))
means the LLM never directly mutates state — every action goes through
a structured pending action with TTL semantics in Redis.

For the full portfolio writeup of the architectural decisions and the
vendor-fee value proposition, see
[`docs/SLOTSENSE_ARTICLE.md`](docs/SLOTSENSE_ARTICLE.md).

## Capabilities

- **Multi-tenant by construction** — five-layer tenant isolation
  (deny-all Firestore rules, repository pattern requiring
  `TenantContext`, JWT-vs-subdomain cross-check middleware, automated
  cross-tenant tests, CI static-analysis gates)
- **AI booking assistant** — Vertex AI Gemini 1.5 Pro with function
  calling over 5 tools; propose-confirm-execute gate for all mutations;
  output classifier for hallucination detection; Python-side guards
  for temporal reasoning, quota arithmetic, and disambiguation
- **Per-tenant branding** — subdomain-based; each tenant's logo,
  colors, and name applied via CSS variables at runtime; tenant brand
  is the primary identity in the header; "powered by SlotSense" footer
  attribution is the platform's secondary presence (ADR-0029)
- **Portfolio-quality UI** — Tailwind v4 + shadcn/ui (Radix primitives)
  design system; Inter typeface; light/dark mode; responsive across
  mobile, tablet, and desktop; 238 frontend tests across 37 test files
- **PWA installable** — real app icons, correct Workbox cache strategy
  (`no-cache` on HTML/manifest/SW; immutable long-cache on hashed
  assets); install prompt on iOS, Android, and desktop
- **Verified accessibility** — 28 automated axe-core scans (14 pages ×
  2 modes) with zero serious/critical violations; keyboard navigation
  and ConfirmDialog focus-trap confirmed; slot states are not
  color-only (Radix + text labels)
- **Production engineering posture** — 91%+ backend test coverage,
  branch-protected `main`, Workload Identity Federation for
  deployments (zero JSON keys), structured JSON logging, ADRs
  before code

## Architecture

The request flow with the AI agent path (Phase 9) added to the
original multi-tenant backend:

```mermaid
flowchart LR
  C[Client / PWA] -->|HTTPS + Firebase JWT| E[Cloud Run edge]
  E --> M1[RequestId + RateLimit MW]
  M1 --> A[Auth dependency<br/>JWT verify + tenant cross-check]
  A --> R{Route}
  R -->|Standard API| S[Service layer]
  R -->|/agent/query| AG[Agent orchestrator]
  AG --> V[Vertex AI<br/>Gemini 1.5 Pro<br/>tool calls + output guard]
  AG --> RD[(Memorystore<br/>pending actions<br/>5-min TTL)]
  AG --> S
  S --> RP[Repository layer<br/>tenant-scoped]
  RP --> F[(Firestore<br/>/tenants/id/...)]
  S --> CT[Cloud Tasks<br/>notification worker]
  CT --> RS[Resend<br/>email]
  subgraph GCP [sport-slot-dev · asia-south1]
    E; M1; A; R; S; AG; V; RD; RP; F; CT
  end
```

**Tenant isolation (ADR-0004), five layers:** deny-all Firestore
rules · repository pattern requiring `TenantContext` at construction ·
JWT-vs-subdomain cross-check middleware · automated cross-tenant
tests · CI static-analysis gates.

**Agent safety architecture (ADRs 0021–0027):** the LLM extracts
intent and proposes actions; deterministic Python validates and
corrects edge cases; a Redis-backed pending action store with 5-min
TTL holds proposals between propose and confirm; an output
classifier validates that entity references in the natural-language
reply exist for the current tenant, failing closed.

## Quickstart (local)

```bash
make install && make verify-env   # toolchain check (13 tools)
make dev-env                      # creates backend/.env from template
# → fill SPORTSLOT_WEB_API_KEY (Firebase Console → Project settings)
make seed-dev                     # demo Firebase user + profile (dev only)
make run-dev                      # uvicorn on :8000
TOKEN=$(./scripts/get_dev_token.sh demo-resident@chandraailabs.com '<password>')
curl -H "Authorization: Bearer $TOKEN" localhost:8000/api/v1/users/me
```

The full agent path requires a configured GCP project with Vertex AI
access, Memorystore Redis, and Cloud Tasks. Local development typically
runs the backend without the agent (the non-agent API surface works
independently).

See `docs/runbooks/local-development.md` for the full loop, frontend
setup, and known issues.

## Key documents

- [`docs/runbooks/create-environment-step-by-step.md`](docs/runbooks/create-environment-step-by-step.md)
  — **create a full GCP environment** (dev/test/prod): plain-English
  steps for the automated installer + DNS + first admin login
- [`docs/runbooks/provision-environment.md`](docs/runbooks/provision-environment.md)
  — one-page command card for the same procedure
- [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) — canonical project
  scope, reconciled to actual state through Phase 9
- [`docs/SLOTSENSE_ARTICLE.md`](docs/SLOTSENSE_ARTICLE.md) — the
  portfolio article: architectural decisions, vendor-fee economics,
  what I'd reconsider with hindsight
- [`docs/adr/`](docs/adr/) — 29 Architecture Decision Records covering
  stack, data, tenant isolation, cost, API design, auth, booking
  domain, slot locking, audit, frontend, error presentation, admin
  identity, facility catalog, user provisioning, deletion lifecycle,
  CI/CD security, notification architecture, password policy, the
  seven Phase 9 ADRs documenting the AI agent's safety architecture,
  and two Phase 10 ADRs (design system + co-branding hierarchy)
- [`docs/retrospectives/`](docs/retrospectives/) — phase closure
  narratives. Phase 2 through 5 documented previously; Phase 9
  and Phase 10 added during their respective closure ceremonies.
  Phases 6, 7, and 8 (deferred) are intentionally undocumented as
  retrospectives — see the Phase 9 retrospective's "honest reflections"
  section for why
- [`docs/security/charter.md`](docs/security/charter.md) — principles,
  threat model, phased controls, DPDP compliance, identity and
  credential model
- [`CHANGELOG.md`](CHANGELOG.md) — slice-level history with
  per-PR detail; the canonical record of what shipped when

## Stack

**Backend:** Python 3.12 · FastAPI · uv · structlog ·
zoneinfo (per-tenant timezones) · pytest with hermetic Firestore mocks

**Frontend:** React 18 · Vite 6 · TypeScript · pnpm · React Query 5 ·
react-router-dom 7 · Tailwind v4 · shadcn/ui (Radix primitives) ·
lucide-react · Inter · PWA (Workbox)

**Data:** Firestore (Native Mode) · Memorystore Redis (distributed
locks + pending actions) · BigQuery (federation for cross-country
reporting; future)

**AI:** Vertex AI Gemini 1.5 Pro (function calling + output
classifier)

**Infrastructure:** Cloud Run · Cloud Build · Artifact Registry ·
Cloud Tasks (notification dispatch) · Firebase Auth · Firebase Hosting
(via Hosting REST API) · Terraform · GitHub Actions with Workload
Identity Federation

**External services:** Resend (transactional email, verified domain
`mail.chandraailabs.com`)

## Project status

| Phase | Scope | Status |
|-------|-------|--------|
| 0 | Foundation ADRs (0001–0020) | ✓ Complete |
| 1 | Workspace bootstrap | ✓ Complete |
| 2 | Backend API foundation | ✓ Complete |
| 3 | Booking engine | ✓ Complete |
| 4 | Frontend foundation | ✓ Complete |
| 5 | Admin & Provisioning | ✓ Complete |
| 6 | CI/CD + WIF + branch protection | ✓ Complete |
| 7 | Notifications (7.1) + Auth/password reset (7.2) | ◐ Partial (7.3–7.6 deferred) |
| 8b | Production networking (LB, wildcard TLS, Cloud Armor, ingress) | ✓ Complete |
| 9 | AI Booking Agent (SlotSense) | ✓ Complete |
| 10 | UI redesign + PWA + accessibility audit | ✓ Complete |
| 13 | Entity lifecycle management (delete/deactivate, DPDP erasure) | ✓ Complete |
| 15 | Billing & invoicing | ✓ Complete |
| 16 | Voice I/O for the AI Booking Assistant | ✓ Complete |
| 17 | Production Readiness (backup/DR, Terraform rebuild path, doc/CI truth, observability) | In progress: PR-1a ✓, PR-1b ✓, DOC-TRUTH ✓, PR-2 (this PR, pending apply), PR-3..5 open |

Phase 8b (production networking) shipped the GCP load balancer stack
replacing Firebase Hosting's implicit infrastructure. Row 5's original
"Binary Auth + supply-chain security" scope never shipped in that slot
— it's the deferred hardening work now underway as Phase 17 (see
ADR-0039). Phases 12 and 14 are gaps in this table, not typos — see
[`docs/adr/README.md`](docs/adr/README.md) for the ADR-indexed phase
mapping, which is more current and granular than this table (status
corrected 2026-07-16, DOC-TRUTH). `docs/backlog.md` is the canonical
tracked-work record; this table is a coarse overview only.

Phase retrospectives document the build process, lessons learned, and
process improvements adopted:

- [`docs/retrospectives/phase-8b.md`](docs/retrospectives/phase-8b.md) — production networking: LB, wildcard TLS, Cloud Armor, ingress restriction, 7 issues caught
- [`docs/retrospectives/phase-9.md`](docs/retrospectives/phase-9.md) — the 16-slice AI agent build and its seven live-testing rounds
- [`docs/retrospectives/phase-10.md`](docs/retrospectives/phase-10.md) — the UI redesign, the density saga, deploy/cache lessons, a11y audit

## Engineering method

Three-agent protocol: a Strategist (Claude) designs and writes
execution prompts, a Worker (Claude Code) executes them, and a
human Coordinator approves designs, runs credentialed operations,
and validates every slice independently in a fresh terminal.
Discussion-first; ADRs before code; no unverified completion claims.

The protocol itself (the operational playbook, the named failure
patterns, the recovery flows) is maintained as a private methodology
document outside this repo. The eleven protocol-level lessons that
emerged from Phase 9 — captured in the
[Phase 9 retrospective](docs/retrospectives/phase-9.md) — feed the
next revision of that document.

## License

MIT © Chandra AI Labs
