# Claude connection and optional usage availability

User evidence: valid Claude session18% plus a Chrome Safe Storage warning and
connection buttons; an unwanted overall Weekly0% meter. The user asks to hide
weekly limits when unavailable and requests five menu-bar time-window designs
for selection before implementation. Existing PR3 remains open on e59f6c1.
Runtime Plan mode is unavailable; this equivalent plan precedes production edits.

## Acceptance

- C1: Valid Claude usage does not show Chrome reconnect controls on the dashboard,
  even if background cookie sync is denied or still running. Settings retains
  explicit Chrome sync/profile/manual controls. A sync failure does not invalidate
  working API credentials or start another interactive Keychain read.
- C2: Disconnected/unavailable Claude usage has connection controls. A real
  usage-endpoint401/403 must expose recovery even after prior successful usage;
  a later valid response recovers. Network/server failures do not become fake
  authentication failures. No auth parser/polling/cookie storage changes.
- C3: Overall Weekly is shown only when the current response reports valid
  seven_day.utilization. Absent/null/malformed/boolean/out-of-range values are
  unavailable; numeric0 is available. Weekly state and reset timestamp cannot
  leak from a previous response/account. Optional model limits follow the same
  validity principle; preserve the existing idle-Fable visibility rule.
- C4: Keep one menu percentage per provider and the existing independent window
  settings. Missing selections fall back and recover. Menu duration styling stays
  unchanged until the user selects and approves a design.
- C5: Produce exactly five distinct menu-bar mockups, showing Claude18% over5h
  and Codex15% over7d, with selectable time windows to check alternate states.
  No live data, website change or release publication is part of the mockups.

## What can go wrong

| Category | Trigger and invariant | Verification / decision |
| --- | --- | --- |
| Invalid input | Missing/null/invalid optional usage must not invent0%; valid0 remains visible | Frozen parser/visibility acceptance; requested repair |
| Concurrency | Background Chrome import overlaps valid API response; sync state cannot override connection state | All sync-state permutations plus existing lifecycle races |
| Idempotency | Duplicate response, detect or presentation must not create reads or erase saved choices | Repeat parse and existing coalescing tests |
| Timeouts | Existing20s provider timeout remains; no UI-triggered request | Offline URLProtocol timeout/recovery cases |
| Retries | No new retries or interactive Keychain reads | Deny-network fixture, existing reader lifecycle suite |
| Partial failure | Chrome locked with working cookie, or optional weekly absent with session present | Dashboard predicate + native view inventory |
| Auth |401/403 after success must expose reconnect; valid response restores connected view | Synthetic HTTP fixture; existing stale-response cancellation |
| Data limits | Existing bounded parsers retained; long warning and Settings stay scrollable | Existing native popup suite plus scoped fixture |
| Migrations | No preference reset; window availability changes across accounts/plans | Present→missing→zero and clear/new-account sequences |

Failure cases were presented in chat before implementation. Missing vs numeric0
is evidence-based availability, not an inference about plan names. New visual
styling is explicitly pending user choice; no policy decision is inferred from
silence. API-provided numeric0 cannot safely be treated as no weekly limit.

## Work and evidence

1. Fresh spec-only acceptance author gpt-6.1-sol, no inherited context, against
   public contracts only; distinct implementer gpt-6-astra after tests freeze.
   Shared filesystem is not enforced isolation. Root owns visualization/wiring.
2. Reproduce baseline defects before production edits, then implement C1-C4.
3. Verify parsing/HTTP recovery, independent source review and a disposable mutant
   that always exposes Weekly. No live provider load or credentials in tests.
4. Run configured tests/lint, update PR3 once, build/install clean universal app
   with rollback, verify exact-head CI. No merge, notarization or store submission.
5. Present five designs; defer menu style implementation until user approval.

## Assumptions and unresolved items

- A valid numeric weekly field is authoritative, even at0%; absence/invalidity
  means unavailable. If the provider returns misleading valid0, subscription
  absence cannot be inferred from that value alone.
- Physical display coverage remains the current macOS desktop; network/load
  testing is not applicable to local presentation changes. Existing fault tests
  exercise unchanged external boundaries. Native material appearance is not
  inferred from an offscreen capture.

## Verification receipts

- Before implementation, fresh test author froze Acceptance.swift SHA256
  884bd5bbd77303398b91354d769c74e9eedbba174d3847f41ea44ed791bdb60c
  and existing-API Baseline.swift SHA256
  07c9d0de36598047a9fc533302bf679b7a497f96e2934c419b76fa769bd0a45c.
  Root preserved the eight baseline sources before the implementer started.
  Baseline compile passed; execution failed15of21assertions in9sequences, proving
  stale reset/model availability failures without relying on missing new APIs.
- Focused final full-source acceptance passed:277cases,2131assertions,0failures;
  optional-data breadth256cases, seed0xCA11AB1E20261011. Frozen hashes unchanged.
  No real network, Chrome account or Keychain reads were used.
- The actual dashboard gates connection controls on usage state and Weekly on
  current availability. Settings still includes chromeConnectionControls directly.
  The repair exposes recovery on usage401/403 and retains the cookie for retries.
- Five menu-bar alternatives are prepared separately for user selection. No
  proposed duration styling has been added to production.
- Disposable mutation forcing missing weekly data to available compiled but was
  rejected by196of2131frozen assertions(exit1). Production was never mutated.
