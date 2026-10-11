# Menu countdown badges and refresh stability

The user approved the compact badge preview: one percentage per connected
provider, with its selected window's time until reset in a smaller rounded
badge. Show one unit only: whole days at >=24h, whole hours at >=1h, minutes
below1h. Preserve the approved vertical centering of logo, percentage and badge.
The user also reports a percentage sometimes disappearing and requests a fix.
Runtime Plan mode is unavailable; this equivalent plan precedes implementation.

## Acceptance

- M1: Keep independent provider/window selections and session-first fallback.
  A selected window supplies its own percentage AND reset timestamp. Badge
  uses remaining time, never the window duration. Days/hours truncate; minutes
  round up to avoid positive remaining time reading0m. At/past reset show0m;
  never synthesize a fresh usage percentage before provider confirmation.
- M2: Unknown/nonfinite/unsupported reset timestamps omit only the badge.
  Zero percent remains visible. Neither provider available shows the app mark;
  one/two providers show only their actual monochrome logos and their values.
  Native template rendering must fit at1x/2x with vertically centered badges.
- M3: Retain the last validated menu values during loading and temporary failures
  (timeouts, network/server/protocol/invalid-data/executable-unavailable errors).
  Mark them as last known in accessible text/tooltip and show existing errors.
  Current raw invalid data remains unavailable; retained display values do not
  rearm notifications, invent zeros or revive missing windows in valid responses.
- M4: Actual auth failure/sign-out, explicit clear, or changed Claude sessionKey
  or organization clears retained menu values immediately. Different credentials
  cannot inherit old-account percentages. Unchanged session/org auxiliary-cookie
  rotation keeps the validated display. Existing revision guards reject old replies.
- M5: Valid subsequent responses replace the retained display atomically, clear
  stale indication and apply selected-window fallback. A valid response with no
  usable windows removes that provider. No extra network polls/Keychain prompts;
  countdown redraw occurs on existing refresh/minute/wake paths.
- M6: Complete previously authorized Claude connection/Weekly changes and update
  existing PR3. Gate, clean universal local build and verified app installation
  remain required; do not merge or publish a distribution release.

## What can go wrong

| Category | Trigger / invariant | Test / decision |
| --- | --- | --- |
| Invalid input | nil/NaN/infinite/huge/past reset; malformed usage | Formatter boundaries, valid0%, last-known only on failure; hide badge alone |
| Concurrency | simultaneous refreshes, late replies after account clear/import | Existing coalescing/revision fixtures plus held responses and menu publication |
| Idempotency | repeated failure, repeated cookie sync/window selection | Display unchanged, one request set, notification history unchanged |
| Timeouts | HTTP/app-server timeout after success | Last known menu survives, error visible, existing deadlines retained |
| Retries | routine timers/manual refresh after failure | Recovery replaces display; no added polling or prompt, independent providers |
| Partial failure | one provider fails while other succeeds | Both numbers persist; current error distinguishes cached data |
| Auth |401/403, Codex signIn, manual clear or different session/org | No old-account menu value; a later valid response recovers |
| Data limits | timestamp overflows, many buckets/long labels | Bounded formatter, existing1MiB/64-bucket limits unchanged; rendering extent checks |
| Migrations | existing Settings IDs, optional windows change | Existing preferences unchanged; saved missing choice falls back then restores |

Failure scenarios were presented in chat before production changes. No further
business decision is required for the accepted one-unit countdown. Retention is
display-only in memory, scoped to the validated current credentials; not persisted
across launches. Current parser availability continues to follow existing tests.
Rotating sessionKey is conservatively a credential identity change because the
cookie alone cannot prove that it belongs to the same account.

## Work and verification

1. Freeze spec-only tests from fresh gpt-6.1-sol context; implementation uses
   distinct gpt-6-astra. Shared filesystem is context separation, not sandbox isolation.
2. Reproduce transient-failure/cookie-rotation disappearances with synthetic inputs.
3. Implement reset propagation, native badge drawing and scoped display retention.
4. Run focused acceptance and mutation challenges before the full configured gate.
   Diagnose the prior native descendant readiness failure before another full run.
   Preserve all existing deadlines/assertions; no blind retry.
