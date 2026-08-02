# ADR-0039: Accepted Production-Hardening Residuals

- **Status:** Accepted
- **Date:** 2026-07-16
- **Phase:** 17 — Production Readiness / DOC-TRUTH
- **Related:** Security charter; PROJECT_REVIEW 2026-07-15 (P1.1–
  P1.4); ADR-0005 (cost ceilings); docs/backlog.md

## Context
The 2026-07-15 project review lists CMEK, VPC + Cloud NAT for
Cloud Run, MFA for admin roles, and formal penetration testing as
open production-maturity items. The system is a dev-stage,
pre-revenue portfolio SaaS under explicit cost ceilings
(₹5K/mo dev), with no resident-facing production deployment and
no real tenant data beyond test tenants.

## Decision
These four controls are DEFERRED as accepted residual risk — a
deliberate, dated decision rather than unfinished work:
1. **CMEK** (Firestore/GCS/Secret Manager): Google default
   encryption at rest is in force; CMEK adds key-management
   operational load and cost with no threat-model delta at this
   data sensitivity and stage.
2. **VPC-only ingress + Cloud NAT:** Cloud Run already sits behind
   the LB with internal-LB-only ingress and private-ranges egress;
   full VPC isolation is deferred with it.
3. **Admin MFA:** single-operator project today; becomes mandatory
   the moment a second human or a real tenant admin exists.
4. **Penetration test:** premature before the attack surface is
   final (voice gates, PR-5 hardening pending).

## Revisit triggers (any one re-opens this ADR)
- First paying/real tenant signed, or a production cutover date set
- Any real resident PII beyond test data enters the system
- A second human operator or tenant-admin onboards (MFA
  immediately)
- Compliance/DPDP assessment (SEC-01) demands any of the four

## Consequences
- The security charter references this ADR instead of claiming or
  silently omitting these controls.
- Backlog items P1.1–P1.4 from the review are tracked as one entry
  (HARDENING-RESIDUALS) pointing here, not four open items.
