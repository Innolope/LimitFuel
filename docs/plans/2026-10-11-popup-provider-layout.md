# Popup and provider display repairs

Baseline: main6162a95. User screenshot shows the popup's upper content cut off,
and a Codex Secondary row rendered as unavailable. The user explicitly requests
provider logos when connected, with the app mark only while disconnected.
This supersedes D1 of the earlier desktop-connection plan. Runtime Plan mode is
unavailable; this file records the equivalent plan before production code.

## Acceptance

- P1: Popup viewport and native popover height agree and fit the screen containing
  the status item. Opening starts at the top, including after a prior scroll or
  data-driven resize. Tall dashboard/settings content remains scrollable to its
  bottom, with no lost header or controls. Do not recenter an oversized root view.
- P2: With no valid connected usage, show only the monochrome Segments app mark.
  With Claude and/or Codex usage, show only the corresponding monochrome Claude
  and OpenAI marks and percentages, Claude first. Hide disconnected providers.
  Keep template rendering,0%/100%, rounding, accessible provider names,1x/2x.
- P3: Omit a Codex secondary row when its window is absent. Retain real0% rows and
  existing titles/durations. If only a secondary window exists, render it once;
  never invent an unavailable primary row alongside it.
- P4: Preserve provider authentication, polling, diagnostics defaults/opt-out,
  settings/preferences and connection recovery. Install a clean verified build
  with a rollback copy, publish a PR; merging/release publication is separate.
- P5: Keep exactly one number per connected provider. Each provider gets its own
  Settings selector for a specific available bucket/window. Default Automatic
  prefers a positive, shorter-than-one-day session window (usually5h) over weekly
  usage, then retains existing preferred-bucket and window order. Explicit saved
  choices override Automatic, persist independently and update the bar immediately.
  Missing/invalid windows temporarily fall back without deleting the saved choice.
  No stale account percentage, invented zero or authentication side effect.

## What can go wrong

| Category | Trigger / observable invariant and impact | Test / decision |
| --- | --- | --- |
| Invalid input | Missing/nonfinite/out-of-range usage excluded; zero visible; malformed layout measurements cannot grow the window | Existing parser/menu tests plus geometry boundaries; accepted technical repair |
| Concurrency | Async usage/profile/status updates change content while popup opens or moves screens; viewport/native size must converge without losing the top | Offline native popover resize and repeated presentations; accepted |
| Idempotency | Repeated open/close or same measurement must not create observers, scroll jumps or resize loops | Repeated lifecycle/layout cases; accepted |
| Timeouts | Layout/display service or fixture unavailable must be reported as unverified, never pass | Bounded offline native probes; provider timeouts unchanged |
| Retries | No new provider or telemetry retries; rendering failures need a visible deterministic mark | Asset fallback smoke, existing suites; accepted |
| Partial failure | One provider/window/asset missing must not hide the other provider or leave empty unavailable rows | Single/both/neither and nil-window permutations; accepted |
| Auth | View changes must not read credentials or trigger sign-in/Keychain prompts | Offline managers/fixtures only; auth integration unchanged |
| Data limits | Tall settings, error text, multiple buckets, small/scaled screens; screen-bounded viewport with full scrolling | Fixed geometry cases and seeded generated boundaries, native tall-content fixture; accepted |
| Migrations | Existing settings/bundle ID/manual cookie unchanged; latest icon preference overrides older frozen expectations | Explicit spec correction in menu tests; rollback prior installed app |

Failure cases above were presented in chat before implementation for user edits;
they follow explicit requested behavior and prior accepted authentication/polling
decisions. No new business-policy decision is required.

## Implementation and verification

1. Freeze spec-only tests in a fresh context with a model different from the
   implementer. Record tool/model/isolation limits; do not weaken existing checks.
2. Reproduce layout/menu/missing-row failures offline; implement bounded sizing,
   provider marks and conditional meters after expectations are frozen.
3. Test positive/negative states,1x/2x, display geometry and real native popover
   fixtures; separately find and verify substantive defects. Challenge the sizing
   bound in a disposable failing variant. No live provider load or real credentials.
4. Run configured test/lint gate and universal build, publish one PR assigned to
   innolope-dev, verify exact-head CI, install from clean source with retained rollback.

