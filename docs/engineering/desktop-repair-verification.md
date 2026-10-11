# Desktop repair verification

Baseline: ce7b0dd, Innolope/LimitFuel. Accepted scope and failure categories are
in docs/plans/2026-10-11-desktop-connection-repairs.md.

## Independent evidence

- Fresh spec-only gpt-6.1-sol authored four frozen acceptance suites before
  implementation. Context isolation was instructed; filesystem isolation was not
  enforced. Root implemented core/UI repairs; gpt-6-astra implemented diagnostics.
- Baseline failed the valid-session/unsafe-auxiliary case, startup Codex account
  updates and persistent menu-mark pixels. Fixture-only adapters use writable temp
  paths and Python through PATH; expectations and deadlines were retained.
- A separate finder reproduced three denied Keychain lookups within one detection;
  the independent verifier reproduced it, then observed one lookup after the fix.
- The verifier found concurrent opt-out/re-enable retaining a cache generation.
  Its unchanged probe observed a new generation and deletion of the old queued
  file after the fix. Main-thread SDK shutdown avoids a synchronous queue deadlock.
- Frozen diagnostics policy and expanded SDK privacy suites passed. The expanded
  suite captures the actual SDK HTTP envelope through an offline URLProtocol,
  decompresses it and checks synthetic secrets and private fields are absent.
  It also exercises real SDK start/close/restart, queued report invalidation,
  persistent opt-out, failed/stalled transport and cache cancellation/rotation.
- Pinned SDK source inspection confirms sanitized events enter the normal envelope
  cache. The enabled crash integration does not register a later event processor
  that restores private fields. SDK version9.30.1 and license hashes are pinned.
- A disposable sanitizer leak mutant failed the privacy check. A separate Codex
  mutant disabling established-account invalidation failed the new negative test.
- Live read-only Codex probe using the repaired client returned a nonempty quota
  snapshot from the existing ChatGPT login. Only the availability boolean was
  printed; no account identity, token or quota values were logged.
- Six menu states were rendered and inspected on light/dark backgrounds: neither,
  either, both, 0% and100%. Same Segments mark, readable percentages, no clipping.
  Popup/settings fixture captures verify layout only; offscreen material/blur
  rendering is not proof of the native window appearance.

## Required gates and budgets

Tests/run.sh retains the existing 599 reader,69 lifecycle,219 Codex assertions,
512 header fuzz cases (seed0xC0FFEE),128 Codex generated cases (seed0xC0D3),
625 menu pairs/256 generated pairs (seed0x4C494D4954),64 transitions and8 rendered
snapshots. Release/bounded-command tests and all new desktop/diagnostics suites
remain required. SDK privacy tests require the checksum-verified cache and cannot
silently skip or download during an offline run. Tests/lint.sh checks new metadata.

An initial suite passed before the final SDK concurrency repairs. A later run
failed the new two-second Codex fixture while several compilers ran concurrently;
that run is not passing evidence. Serial gates failed the menu pixel
comparison. The independent author initially could not reproduce it across 1,000
in-process cases and 60 fresh processes, including allocator, initialization and
graphics-context variations; 15 additional fresh root probes passed. Its cause
was then captured: the gate selected 2x source snapshots, while those probes used
1x. Forced2x bitmap reproduction confirmed identical source icon pixels but
width-dependent downsampling at1x. Destination-resolution vector drawing passed
the unchanged pixel comparison. The assertion includes pixel/representation
diagnostics, with the exact threshold and original fixture behavior unchanged.
Another gate failed existing
release fixture deadlines during a system load spike above390; no leftover
LimitFuel test processes were found, and the focused success fixture subsequently
passed within its unchanged deadline. These failed runs are retained as failures.
Final configured checks run without concurrent builds through the existing
mandatory commit hook. Its result and the hosted PR check are the final gates,
separate from this record. No hook was installed or trust setting changed.

Latest historical hosted job took2m12s (tests80s, build42s). No running/queued job
was present before publishing. The updated macOS job has a ten-minute total
budget; SDK download is75MB and bounded/checksummed. No deployment is dispatched.

## Assumptions

- Default Google Chrome profiles and an installed ChatGPT-authenticated Codex CLI.
- The application error budget is20 attempts/hour per running process; relaunch
  resets the budget. Offline synthetic tests do not load live providers.
- Sentry's public DSN came from the dedicated GitHub production configuration.
  No auth token is required, used, committed or bundled.

## Not handled

- Real interactive Keychain approval, deliberate native crash/relaunch replay and
  live Sentry receipt/project settings. No provider sign-in is automated.
- Full native crash symbolication: debug image metadata and symbol uploads are
  excluded. See docs/diagnostics.md for the privacy tradeoff.
- Developer ID signing, notarization, App Store acceptance or merging the PR.
  Local installation uses an explicit ad-hoc signature with a retained rollback.
