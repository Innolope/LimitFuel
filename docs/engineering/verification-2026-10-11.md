# Verification record

Scope: Chrome session discovery/renewal, permission and donation removal, Claude
and Codex usage tracking, 60-second normal / 12-second high five-hour polling, and LimitFuel rename.

## Evidence and recovery

- Independent spec-only author: gpt-6.1-sol, fresh context containing acceptance
  and public API only. Shared filesystem and model isolation are not enforced.
- Reader: 599 assertions, including 512 deterministic cases (seed 0xC0FFEE),
  synthetic v10/v24 encryption, domain binding, expiry, header injection, limits,
  live WAL, SQLite locking, profile ambiguity and adaptive cadence boundaries.
- Lifecycle: 69 assertions with isolated defaults, mocked HTTP and blocked import.
  Covers manual migration, coalescing, stale results after clear/save, failed import
  preserving credentials, unchanged sessions and auxiliary-cookie rotation.
  Invalid responses preserve notification history while clearing adaptive state.
- Codex: 219 assertions using synthetic RPC/parser/manager tests, seed 0xC0D3 with
  128 generated cases. Native TERM-resistant fixture confirms readiness before an
  8s deadline, holds stdout 30s and verifies bounded failure/cleanup within 12s.
- Deliberate failing variant: disposable reader copy changed `>90` to `>=90`.
  The threshold assertion failed as intended; real source passed all 599 checks.
- A second disposable variant removed SQLite-component validation. The malformed
  stored-cookie assertion failed as intended, demonstrating injection protection.
- Separate finder and verifier reproduced response-relative cadence (17.531s with
  5s fetch), duplicate alerts after lower/missing usage, stale Claude adaptive
  state and a TERM-resistant descendant delaying timeout. Fixes anchor request
  starts, retain bounded threshold history, clear invalid adaptive data and use
  nonblocking pipe reads with a monotonic deadline and owned-group cleanup.
- Independent post-fix verifier passed 31 adaptive/parser/Codex checks and 9 Chrome
  recovery checks. A ready TERM-resistant child was cleaned up after a 3.028s timeout,
  before its natural 5s exit. Scheduled fire date stayed start+12s through completion.
  Four malformed Claude response forms retained notification history through recovery.
- Primary Chromium source confirmed LAContext cannot suppress legacy Keychain UI.
  Chrome reads now serialize the process-wide legacy prompt flag and restore it;
  actual Keychain prompts remain untested.
- Fixture corrections preserved assertions: threshold was seeded before manager
  initialization; temp paths are explicit; descendant readiness must be established
  before treating a timeout run as valid evidence.
- An initial quality-gate rerun failed compiling AppKit when disk space ran out.
  This was an unpassed check; only task-generated caches were removed before retry.
- A later combined gate passed reader/lifecycle checks but failed the native-fixture
  readiness precondition while host load exceeded 280. A dedicated worker handshake
  and native timestamp now separate scheduling from the child deadline without
  extending the timeout bounds. The same prebuilt Codex suite failed native readiness under the default
  macOS temporary directory, then passed from /private/tmp. The runner now uses
  that explicit writable root, retaining all assertions and deadlines. This is
  path correlation, not proof of an OS root cause; the unchanged standalone Codex suite passed 219 checks and a separate
  verifier observed readiness at 1.898s, timeout at 8.037s and process cleanup.
  Failed precondition runs are not counted as timeout-test passes. After the path
  correction and LimitFuel rename, the complete suite passed 887 assertions
  (599 reader, 69 lifecycle, 219 Codex); lint also passed. The existing personal
  commit gate is configured to rerun the complete suite and lint before publishing.
- Local universal app and offline Claude/Codex light/dark previews compiled.
  The build uses an explicit ad-hoc signature; distribution signing is separate.
  Renamed LimitFuel.app compiled for x86_64 and arm64 and passed strict signature
  verification. Bundle name/executable are LimitFuel; identifier is unchanged.
  The first renamed build could not locate the SDK with a direct toolchain PATH;
  selecting the installed macOS SDK explicitly through SDKROOT resolved it.
- Installed Codex read-only RPC probe reached Codex but returned sign-in guidance;
  its current login did not expose a ChatGPT account with plan quotas. No credentials
  or account identity were printed. No login or inference was performed.

## Limits and assumptions

- Real Chrome/Keychain interaction is untested. Tests never read actual browser
  cookies or credentials. Default Chrome only; custom data dirs/channels use manual
  fallback. Background Keychain access cannot prompt; Detect can request access.
- Existing manual cookies stay manual until explicit detection. Multiple signed-in
  profiles require selection instead of guessing. These are compatibility assumptions.