## Assumptions and unresolved items

- Standard desktop screens with room for a menu bar. Native window behavior must
  be measured; the screenshot alone does not establish its clipping mechanism.
- Existing vector provider assets are reusable. No network asset download needed.
- Native popup visual/geometry verification will be distinguished from offscreen
  SwiftUI layout captures. Notarization and App Store release remain separate.

## Baseline evidence and frozen expectations

- Independent fresh spec-only author gpt-6.1-sol froze PopupAcceptance.swift
  before production implementation (SHA256902f1ad9205bd2d850fae20c5b013fd06094a19987804b5df4119a0572d8d298).
  Implementation uses distinct gpt-6-astra. Context separation is instructed;
  agents share the filesystem, so filesystem isolation is not enforced.
- Rendering-only baseline execution fails the actual provider PDF oracle:
  `First mark must match provider PDF rather than app mark`. Missing new helpers
  were excluded from this baseline probe; compile failures are not product evidence.
- An offline native AppKit fixture using the actual baseline UsageView on the
  1440x900pt display (visible height781pt,2x) reproduced retained scrolling:
  four synthetic buckets gave document1043pt / viewport600pt; bottom offset443pt
  persisted across close/reopen. Shrinking to two buckets retained offset97pt.
  Header controls disappear while the footer remains reachable. This reproduces
  the reported shape, but does not establish the user's exact interaction history.
- The fixed320pt native contentSize hypothesis was refuted: AppKit resized the
  hosted view to600pt and native window626pt despite the property staying320pt.
  Correct fresh-open scroll reset is essential; a height cap alone is insufficient.
- DesktopMenuTests previously enforced an app mark in connected states. Its
  independent spec-only correction follows the user's new explicit decision;
  unrelated validation/order/accessibility assertions remain, with provider PDF
  and singleton/combined-shape assertions at1x/2x replacing obsolete equivalence.

- Independent native verifier confirmed the retained offset in the baseline
  fixture, while correctly limiting the evidence: that fixture directly presents
  NSPopover and does not prove first-ever-open clipping. Candidate native tests
  exercise the production AppDelegate opening path with injected offline managers.
- A suspected 2x raster harness defect was refuted using an independent18x18pt
  rectangle:1x ink8x18=144pixels;2x ink16x36=576pixels. The frozen popup test is
  unchanged. Corrected DesktopMenuTests uses rep.size without double scaling.
- Finder and verifier reproduced a pre-existing availability edge in P2: an
  empty preferred/first Codex bucket hides valid usage in another bucket; invalid
  primary101% hides valid secondary42%. Scoped repair retains preferred-codex,
  primary and original-bucket precedence while skipping unavailable/invalid
  values. Fresh tests froze before that helper change (SHA256
  3a2f68be8be7cd11e659525fbf82941d33b69c23d70a4d6a952851645561d5ee).
- Disposable height-cap mutation was rejected by the frozen test:
  viewport(content:nan,available:0.001) incorrectly returned250pt, exit132.
  Production cap was never mutated; the real candidate passes these expectations.

## Test method boundaries

- Geometry generated workload:4096 deterministic pairs, seed0x4C494D4954465545,
  plus explicit boundaries and monotonic sequences. Menu tests exercise provider
  permutations, transitions and actual PDF alpha shapes at1x/2x.
- Existing parser fuzzing and lifecycle fault tests remain in the full suite.
  Native offline tests exercise dynamic grow/shrink, reopen and page changes.
- New network/concurrency load tests are not applicable to these layout/model
  repairs: no network/service capacity or retry behavior changes. Existing bounded
  synthetic provider lifecycle tests cover those unchanged boundaries. No live
  accounts, provider load, authentication retries or telemetry are used in fixtures.
- Full configured Tests/run.sh and Tests/lint.sh passed the initial candidate.
  Final helper changes require the mandatory commit gate to rerun the full suite.

## Accepted scope extension: per-provider menu choices

The user first requested session priority, then a Settings choice, selected any
specific bucket/window, and clarified that the menu still needs just two numbers,
one per provider. This adds P5; it does not add more menu numbers or remove valid
dashboard buckets. Failure cases were presented before implementation.

### What can go wrong

