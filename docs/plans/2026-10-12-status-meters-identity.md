# Status expiry, meter mode, picker, Codex race, Claude connection, app identity

User requests (2026-10-12):

1. A status.claude.com alert disappears 6 hours after it was posted.
2. Popup meters show the same Used/Remaining percentage as the menu bar.
3. The Settings window pickers show the window actually in use, not
   "Automatic (session preferred)".
4. Codex sometimes disappears from the menu bar for a minute.
5. Claude is connected, but Settings shows a "connect" Keychain message.
6. Leftovers from the ClaudeUsageBar predecessor: LimitFuel still uses upstream's
   bundle ID `com.claude.usagebar`, its login item is upstream's "ClaudeUsageBar"
   record, the repo keeps an `upstream` remote, and tests leave
   `ClaudeUsageBar.Acceptance.*` / `LimitFuel.*` preference files behind.

Tier: Standard (ships to users; no money/auth changes beyond reading existing
credentials). Acceptance tests are written from this spec by Codex, separately
from the implementation.

## Root causes found

- (4) Codex app-server emits its startup `account/updated` notification about
  0.4s after launch. When `account/read` answers first, the client treated the
  late startup notice as a sign-out (`.signIn`), which deletes the retained menu
  values until the next poll. Sentry: 59 `codex/signIn` events in 24h.
- (5) Each local rebuild changes the ad-hoc code signature, so the hourly
  background Keychain read of "Chrome Safe Storage" (which may never prompt)
  fails. The Settings card printed that background failure as if Claude were
  disconnected, although the stored session kept working. Sentry: 12
  `claude/signIn` events, all from this path.
- (1) The status card only drops incidents once Statuspage resolves them; the
  platform.claude.com incident stayed in "monitoring" for 4+ days.
- (2) Meters were specified to stay "used" (NFR); the request changes that.

## Contract

### A. Percentage display

```swift
extension MenuBarPercentageMode {
    func displayedPercent(used: Double) -> Int      // rounded .toNearestOrAwayFromZero
    func displayedFraction(used: Double) -> Double  // 0...1
    func accessibilityValue(used: Double) -> String // "79 percent remaining" / "21 percent used"
}
```