5. Run native presentation/image inspection, lint, gate and universal build; update
   PR3 once, inspect exact-head CI and install a verified clean-source bundle with rollback.

Network/load testing against real accounts is out of scope: existing offline
fault fixtures exercise I/O boundaries. Local rendering has no capacity-sensitive
server work. No credential contents, auth keys or local release secrets enter Git.

## User revision: progressive stale blur

The user explicitly chose start10minutes, maximum30minutes, per provider.
Count from that provider's last successful usage response, never a refresh attempt,
cookie sync, Settings change or the other provider's success. Blur percentages and
countdown text gradually from0to1.2pt over600..1800seconds; keep provider marks
and badge backgrounds sharp. Cap blur to retain legibility. Successful usage
immediately restores sharpness. Unknown timestamps and invalid clocks do not
invent age; disconnect/auth protections still remove old identity data.

Accessibility: tooltip/VoiceOver retain exact values and update age. Increase
Contrast or Reduce Transparency disables blur; stale text remains available.
No new permission prompt or additional polling. Existing minute/wake redraws
drive the effect. New spec-only tests freeze threshold/monotonicity/provider
independence/recovery and1x/2x rendering before implementation. Test-author and
implementation roles remain separate. All other failure-list categories above
apply; optional badge errors cannot remove a provider's percentage.

## Observed fixture startup failure

The previous full gate failed before the descendant timeout assertion: a newly
compiled native fixture did not enter main within the existing6second readiness
budget. An isolated unchanged Codex suite passes219checks. Identical executable
bytes at fresh paths delayed markers beyond6seconds, while warm paths started
in29..46ms. Process.run returned within11ms; changing /private/tmp to workspace
did not resolve it. The host load exceeded500. Exact OS cause is unverified.

Prepare the executable through an explicit no-side-effect --prepare mode under
its own30second bound before the timed scenario. Preparation failure remains a
gate failure. Independent frozen tests verify exit0, no output or markers and
repeatability. Keep the existing6second readiness,8second client deadline and
12.5second completion assertions unchanged; do not reinterpret failed runs as
passing or retry an unchanged gate blindly.

## Verification receipts

- Baseline (frozen pre-change sources):3display failures reproduced, expected exit1.
- Countdown frozen suite:4,162checks passed, seed0xC0FFEE,4,096generated boundaries.
- Fixture preparation: silent/idempotent/no-marker acceptance passed; first copied
  executable preparation took6.667seconds, consistent with the observed startup
  issue and separately bounded from cleanup behavior.
- First blur run:4of4,197assertions failed on2x logo invariance;1x, ages, text
  differences and sharp fallback passed. Core Image also emitted Intel OpenCL
  errors. Replaced the driver dependency with a bounded CPU separable Gaussian
  and explicit glyph-layer clipping. Exact pixel diagnostics then proved the2x
  fixture created its context before setting bitmap logical size, drawing1x
  content on a2x canvas. The independent spec author corrected only that helper
  and added explicit scale assertions; logo boundaries remain unchanged. The
  disposable corrected diagnostic passed all4,197original assertions.
- Test contexts were fresh spec-only gpt-6.1-sol; production implementation used
  gpt-6-astra. Shared filesystem isolation is procedural, not OS-enforced.
- Frozen SHA256: countdown b97eea1766b84f8ce693155c5ec367e992a1e7c851a481482fe3de743f6440cc;
  stability b0d3be7260470cf1ac0337923b1f5ca88c755a2b4e13ee68bb5b698ef31abe1e;
  corrected blur a9cd30a338e72c36eff75750f6bf8444ad75e61b0f4bac72da2386365fd2ee51;
  provider age706863ccf8d1d241c945f4c90f95c5561b21dfe9ff606cfe021653c16d211d76.
- Disposable CPU-blur protection removal (radius forced to zero) was rejected
  by2,051of4,261checks in the corrected frozen suite. The production copy was
  untouched. This challenges both numerical thresholds and visible text blur.