- Invalid stored type, empty/control/oversized ID: use Automatic safely; well-formed
  temporarily unknown IDs stay saved. Invalid percentages never become choices.
- Concurrent refresh/settings changes: resolve against current options and current
  provider preference; update immediately without network calls or stale cached values.
- Repeated selection/relaunch: independent stable IDs persist; no duplicate observers
  or repeated side effects. Duplicate names and separator-containing bucket IDs stay distinct.
- Missing window/account switch: fall back to current available session/other window;
  no previous-account percentage. Restore the saved choice if that window reappears.
- Timeouts/retries: none added; preferences and selection are local. Provider timeout
  and authentication contracts remain unchanged, exercised by existing suites.
- Data limits/migration: validate ID size and values, preserve existing preferences,
  start new keys at Automatic, keep the Settings page scrollable after new controls.

Fresh spec-only acceptance is authored from the separate public-contract packet
by gpt-6.1-sol before gpt-6-astra implements this extension. Context isolation is
instructed; filesystem isolation remains unenforced. Real native popup tests and
the prior frozen geometry/rendering expectations remain applicable.

### Extension verification receipts

- The fresh preference acceptance froze before implementation: SHA256
  71e2adbe2a517274e33f04c6fbddca013decb490aabd176b15b3f82d76744965.
  It covers6064assertions and2000seeded option/transition cases(seed0x5eed),
  preference persistence/type/UTF8size validation and Codex IDs across reorder/rename.
- Previous automatic selection failed the session-priority baseline before the
  selector change. Final generic selector passes the frozen preference acceptance.
- A disposable mutation ignoring explicit saved choices fails the explicit
  weekly0% assertion(exit132). Production sources were never mutated.
- Popup-only native acceptance passed before this Settings extension: actual
  AppDelegate first open/three reopens at scroll0, real Settings/Back actions,
  bottom reachability, grow/shrink and secondary-only0% shrinking the viewport379pt.
  Removing the presentation token in a disposable copy fails reopening at391pt.
- Native geometry acceptance was corrected with concrete evidence: AppKit places
  the arrow4pt into the menu bar. All hosted content must be inside visibleFrame;
  native lower/horizontal bounds must fit visibleFrame and the full window must
  fit the physical screen. This checks content clipping without prohibiting the
  normal arrow. Offscreen/unshown default window frames are not passing evidence.
- The existing landing page was launched as a separate local preview at
  http://127.0.0.1:8000/ and visibly verified in the parent browser. No site edits
  or publication were requested or performed.
- Separate finder and verifier confirmed duplicate Codex names made distinct
  bucket/window choices indistinguishable. The verifier froze the integration
  regression before the repair (SHA256
  361b281199639b6083afa72f487a31c903b87cd08b4cc80f304e4348a6f5bce2).
  Duplicate names now include the stable bucket ID; unique names stay concise.
- Final immutable eight-source snapshot passed full-source integration and native
  acceptance, exit0. The verifier rechecked all source hashes against production.
  Native test SHA256
  5c82bd0caecc6ace34d6f725f26ceefed2f2c4d7f8307b525c12c95142659273.
  Actual menu transitions prove independent immediate choices, session default,
  missing-selection fallback/recovery including0%, invalid Claude data and
  disconnect clearing. Exactly one percentage per connected provider is asserted.
- Final native Settings inventory has exactly two provider pickers, each with
  Automatic plus that provider's current windows. Actual local Settings/Back
  actions, first open and three reopens, tall-content bottom reachability,
  grow/shrink, and secondary-only0% all pass. Test windows/status item were removed.
  These checks ran on the1440x900pt,2x desktop; physical smaller/multiple screens,
  native material appearance and live accounts remain unverified. Picker bindings
  were source-inspected; menu preference transitions were exercised through the
  actual shared model and AppDelegate callback.
- Full integration regression is part of Tests/run.sh. WindowServer-dependent
  acceptance is explicit in Tests/run-popup-native.sh, separate from headless CI;
  absence of a display is a failure/unverified result, never a silent pass.
- Final mandatory test/lint gate, clean universal build, exact-head hosted CI and
  installed-bundle checks are delivery steps; native fixture success alone does
  not establish them. Runtime commit-hook trust/activation and branch protections
  remain separate from the configuration file and local check results.
