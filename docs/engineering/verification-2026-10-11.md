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