## User revision: used or remaining percentage

The user requests a Settings toggle and explicitly chooses Remaining as the
default. Scope is the menu bar, one global preference applying to both providers.
Dashboard usage meters and threshold polling/notifications continue using raw
used percentages. Compute remaining as100minus validated unrounded usage, then
round the display. The selected window, reset badge, last-success age and blur
are independent of this preference. Tooltips identify Used/Remaining explicitly.

Failure additions: missing/invalid persisted mode defaults to Remaining; reload
preserves explicit Used; switching is idempotent and redraws immediately after
the preference changes. It must neither fetch usage, change credentials, alter
saved provider windows nor reset freshness. Invalid values still hide,0used
becomes100remaining and100used becomes0remaining. Independent spec-only tests
freeze boundary/seeded transforms, persistence and actual delegate integration
before production changes. Existing native used-display fixtures will explicitly
select Used, preserving their original assertions under the new default.

Frozen PercentageModeTests SHA256:
eb54600be79858afbc66eecdb6df7fe6372d9ced23c944794cd1ac1550a99af6.
Fresh spec-only model gpt-6.1-sol authored boundary, malformed preferences,
1,000seeded percentages and actual offline delegate tests; implementation model
gpt-6-astra changed only preferences, rendering and Settings integration.

The final percentage-mode source compiled and passed10,172acceptance assertions,
including1,000seeded inputs and actual native delegate default88%/67%, Used12%/33%
and selected Weekly Remaining66%/67%. Switching preserved raw utilization and
the successful-response timestamp and made no network request. Initial sandboxed
execution was inconclusive because Foundation selected a protected system temp
folder; the identical offline binary passed outside that filesystem sandbox.
Lint and whitespace checks passed on the combined staged change. Full configured
gate, universal build, hosted CI and installation remain separate milestones.

## Final verification observations

The configured gate failed in unchanged ReleaseWorkflowTests before Swift
acceptance ran: 12 tests in 219.553 seconds, 11 failures and 4 errors. Mocked
release processes exceeded the existing 20-second limit; the concurrency fixture
missed its 5-second boundary, and later cases observed the timed-out fixture's
remaining lock. Lint passed. Neither release code nor those deadlines changed.
An isolated unchanged success case subsequently passed in 14.493 seconds with
no compiler running. The unchanged whole release contract then passed all 12
tests in 100.743 seconds; no deadline or assertion was relaxed.

A disposable combined Swift compile reached its 600-second bound. A second,
bounded compile used whole-module compilation and succeeded. It preserved exact
production bytes and removed only each test file's @main annotation, dispatching
each original main in its own child process. Input hashes and transformations
are recorded in .limitfuel-install/focused-final/manifest.json outside Git.
Against those final production bytes, countdown passed 4,162 checks, blur passed
4,261 checks, Claude presentation passed 2,131 assertions, the weekly rule passed
709 assertions, and native Claude presentation passed. Native 1x/2x raster images
were inspected: centered percentage/badge, sharp logos/backgrounds, progressive
text blur. This focused verification does not replace the configured gate.

The refresh and age suites exposed test sequencing mistakes: stale becomes true
at poll start, so their recovery calls could be coalesced into the still-running
failure; initial successful usage could also publish before auxiliary callbacks
finished. The independent test author confirmed this from tests, logs and public
contracts without reading production. Corrections add main completion, exactly
four transport deliveries per poll, empty injected-session tasks and a main-queue
acknowledgement before the next poll. Original assertions, failure scenarios,
4-second waits and existing drain durations remain. Disposable defaults disable
real Chrome discovery and Claude notifications. Codex notification assertions
remain unchanged. Corrected frozen hashes:

- Refresh: eb76bd7466bac0994ed98e4292d166a04bb49abf5e40cc78f9cf2fe386c4d404
- Age: e450dd92994db5f994e9c2d837a3007e2c199c5eed70ec0a872e521f1b578a8d

At that checkpoint the corrected suites still needed execution. The native
popup suite separately failed its Back-header navigation assertion, with all
assertions retained. Nothing had been committed, pushed or installed; the
installed app was 1.3.6 (11).

