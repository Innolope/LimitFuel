# LimitFuel defect preflight

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