`.used` shows the raw used percentage; `.remaining` shows `100 - used`. The menu
bar entry percent and every popup meter (Claude session/weekly/model rows, Codex
windows) use these helpers, so both always show the same number. Warning colors
(amber from 70% used, red from 90% used), polling and notifications keep using
the raw used value. Extra-usage spend follows the mode too ("$15.00 left of
$20.00 · 75%" in remaining mode).

### B. Settings window pickers

```swift
enum MenuBarSelection {
    static func pickerOptions(provider: MenuBarProvider, options: [MenuBarWindowOption]) -> [MenuBarWindowOption]
    static func pickerSelectionID(provider: MenuBarProvider, options: [MenuBarWindowOption], selectionID: String?) -> String?
}
```

The picker lists only real windows. Its selected value is the window the menu bar
currently shows (`selectedOption(...)?.id`): the saved choice when available,
otherwise the session-first fallback. Displaying the fallback never overwrites a
saved choice that is temporarily missing. No windows → no picker value.

### C. Codex window labels

Single bucket named "codex" (limitName null falls back to the id): no bucket
prefix. 300 min → "Session · 5h"; 10080 min → "Weekly · 7d"; other durations →
"Primary · 2h" / "Secondary · 1d" ("Nd" if divisible by 1440, "Nh" by 60, else
"Nm"); unknown duration → "Primary" / "Secondary". Several buckets or another
name → "<name> · " prefix with the existing duplicate-name " (<id>)" suffix.
Option IDs are unchanged.

### D. Codex account-update race

- `account/updated` before the first `account/read` response: ignored.
- After it, with `authMode` "chatgpt", null or missing: finish the rate-limit
  read, then send one more `account/read`. Same email → return the first limits.
  Different email (still ChatGPT) → read rate limits again and return them with
  the new email. No ChatGPT account → `.signIn`. Another `account/updated`
  during this confirmation → `.protocolFailure`.
- After it, with another string `authMode` (e.g. "apikey") → `.signIn`.
- A child that exits early yields a typed non-signIn error; writes to a closed
  pipe never raise SIGPIPE.

### E. Status alert expiry

```swift
enum StatusFreshness {
    static let maximumAge: TimeInterval            // 6 hours
    static func isExpired(_ postedAt: Date?, now: Date) -> Bool
}
struct StatusSummary { indicator, description, incidents, components }
StatusManager(defaults:notify:)
StatusManager.decode(_ data: Data) -> StatusSummary?
StatusManager.apply(_ summary: StatusSummary, now: Date)
StatusManager.visibleIncidents(now:) / visibleAffectedComponents(now:) / effectiveIndicator(now:)
```

An incident's time is its latest posted update. It is visible while tracked and
at most 6 hours old (unknown time: visible). A non-operational tracked component
is hidden when no visible incident references it and either its own
`updated_at` is over 6 hours old, or (time unknown) an expired incident
references it. The indicator, card text and tint use only visible data.
Expiry is silent: a change to "none" caused by expiry sends no notification.

### F. Claude connection in Settings

```swift
UsageManager.connectionSummary: String?    // nil unless usage is working
UsageManager.settingsChromeMessage: String?
```

While Claude usage works, Settings shows "Connected via Chrome · <profile>",
"Connected via Chrome" or "Connected with a manual cookie", and hides background
Chrome sync failures and redundant success text. A failed Detect that the user
started is always shown. When usage is
not working (never fetched, or 401/403), the last Chrome message is shown with
the connect controls, as before.

### G. App identity

Bundle ID becomes `com.innolope.limitfuel`. Before any settings are read, the
app copies keys from `com.claude.usagebar` that are absent in its own domain,
once (`legacy_settings_migrated`), never overwriting and never deleting the
legacy domain (upstream ClaudeUsageBar may still use it). If the legacy domain
had `open_at_login`, the new identity registers its own login item.

```swift
enum LegacySettings {
    static let domain = "com.claude.usagebar"
    static let markerKey = "legacy_settings_migrated"
    @discardableResult static func migrate(into: UserDefaults, legacy: [String: Any]?) -> Bool
}
```

## What can go wrong

| Category | Failure | Mark | Where handled / test |
| --- | --- | --- | --- |
| Invalid input | Status incident without updates or dates | handle | unknown time stays visible (E) |
| Invalid input | Codex `account/updated` params missing/null/other type | handle | treated as "confirm" (D) |
| Invalid input | Raw percent outside 0...100 in a meter | handle | clamped; menu bar still rejects (A) |
| Concurrency | Startup `account/updated` races `account/read` | handle | confirmation read (D) |
| Concurrency | Account switch between reading account and limits | handle | re-read limits for new email (D) |
| Concurrency | Background Chrome check finishes after a manual save/clear | handle | existing revision guard |
| Idempotency | Migration runs on every launch | handle | marker key (G) |
| Idempotency | Expired alert flips indicator every fetch | handle | expiry is time-based and stable; silent (E) |
| Timeouts | Confirmation read hangs | handle | same 20s fetch deadline |
| Retries | Unchanged | n/a | existing timers |
| Partial failure | Child exits during confirmation | handle | typed non-signIn error, no SIGPIPE (D) |
| Partial failure | Legacy domain unreadable | handle | treated as empty, marker set (G) |
| Auth | Real Codex sign-out still clears values | handle | non-chatgpt account → `.signIn` (D) |
| Auth | Claude 401 after background Chrome failure | handle | connect controls + message return (F) |
| Auth | Keychain ACL lost after bundle ID change | handle | one interactive Detect; documented |
| Data limits | Long Codex bucket names in picker | defer | existing 200-char cap |
| Migrations | Saved window IDs, percentage mode, cookie, menu position survive ID change | handle | copy-all migration (G) |
| Migrations | Upstream "ClaudeUsageBar" login record remains | handle | unregistered once on this Mac |
| Migrations | Notification permission is per bundle ID | defer | NSUserNotification needs none for this app |
| Observability | Expiry hides a real, silent long outage | out of scope | user-requested rule; status page link kept |

## Release identity

Version resets to 1.0.0 (build 1) with the new bundle ID; the fork has no
published releases. The build stays one universal (arm64 + x86_64) app, so a
single `LimitFuel.dmg` serves Intel and Apple Silicon.

## Verification

- `Tests/run.sh` green on this branch and on the combination with PR #4;
  `Tests/run-popup-native.sh` and `Tests/lint.sh` green.
- Seven deliberate mutations (late Codex update as sign-out, no expiry, noisy
  expiry, visible background Chrome failure, mode-blind meters, picker showing a
  missing saved ID, overwriting migration) each turned the matching suite red.
- Spec test fixture correction: the status tests assumed an unnamed component
  starts untracked; the app tracks every non-Government component on first fetch,
  so the fixture now sets `tracked_component_ids` explicitly.
- Test suites are named `LimitFuel.<Kind>.<UUID>`; `Tests/run.sh` removes the
  plists a run creates (cfprefsd rewrites them about two seconds after exit).