The runner now builds the eight shared application sources once as an
unoptimized, testable Swift module/dylib. Each original suite is compiled with
only a prepended testable import and runs in its own process. This removes
repeated expensive app compilation without combining fixture state. Structural
inventory comparison verified every original suite, runtime command, order and
environment; standalone Sentry SDK/privacy compilation remains byte-identical.
The configured 480-second gate budget remains. Structural checks were followed
by the real import, linking and runtime verification recorded below.

## Local acceptance complete before publication

The complete configured test/lint gate passed in 294.4 seconds, including all
original suites, release contracts, subprocess cleanup, Sentry privacy, and the
new frozen acceptance. Corrected refresh passed 203 checks; provider age passed
48; Used/Remaining passed 10,172. No test, assertion, failure case or configured
deadline was removed. The successful gate's exact shared-module bytes and source
hashes were preserved outside Git for native verification.

The diagnostic native popup run showed a real Back click, the same attached
scroll/document changing from 1119 to 1683 points within the original 0.8-second
endpoint, and both Settings selectors disappearing on return to the dashboard.
The original suite then passed with unchanged assertions and timing against that
same module. The earlier navigation failure was not reproduced; its exact cause
is unverified, so the diagnostic pass is not claimed as a product repair.
Native Claude presentation and native countdown/blur raster checks also passed.
View-cache screenshots omit material-backed compositing; they are not proof of
the complete macOS glass appearance.

Status at this source checkpoint: local acceptance and lint passed. Clean-source
universal build, hosted exact-head CI and installation with rollback follow the
commit; those receipts must be recorded separately before claiming delivery.

## Separator revision and CI accessibility fixture correction

The user explicitly replaces the translucent reset badge with plain text and a
vertical separator: provider mark, percentage, `|`, and the existing one-unit
reset countdown. Omit both separator and countdown when reset is unknown. Keep
percentage and countdown vertically centered, both providers independently
visible, and Used/Remaining preference and freshness behavior unchanged.
This is a visual revision of the previously approved badge, not a timing change.
Plan mode cannot be switched by this client; this persisted plan remains the
equivalent working plan.

Build/install receipt for 21ece3f: local universal build and strict ad-hoc
signature passed; 1.3.7 (12) was installed and launched with a verified binary
hash and a preserved 1.3.6 backup. Hosted run 38180010677 failed only eight stale
text pixel-difference assertions; universal build was skipped. No rerun occurred.
The fixtures omitted allowsBlur and inadvertently inherited host accessibility
policy. Official actions/runner-images configure-system.sh explicitly enables
Reduce Transparency. This strongly explains the matrix of failures; the next
test run will print the actual host preference flags as a receipt.

Clarified renderer contract: allowsBlur defaults to nil, respecting both live
Increase Contrast and Reduce Transparency flags. An explicit true/false is a
deterministic internal fixture override and must not query those flags. All
application callers keep the default policy. Injected preference truth-table
tests supplement every existing numerical/pixel/logo assertion; no OS settings,
assertions, deadlines or CI budgets will be weakened. The independent spec author
freezes these tests before the separate implementation role changes production.

### What can go wrong

- Invalid reset timestamps: omit countdown and separator together; retain the
  percentage. Existing invalid/date-boundary acceptance remains applicable.
- Concurrency: the draw closure must consistently use its captured entries and
  percentage mode. No additional mutable state or async operation is introduced.
- Idempotency: repeated rendering of identical input/preferences has identical
  dimensions and pixels. Keep explicit overrides independent of host state.
- Timeouts: no external operation is added; existing test/build deadlines remain.
- Retries: no network, polling or retry changes in this visual/API slice.
- Partial failure: missing provider artwork keeps the existing fallback; absent
  reset does not remove its provider's number. Validate both 1x and 2x output.
- Auth: rendering has no credential access; existing clear/identity invariants
  remain covered by the unchanged refresh and age suites.
- Data limits: keep the existing bounded date, finite percentage and two-provider
  contracts. Separators must not collide with adjacent percentage/countdown glyphs.
