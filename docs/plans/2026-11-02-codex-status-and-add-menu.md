# Codex service status and the popup's add-account menu

## Add-account menu

A `+` glass button left of Refresh in the popup header opens a menu:

- **Sign In to Claude…** opens the sign-in window (`ClaudeSignInWindowController.show`).
- **Add from Chrome** opens Settings and starts `detectChromeSessions(interactive: true)`, so the
  profile choices and messages appear in the accounts card where they already live. Disabled while
  a detection runs.
- **Manual Cookie…** opens Settings with the cookie field shown.

## Codex status

OpenAI's status page (incident.io) has a Codex group: Codex Web, Codex API, CLI, VS Code extension;
"Codex in ChatGPT Desktop" sits in the ChatGPT group. Its Statuspage-style `/api/v2/summary.json`
lists none of the Codex group and no incidents, so LimitFuel reads the documented widget API,
`https://status.openai.com/api/v1/summary` (unauthenticated, CDN-cached 30 s; resolved incidents drop
out). Shape: `ongoing_incidents[]` and `in_progress_maintenances[]`, each with `id`, `name`,
`status`, `url`, `last_update_at` (ISO 8601 UTC), `last_update_message`, `affected_components[]`
(`id`, `name`, optional `group_name`, `current_status`: `operational`, `degraded_performance`,
`partial_outage`, `full_outage`, `under_maintenance`).

### `StatusSource` (app/LimitFuel.swift)

```swift
struct StatusSource {
    let name: String            // "Claude" / "Codex": card text and notification titles
    let endpoint: URL
    let pageURL: URL            // "Open status page"
    let keyPrefix: String       // UserDefaults key prefix: "" for Claude, "codex_" for Codex
    let tracksAllComponents: Bool
    let decode: (Data) -> StatusSummary?
    static let claude: StatusSource   // status.claude.com summary.json, StatusManager.decode, existing keys
    static let codex: StatusSource    // status.openai.com/api/v1/summary, StatusManager.decodeCodex
}
```

`StatusManager.init(source: StatusSource = .claude, defaults:notify:)`. Claude behaviour and its
UserDefaults keys (`tracked_component_ids`, `last_effective_indicator`) are unchanged. The Codex
manager uses `codex_last_effective_indicator`, never reads or writes `tracked_component_ids`, and
shares the `status_notifications_enabled` switch.

### `StatusManager.decodeCodex(_ data: Data) -> StatusSummary?`

- nil unless the data is a JSON object whose `ongoing_incidents` is an array. A missing
  `in_progress_maintenances` counts as empty.
- A component is Codex's when its `group_name` equals "Codex" (case-insensitive) or its `name`
  contains "Codex" (case-insensitive).
- Each ongoing incident with at least one Codex component becomes a `StatusIncident`: `id`, `name`,
  `status`, `latestUpdate` = `last_update_message` (or ""), `updatedAt` = `last_update_at` (ISO 8601,
  with or without fractional seconds), `componentIds` = its Codex component ids only. Incidents
  without a Codex component are dropped; entries missing `id`, `name` or `status` are skipped.
- Each in-progress maintenance with a Codex component becomes a `StatusIncident` the same way, with
  status `"maintenance"`.
- `components`: one `StatusComponent` per distinct Codex component id across the kept entries:
  its `name`; `status` = the worst `current_status` listed for it, with `full_outage` mapped to
  `major_outage` (severity: operational 0; degraded_performance, under_maintenance 1;
  partial_outage 2; major_outage 3; unknown values count as operational); `updatedAt` = the latest
  `last_update_at` of the entries that list it.
- `indicator`: worst component severity 0/1/2/3 → `none`/`minor`/`major`/`critical`.
  `description`: `All systems operational`, or the worst status as `Degraded performance`,
  `Under maintenance`, `Partial outage`, `Major outage`.

### Manager with `tracksAllComponents`

- `isTracked` is always true; `toggleComponent` does nothing.
- `apply` always replaces `allComponents`, even with an empty list, so a resolved incident clears
  its components. (Claude keeps its component list when a fetch returns none.)
- Visibility, six-hour expiry and transition notifications work as for Claude.
- Notifications: "<name> is back online" / "All systems operational", and
  "<name> status: <description>" / "Visit <page host> for details". Claude's text stays
  "Claude is back online", "Claude status: …", "Visit status.claude.com for details".

### Popup

The service status card has a row per provider, Claude then Codex, each with its own Details. The
card is tinted when either has an issue. Codex's row appears after its first successful fetch.
Both refresh every minute and on Refresh.

## Failure list

| # | Failure | Handling |
|---|---------|----------|
| 1 | OpenAI page down, 404 or non-JSON | Decode nil; last good status kept; row stays hidden until a fetch succeeds. |
| 2 | Incident affects only other OpenAI products | Dropped; Codex row stays operational. |
| 3 | Incident lists Codex and other components | Kept; only Codex components shown. |
| 4 | Incident resolves | Drops out of the feed; components cleared on the next fetch; recovery notification. |
| 5 | Incident left open for hours without a post | Hidden after six hours, silently, like Claude's. |
| 6 | Same component in two incidents | Worst status, latest update time. |
| 7 | `full_outage` (incident.io) vs `major_outage` (Statuspage) | Mapped to `major_outage`. |
| 8 | Maintenance in progress on Codex | Shown as minor, status "maintenance". |
| 9 | Codex manager and Claude settings | Separate keys; Claude's tracked services untouched. |
| 10 | Add from Chrome finds nothing or several profiles | Shown in Settings, which the menu opens. |

## Verification (2026-11-02)

- `Tests/CodexStatusTests.swift`, written from this contract by a separate Codex task, passes.
  Not clearing a resolved incident's components, or ignoring `group_name`, fails it. The only
  change to it was passing component ids to `isTracked`/`toggleComponent`, as the existing API
  takes them.
- `ClaudeNativePresentationTests` checks the header offers the three add actions and that the menu
  keeps titles and enabled states and runs the chosen action.
- The real popover, captured on screen in light and dark with a synthetic Codex incident: the `+`
  menu opens below its button with the three items, and the status card shows Claude's row and
  Codex's row with its incident details.
- The offline renderer (`Tests/RenderPreview.swift`) cannot draw macOS 26 glass: it garbles the
  glow and renders a tinted card's page blank, so on-screen captures are the visual check.
