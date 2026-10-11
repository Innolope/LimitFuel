# LimitFuel defect preflight

## 2026-10-11: keep raster fixtures independent of host accessibility policy

Hosted run 38180010677 failed the eight stale-text pixel-difference cases while
all other blur assertions passed locally and on CI. The fixtures inherited live
NSWorkspace preferences; official actions/runner-images configure-system.sh
sets Reduce Transparency true. This is a concrete host-policy explanation,
pending the next run's actual preference receipt, rather than evidence to remove
the application's accessibility fallback.

Inspect `rg -n 'allowsBlur|accessibilityPreferences|accessibilityDisplayShould' app Tests`.
Production callers must use the default live accessibility policy. A deterministic
fixture can explicitly choose rendering while separate injected truth-table tests
cover the real default and prove explicit overrides do not read host preferences.
Fresh values are a safe counterexample: they remain sharp with either policy.
Preserve every numerical, visible blur, sharp-logo and native-scale assertion;
do not change the runner's OS preferences or weaken contrast/transparency support.

## 2026-10-11: retained popup scroll position

Trigger: scroll a tall dashboard to its footer, close and reopen. The persisted
SwiftUI host retains the NSScrollView offset, hiding header/refresh/settings
controls. An actual baseline UsageView native fixture measured document1043pt,
viewport600pt and offset443pt before and after reopening; shrinking the data
left offset97pt. The screenshot is consistent with this behavior, but its exact
interaction history is unknown.

Inspect `rg -n 'openPopover|beginPresentation|scrollTo|opening|contentSize' app`.
Follow every opening path and the actual hosting/scroll lifecycle. The fixed
initial contentSize320pt was not the cause in this fixture: AppKit correctly
resized the hosted view to600pt. A deliberate scroll while the same presentation
stays open is a safe counterexample: normal user scrolling must still work.

Regression: offline native open/scroll/close/reopen and page-switch fixtures,
plus screen-bounded viewport tests. Geometry proves native positioning/offset;
caching a material-backed view alone does not prove composited appearance.

## 2026-10-11: select available Codex limits before rendering

Trigger: a parser-accepted preferred `codex` or first bucket has no windows,
while a later bucket has usage42% or0%; alternatively primary101% accompanies
secondary42%. Selecting the bucket/window before validation hides the provider
from the menu bar despite available data. Finder and separate verifier reproduced
this from synthetic parser inputs; no live incidence was established.

Inspect `rg -n 'menuBarPercent|updateSelectedProviderIcon|displayWindows' app`.
Preserve preferred-codex, primary and original-bucket precedence, filtering
availability before fallback. A valid preferred0% is a counterexample to truthy
selection: zero must win over later usage. CodexMenuSelectionTests covers missing,
invalid/nonfinite values, zeros, precedence and order; native integration checks
the actual menu tooltip.

## 2026-10-11: distinguish provider window choices

Trigger: two Codex buckets have different IDs but the same display name and
primary duration. Settings shows identical option labels, so a user cannot tell
which saved choice will be used. Separate finder and verifier confirmed the
reachable source path and froze a synthetic regression before the repair.

Inspect `rg -n 'menuBarOptions|option.label|bucket.id|nameCounts' app` and follow
the option producer through the Settings picker. Stable choice IDs alone do not
make labels distinguishable. Different names are a safe counterexample: they
need no extra identifier. MenuPreferencesIntegrationTests asserts duplicate names
include distinct bucket IDs and labels remain stable across percentage changes.

## 2026-10-11: separate browser sync from provider connection

Trigger: a saved Claude cookie still fetches valid usage, but hourly Chrome sync
cannot read Safe Storage. The old dashboard renders connection buttons whenever
chromeNeedsAttention is true, suggesting disconnected usage. Inspect
`rg -n 'chromeNeedsAttention|showsClaudeConnectionControls|hasFetchedData|401|403' app`.
Follow the usage HTTP result and cookie-sync result separately. A real401/403 is
a safe counterexample: recovery controls must remain reachable after prior success.
ClaudePresentationAcceptanceTests covers all16sync-state combinations and
success→401/403/500/timeout→success, with fake HTTP and forbidden Keychain access.

## 2026-10-11: optional usage availability and stale reset state

Trigger: a response with weekly/model limits is followed by one without them or
with invalid optional values. Unconditional rendering invents Weekly0%; retained
model flags/reset times can make nonexistent limits look real. Existing-API
baseline reproduced15failures in21assertions before the repair. Inspect
`rg -n 'resetOptionalUsage|hasWeeklyUsage|hasWeeklySonnet|hasWeeklyFable|weeklyResetsAt' app`.
Trace each parse failure, successful response and account clear. Numeric0 is a
real available value, including for explicit menu selection. The user-approved
dashboard heuristic hides overall Claude Weekly0 while session usage is positive,
and shows both at0; this must not erase raw availability or round decimal positives
before making the visibility decision. Check `showsClaudeWeeklyUsage` and its
dashboard call site; matrix and native row-transition tests cover this rule.
Frozen acceptance covers256seeded optional-data combinations, seed0xCA11AB1E20261011,
and present→missing→zero→clear sequences. No subscription-name inference is used.

## 2026-10-11: transient refresh must not erase a connected menu value

Offline baseline reproduced Codex15% disappearing after timeout, Claude18%
disappearing after HTTP500, and Claude18% disappearing while a same-session
auxiliary cookie changed. Canonical fetch state and menu display had shared
clearing behavior. Inspect `rg -n 'menuBarDisplayOptions|retainedMenuBarOptions|resetUsageData|sessionIdentity|menuBarUpdatedAt' app`.
Trace loading, every failure, recovery and credential revision. Valid response
missing a formerly available window is a safe counterexample: its new complete
snapshot must replace the cache. Actual401/403/signIn and identity changes must
also remove old values. Frozen MenuRefreshStabilityTests covers offline faults,
coalescing, late cancellation, raw/display separation and notification suppression.
StaleBlurAcceptanceTests verifies600..1800second bounds, independent update age,
exact accessible values and1x/2x text-only image changes.

## 2026-10-11: native fixture readiness includes loader startup

Fresh identical native executable paths sometimes reached main after the6second
fixture readiness deadline on a host with load>500; warm paths started29..46ms.
Workspace and /private/tmp both failed, while Process.run returned within11ms.
Do not infer that the product failed descendant cleanup before the fixture became
ready. Inspect preparation and readiness separately. The explicit --prepare mode
must complete within30seconds without markers, output or children before the
unchanged6second readiness/8second client/12.5second completion scenario. A warm
fixture that becomes ready promptly but survives cleanup is a real product
failure, not a startup exemption. FixturePreparationTests verifies repeatability
and side-effect absence; preparation timeouts remain visible gate failures.