- Migration: no preference/schema/version migration. Existing Used/Remaining
  choice persists; Remaining is still the default. The installed verified prior
  binary and backup remain available until a new clean-source build is verified.

Verification milestones: frozen acceptance, focused native raster inspection,
accessibility-policy mutant rejection, complete configured gate, ordinary guarded
commit, one push with a concrete changed condition, exact-head hosted checks,
clean-source universal build and verified installation. Keep PR #3 draft until
hosted checks pass; no new merge authorization is inferred.

Frozen revision acceptance SHA256:
948a0eb3628929428f8c73a7d838ee169e3f40f447537498777584e90ce068b7.
The independent author preserved existing assertions and added native plain
separator/policy coverage before the implementation role was released. Official
runner source inspected at revision 8197087fc536320d1441203fdb5da9ae1b44b863,
images/macos/scripts/build/configure-system.sh (Reduce Transparency enabled).

Focused revision verification passed all 4,573 frozen assertions, including
the preserved 2,048 generated ages (seed 0x5A1EB10B), all injected accessibility
combinations, deterministic overrides and 1x/2x spacing/alignment. Native raster
inspection covered both providers, a single provider and unknown reset on dark
and light backgrounds. Percentage stays 13pt regular, countdown stays 10pt medium;
the centered 1pt divider and logos stay sharp. No font-size change was requested.
The local host receipt was Increase Contrast false / Reduce Transparency false.
A disposable variant that ignores accessibility preferences was rejected by
12 policy assertions; production source was not mutated. Full configured gate,
hosted CI, clean-source build and new installation remain separate milestones.

The revision's complete test and lint commands both exited zero, including
offline Sentry privacy. The quality gate correctly rejected the receipt because
the parent changed README/plan documentation and staged the index during checks.
This is an invalidated validation snapshot, not a passing gate or failing product
test. Final inputs are now frozen; ordinary guarded commit must revalidate them
without concurrent file/index changes. No gate or invariant is bypassed.

## User revision: centered dot

After the pipe revision was committed as cda1e65, the user explicitly replaced
the vertical separator with a centered dot: `81% · 6d`. This supersedes only
separator geometry. Preserve 13pt percentage, 10pt medium countdown, spacing,
sharp marks/separator, no background, missing-reset omission and every accepted
data/blur/preference invariant. The same failure list applies; no new external
boundary, state or preference migration is introduced. Independent shape-test
correction precedes the separate rendering edit; other assertions are unchanged.

The superseded local universal build was stopped through its TERM cleanup, and
hosted run 38181618902 was cancelled to avoid finishing obsolete artifacts. The
installed verified 21ece3f app is retained until the dot revision is verified.
Finish all docs/staging before ordinary guarded commit, so its validation
snapshot stays immutable. Then push once, verify exact-head CI, build and install
only the requested dot revision with the prior app preserved for rollback.

Native previews showed current (5pt each side), compact (3pt) and tight (2pt)
spacing. The user selected tight with a slightly increased gap after the dot.
Use 2pt before and 3pt after the centered 2pt dot, preserving typography and
all prior invariants. Independent corrected dot acceptance is frozen at SHA256
e2539b42967b293baafd7b9bae038e1eee20d7d1e923faf3657ea95168816fb9;
only shape assertions changed, replacing the former tall stroke with a small
round centered component. Keep every blur/policy/logo/spacing assertion.

The selected 2pt/3pt spacing passed all 4,577 frozen assertions at 1x/2x,
including maximum-blur dot sharpness and every accessibility preference
combination. The previously verified explicit-policy API is unchanged. Final
rendering source SHA256 is
498bfc8e723c5cbd9cef12616138c6fbfa363e2bc8e645c52bbd9f2813bf702b.
Final light/dark previews use native AppKit rendering and bundled PDF marks,
with synthetic percentages. Complete guarded-commit checks, exact-head hosted
CI, clean-source universal build and installed-bundle verification follow this
frozen checkpoint. No file/index edits will occur during commit validation.