- Existing manual credentials remain in app UserDefaults; no storage migration.
- Update announcements use the fork's empty release feed until a fork release is
  published, so upstream release prompts cannot replace the fork's changes.
- Codex alerts retain at most 256 account/window threshold keys; missing windows
  and decreasing usage do not reset the current window's remembered threshold.
- Fuzzing is bounded and deterministic. HTTP/import concurrency and process failures
  use synthetic fixtures. Network load testing is skipped: a personal timer client
  has no server capacity claim. Keychain denial is injected, not a real permission test.
- No project lint or CI existed initially. Configured the existing personal commit
  hook with the full test suite and shell/metadata/whitespace checks. Runtime
  activation was observed when it rejected unconfigured commits. No hook was
  installed or trust setting changed. Hosted CI and branch protections are separate.
- No installation, merge, release, website deployment or notarization is performed.

- Rename: executable, app bundle, source/icon filenames, visible branding and
  fork repository now use LimitFuel. Bundle identifier and credential/settings
  keys remain stable. Fork update metadata is separate from upstream releases.

## Release preparation and dual menu bar (2026-10-11)

- User authorized updating the PR without secrets and explicitly chose both
  providers, then monochrome Claude/OpenAI marks and hiding missing providers.
- Release workflow uses public Innolope identity/profile names and Keychain-only
  notary authentication. No TeleCRM environment file, password or private key was
  copied. Ignore checks cover environment files, local wrappers, signing keys,
  certificates, provisioning profiles and generated output.
- Fresh spec-only gpt-6.1-sol authors wrote release and menu bar acceptance tests
  before implementation, with no inherited chat or production-source reads.
  This is context separation; filesystem isolation is not enforced.
- Complete Tests/run.sh passed: prior 887 assertions plus 12 release methods,
  6 bounded-command methods, 625 menu fixture pairs, 256 generated pairs (seed
  0x4C494D4954), 64 state transitions and 8 rendered snapshots. Tests/lint.sh passed.
- Release fixtures inject signing, packaging, notary status, malformed/oversized
  output, timeout, staple and Gatekeeper failures. Concurrency checks preserve the
  owner's lock. Timeout instrumentation measures subprocess launch using standard
  audit events, retaining the deadline and exactly-one-attempt assertions when a
  child is killed before its executable body starts. Seed 20261011, bounded local
  fixtures only. Live load/Apple fault testing is inapplicable to offline preparation.
- A disposable Accepted-guard mutant published a Rejected result; the frozen
  negative test failed as intended. Later subcases inherited that mutant output;
  they are not counted as independent mutation detections. Production guard remains.
- Light/dark menu previews visually checked both, either, neither, 0% and 100%:
  vector provider marks, readable percentages, no opaque backgrounds or clipping.
  Empty state keeps a generic gauge and reachable popup; no invented 0% provider.
- Finder reproduced a signing child/lock surviving a TERM sent to the intermediate
  build shell. The bounded runner and background wait now propagate cancellation
  and clean up process groups. Independent verifier observed TERM exit143 in
  0.067s and INT exit130 in 0.124s, lock removal and no delayed descendant write;
  a disposable 1-second signing deadline also cleaned up. A direct-foreground
  counterexample retained shell/lock and permitted the delayed write. An exact
  historical intermediate snapshot was unavailable to that verifier.
- Universal local app compiled for arm64/x86_64 and passed strict ad-hoc signature
  verification. The build used explicit SDKROOT/toolchain paths; the system Python
  shim emitted cache-permission diagnostics but exited successfully. No distribution
  signing was exercised. Mandatory commit hook and hosted CI are separate checks.
- Local fixtures do not prove real signing, notarization or App Store acceptance.
  No Apple upload, installation, publication, console record or sandbox redesign
  was performed. The app icon concept board is preview-only, awaiting user selection.
- Commit-hook attempts blocked on tests exit1, while a direct configured gate
  passed. Retained test transcripts exposed the timeout fixture's cross-process
  clock calculation: macOS Python 3.9 and 3.14 use incompatible monotonic clock
  references. The independent test author changed both timestamp reads to POSIX
  CLOCK_MONOTONIC. A separate verifier confirmed exactly two clock substitutions,
  unchanged one-second deadline, <4.5-second elapsed limit and exactly-one-attempt,
  unknown-outcome, cleanup and no-artifact assertions. Isolated timeout checks pass
  under Python 3.9, Python 3.14 and a fully Python 3.9 subprocess PATH. See
  [Python's clock documentation](https://docs.python.org/3/library/time.html#time.monotonic).
  Failed hook runs are not counted as passing verification. Tests/run.sh retains
  failed transcripts without changing checks or exit codes. Native NSStatusBar
  integration exits before its completion marker in this tool context, so it
  remains unverified.
