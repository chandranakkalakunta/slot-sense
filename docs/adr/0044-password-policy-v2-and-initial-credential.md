# ADR-0044: Password Policy v2 & 6-Digit Initial Credential

- **Status:** Proposed (awaiting Coordinator approval)
- **Date:** 2026-07-26
- **Deciders:** Coordinator (Chandra), Strategist
- **Phase:** post-17 (product/UX + security)
- **Supersedes:** ADR-0020 §2 (length rule) — the rest of ADR-0020 (reset
  flow, zxcvbn, HIBP, enumeration protection, session safety, audit) stands.
- **Extends / amends:** ADR-0014 §3–§4 (generate-and-force-change credential
  model).
- **Relates to:** ADR-0007 (auth & authorization), ADR-0016 (user
  provisioning), ADR-0011 (audit logging).

---

## Context

Two usability complaints against the current auth UX, both accepted as real:

1. **Minimum length of 12 is high-friction.** ADR-0020 §2 set min length 12,
   alongside a `zxcvbn ≥ 3` strength gate and an HIBP breach check, enforced
   server-side in `sport_slot/auth/password_policy.py` and wired into
   `/me/change-password` and the reset-confirm path. Consumer banking apps
   commonly use an 8-char minimum; the Coordinator wants parity.

2. **The generated initial password is a ~22-char random string**
   (`secrets.token_urlsafe(16)`), used by every creation path — resident
   provisioning (`provisioning.py` reset/create) and `seed_platform_admin.py`.
   It is emailed/handed to the user once, with `must_change_password=true`
   forcing a change on first login (ADR-0014 §3–§4). A long opaque string is
   hard to relay (read aloud, SMS, retype) and remember for the ~one time it
   is used.

Key architectural constraint carried into this decision: **authentication is
client-direct to Firebase.** The frontend authenticates against Firebase and
obtains an ID token; the backend only ever sees the *already-issued* token. The
backend therefore does **not** observe the password or failed sign-in attempts,
which shapes what "lockout" can mean here (see D7).

Machine-generated temporary passwords are **exempt** from the ADR-0020
validator (they are high-entropy and not user-chosen). Moving them to 6 digits
removes that entropy, so the exemption now requires compensating controls
(D5–D7) to remain safe.

---

## Decision

### D1 — Length floor 12 → 8, uniform across all roles
The minimum length in `password_policy.py` drops from 12 to 8, applied
identically to residents, tenant admins, and platform admins. Max length
(≥64), full-Unicode acceptance, and the no-forced-composition-rules stance
(NIST SP 800-63B) are unchanged.

### D2 — Strength gate and breach check unchanged
`zxcvbn ≥ 3` and the HIBP k-anonymity breach check remain in force. The floor
lowers the *length* bar, not the *strength* bar: an 8-char password must still
score ≥ 3 and not appear in a breach corpus. This is the primary defense that
keeps an 8-char minimum acceptable in the absence of MFA (admin MFA remains a
deferred residual, ADR-0039). Consequence made explicit: trivially weak 8-char
passwords (e.g. `password1`) are still rejected — "8 characters" does not mean
"any 8 characters."

### D3 — Client length gate 12 → 8
The frontend instant-feedback length check (ADR-0020 Amendment 2) and the
forced-change screen gate move from `< 12` to `< 8`. The server validator
remains the sole authority; the client check is UX only. The client/server
length-parity contract test is updated to 8.

### D4 — Initial credential becomes a 6-digit numeric code
Every creation/reset path generates a 6-digit numeric code (`000000`–`999999`,
cryptographically random via `secrets`) instead of `token_urlsafe(16)`:
`provisioning.py` (resident/tenant-admin/CSV paths, single
`UserProvisioningService`) and `seed_platform_admin.py`. Returned once to the
creator, `must_change_password=true` set as today. The code remains exempt from
the D1–D2 user-password validator (machine-generated), now guarded by D5–D7.

