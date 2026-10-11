# LimitFuel release preparation

User authorized editing PR #1 for signing/notarization preparation on 2026-10-11,
with no secrets committed. No upload, notarization run, installation, publication,
App Store record or submission is authorized by this preparation step.
Runtime Plan mode cannot be switched in this client; this is the equivalent plan.

## Acceptance

- R1: Preserve local universal ad-hoc builds. Signed builds use configurable
  DEVELOPER_ID, defaulting to Developer ID Application: Innolope LLC (MQD26CY5MA),
  hardened runtime and timestamp. Build/packaging never launch an app.
- R2: Package only a strictly verified, hardened, matching-team app with clean
  build provenance. Sign compressed DMG, submit using Keychain NOTARY_PROFILE
  (default LimitFuel), require JSON status Accepted, staple/validate and pass
  Gatekeeper before publishing output.
- R3: Failures exit nonzero. Publish a final release directory only after every
  check succeeds; never overwrite releases. Clean temporary files and exclude
  concurrent builds/packaging with a shared atomic lock.
- R4: Keep credentials in Keychain, never in scripts/PR. Ignore local environment,
  signing material and generated output; track reviewable executable logic.
- R5: Record source commit, version/build, submission ID and DMG SHA-256. Timeout
  means unknown Apple outcome; no automatic resubmission. Document recovery.
- R6: Document direct distribution versus App Store requirements and remaining
  sandbox compatibility work. Do not claim App Store readiness.

## What can go wrong

| Category | Trigger | Invariant and proposed test |
|---|---|---|
| Invalid input | Empty/control-bearing identity/profile, invalid timeout/version, missing app/provenance | Fail before submission/final output; disposable fixtures |
| Concurrency | Simultaneous build/package | Atomic shared app/.release-lock; loser cannot remove owner lock |
| Idempotency | Repeat completed release | Refuse existing version-build directory without modifying it |
| Timeouts | Pending Apple result, hung command | Finite deadlines, child cleanup, nonzero exit and unknown-outcome message |
| Retries | Auth, rejection, transient outage | No automatic submission retry; operator recovery |
| Partial failure | Sign, submit, staple, verification fails | No ready artifact; prior releases intact; staging removed |
| Auth | Wrong team, ad-hoc app, missing certificate/profile | Matching team, hardened runtime, strict signature; Keychain-only auth |
| Data limits | Large/malformed result or unsafe version path | At most 1MiB parsed output; bounded safe version/build components |
| Migration | Existing local build and bundle ID | Preserve --local and bundle ID; replace fail-open packaging |

Technical defaults presented in chat before production edits. Innolope signing
certificate was verified; user requested release preparation. Dual menu bar display
was accepted in chat: show monochrome Claude/OpenAI marks with separate percentages,
hide missing providers, and keep the popup reachable when neither has usage.
Presentation uses immutable snapshots; malformed/nonfinite/out-of-range values are
hidden rather than fabricated as zero. No polling/auth changes. Test both/single/
neither, boundaries and loss/recovery sequences; visually inspect light/dark output.

## Verification and rollback

Use a fresh spec-only author with a different available model, no inherited history;
filesystem isolation is instructed, not enforced. Freeze tests before implementation.
Use fake external boundaries, deterministic failure/concurrency fixtures and an
Accepted-guard mutation in a disposable copy. Live load testing is inapplicable to
a manual single-artifact pipeline. Run full tests/lint, local universal build,
separate finder/verifier, mandatory commit hook and exact-head hosted CI. Reverting
scripts/docs rolls back this preparation; no remote release state is changed.

## Observed failures and corrections

- Finder reproduced a hung signing child retaining the build lock after TERM.
  Add explicit build-command deadlines and interrupt forwarding via a bounded
  process-group runner; verify timeout and descendant cleanup independently.
- Spec-only fixtures initially conflated full preflight startup with the notary
  deadline and assumed a child stub must execute before a 1-second timeout. Native
  child startup can exceed that budget. Correct the fixture oracle with standard
  Python subprocess audit events: measure the launch boundary and count attempts
  even when the child is killed before executing. Preserve deadline/no-retry checks.
- Case-insensitive macOS paths made scripts/Scripts fixture copies collide; copy
  the confirmed scripts directory once. None of these corrections relax product
  behavior or use actual Apple credentials.
- A retained commit-hook transcript exposed incompatible cross-process clock
  references between macOS Python 3.9 and 3.14. The test author replaced the two
  timestamp reads with POSIX CLOCK_MONOTONIC; an independent verifier confirmed
  the unchanged deadline, attempt count and cleanup assertions and passed the
  isolated timeout check with both runtimes, including Python 3.9 subprocesses.