- Native acceptance passed against an immutable eight-source snapshot. Actual
  connected dashboard document height246pt stays unchanged across all Chrome
  attention/detection combinations; valid weekly0% adds a row to299pt and missing
  weekly restores246pt. Actual Settings navigation renders1082pt; disconnect
  renders270pt recovery content. No network/Keychain guards fired; cleanup completed.
  Test SHA25647347e80edfc43ff703f4e450158bf8617cf3a8c395798b00a81bd40ac343cc1;
  compiled LimitFuel.swift SHA256
  c3b01258fce4c10b5804ef6eb734ff2eeb1f0cef7ae4bc5e5972080a6308bbc5.
- SwiftUI Chrome button/text accessibility inventory is unavailable in the
  fixture. Presentation evidence combines actual native geometry/navigation with
  immutable source checks of dashboard guards and Settings control call chains;
  it does not claim direct Chrome-button accessibility or live-account verification.
  Reproduce explicitly with CLAUDE_TEST_SOURCE=app/LimitFuel.swift and
  POPUP_TEST_SOURCE=Tests/ClaudeNativePresentationTests.swift passed to
  `sh Tests/run-popup-native.sh` (use absolute paths and a writable output directory).
- Final delivery still requires the mandatory configured test/lint gate, clean
  universal build, verified installation/rollback and exact-head hosted checks.

## User revision: zero-usage Weekly heuristic

The user explicitly requests: session0 and weekly0 shows both; session>0 and
weekly0 hides overall Claude Weekly. Weekly>0 is shown. Missing/invalid data
remains unavailable and hidden. Decimal positives count before display rounding.
This is presentation, not proof that a subscription has no weekly limit. Valid
weekly0 remains selectable in menu-bar Settings; other model/provider limits
are unchanged. This supersedes C3's numeric0 dashboard visibility expectation.

What can go wrong: fractional values round to zero, a reset fails to restore a
row, missing/invalid data is confused with real zero, or a presentation rule
erases the saved menu selection. A fresh spec-only author freezes matrix and
transition tests before the distinct implementation model edits production.
The remaining failure-list categories above retain their accepted behavior:
this local predicate adds no concurrent work, I/O, retries, auth or migration.

The first mandatory commit gate failed in the unchanged Codex subprocess
fixture: no readiness markers within6seconds, fetch still pending. Transcript
/private/tmp/limitfuel-checks.x4mC1U retained. Host load was63 on8logicalCPUs;
this is correlation, not an established cause. Before retry, run the unchanged
Codex assertions serially with no other task-owned compiler/fixtures active.
No timeouts or assertions will be relaxed. Commit/install remain pending.

Unchanged Codex assertions passed serially:219checks, seed0xC0D3/budget128,
including the same readiness and cleanup deadlines. The diagnostic ran after
other task-owned compilers/fixtures finished; this is the changed execution
condition for one full-gate retry, without asserting a proven host-load cause.
Diagnostic receipt is .limitfuel-install/codex-readiness-diagnostic/run.log
outside Git. The original failure remains recorded above.

Fresh zero-rule spec-only author gpt-6.1-sol froze tests SHA256
ceb9e8fa410fea40b3c961f3047e9bef87421bda46394f158b291c0730849253:
81valid matrix pairs,24invalid inputs primed from shown state,3transition cycles,
reset/reparse, raw availability and menu percent. Distinct implementer gpt-6-astra
edits production only. Existing native assertion is corrected by the test author
to match the user's changed policy: positive session/weekly0 hides, both0 shows,
positive fractional Weekly shows. Auth/geometry assertions remain intact.

Before implementing the revised rule, an immutable eight-source baseline plus
an adapter exposing the existing dashboard guard (`hasWeeklyUsage`) compiled.
Frozen rule tests rejected that behavior at session0.000001/weekly0, proving
a behavioral failure at the unrounded boundary (not a missing-API compile error).
The first execution attempt preceded binary completion and returned127; it is
not counted as test evidence. The completed binary's failure transcript is
.limitfuel-install/claude-weekly-rule-baseline/run.log outside Git.

Revised native acceptance passed against immutable source SHA256
2fb9a2bca7d6d9b540de2d48566baa6ea7271ac8f4eef4ca3a444f1f675b22e0
and revised test SHA256
ba4940e974bb82ff527e807a9cd64c39dc79ca11bac31d8174d2d4eaa49586bc.
Actual popup covers absent→positive-session/weekly0→both0→positive-session/weekly0
→fractional-weekly→missing, plus unchanged Chrome sync permutations, Settings
navigation and disconnected recovery. Native receipt is
.limitfuel-install/claude-weekly-rule-native/native.log. The previously disclosed
SwiftUI Chrome AX inventory limitation remains; no live account was queried.

The single justified full-gate retry also failed the unchanged Codex descendant
readiness assertion after6.0025seconds, with fetch still pending; transcript
/private/tmp/limitfuel-checks.x3UAiB retained. No commit, push, build or install
occurred. Native Claude presentation checks passed separately; the complete
configured suite is not passing. The user then prioritized seeing the designs
and requested ten more graphic concepts; these are independent previews, not
production menu styling. Monthly is an illustrative preview, not a claim that
the provider API supplies a monthly limit. Existing app remains1.3.6(11).