### D5 — Short expiry (TTL)
The profile records `temp_password_expires_at` (default **24h**, config-driven).
The forced-change gate checks it; past expiry, the change is refused with a
clear "code expired — ask an admin to re-issue" message, and the account is
disabled (`fb_auth.update_user(disabled=True)`) pending re-issue. A short TTL
is the main bound on the brute-force window a 6-digit code opens.

### D6 — Single-use via forced change
`must_change_password=true` continues to block all other navigation/actions
until the code is changed to a compliant (D1–D2) password on first login. The
code is never reusable after the change.

### D7 — Abuse resistance without backend-mediated login
Given client-direct Firebase auth, a hard N-strikes account lockout would
require rerouting sign-in through the backend or Identity Platform blocking
functions — rejected as out of proportion here (see Alternatives). Instead the
low-entropy window is bounded by: (a) the short TTL (D5), (b) Firebase Identity
Platform's built-in sign-in throttling, and (c) **App Check / reCAPTCHA
enforcement on the auth path** so automated guessing is attested against.

### D8 — Re-issue and audit
Admin re-issue (existing reset paths) generates a fresh 6-digit code + new
`temp_password_expires_at`, re-enables a disabled account, and audits a distinct
event. Existing ADR-0011 audit events for password changes are retained.

---

## Consequences

**Positive**
- Lower-friction sign-up/change (8-char floor) and a memorable, easy-to-relay
  initial code, meeting both usability complaints.
- No new billable resources beyond App Check (free tier ample at this scale).
- The strength gate + breach check keep the real security bar high despite the
  shorter floor.

**Trade-offs / negative**
- An 8-char floor with no MFA is a weaker posture than 12; mitigated by keeping
  zxcvbn + HIBP (D2). Applies uniformly, including privileged admin accounts —
  a deliberate Coordinator choice.
- A 6-digit code is ~20 bits of entropy. Even with D5–D7, an attacker who
  guesses the code within the TTL window (and passes App Check) could complete
  the forced change and take over before the legitimate user's first login.
  This residual is **accepted** and bounded by the short TTL; it is the reason
  App Check enforcement is a hard prerequisite for any resident-facing prod
  rollout (see Follow-ups).
- Expiry is enforced at the forced-change gate + account-disable, not by
  Firebase itself (Firebase has no native temp-password expiry) — a small
  amount of app-owned state and logic.

**Impact scope (from ADR-0020's own note):** the length change affects only
*future* password changes, never existing stored passwords.

---

## Alternatives considered

- **Relax the strength gate (zxcvbn ≥ 2, or length-only):** rejected. With a
  shared 8-char floor and no MFA, the strength/breach checks are the main
  defense; dropping them to make "any 8 chars" acceptable trades too much
  security for marginal UX.
- **Hard N-strikes lockout via backend-mediated login / Identity Platform
  blocking functions:** rejected for now. Materially reworks the client-direct
  auth architecture (ADR-0007) for a threat the short-TTL + App Check posture
  already bounds. Revisit if abuse is observed or at the prod hardening gate.
- **Keep min length 12:** rejected — does not address the stated friction.
- **Keep the long random temp string:** rejected — the relay/remember friction
  is the specific complaint; forced-change + short TTL make a memorable code
  acceptable.

---

## Security charter alignment

- **Secure by Default** — strength gate and breach check preserved; temp codes
  are single-use, short-lived, and App-Check-attested.
- **Fail Closed** — expired temp codes disable the account rather than silently
  continuing to accept a stale credential.
- **Named residual** — the 6-digit brute-force window is explicitly accepted,
  bounded by TTL, and gated behind App Check for prod (Follow-ups), not left
  as a silent weakening.

---

## Follow-ups (backlog)

1. **APPCHECK-AUTH-GATE (prod launch gate):** App Check / reCAPTCHA enforcement
   on the auth path must be live before the 6-digit initial credential reaches
   a resident-facing prod/test environment. Until then, the short TTL + Firebase
   throttling are the only bounds.
2. **TEMP-CRED-SWEEP (low):** optional scheduled sweep disabling accounts whose
   `temp_password_expires_at` has passed without a first login, complementing
   the on-detection disable in D5.
