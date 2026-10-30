# LimitFuel engineering checklist

Read with the active plan before engineering changes.

- macOS 12+, Intel and Apple Silicon; preserve menu bar and Carbon Cmd+U.
- Browser storage is read-only and scoped to claude.ai; no secret logging.
- Reject expired, malformed, ambiguous, oversized or unsupported credentials visibly.
- Chrome operations run off-main and coalesce; stale results cannot overwrite a
  manual save/clear or repopulate usage from a previous identity.
- HTTP requests have a 20-second timeout and refuse redirects. SQLite lock waits
  are bounded. Background Keychain reads never display prompts.
- Usage polls every minute, or every 12 seconds for five-hour windows above 90%
  until reset; Chrome rechecks hourly. Retries are bounded by timers.
- Codex uses its installed app-server and own sign-in. Only read-only account and
  rate-limit RPCs; 45-second child deadline, forced cleanup, 1MiB output and 64 buckets.
  Its start-up refreshes models online and can take about 20 seconds on a busy Mac.
- One copy owns the menu bar. A later process with the same bundle ID, by kernel
  start time, exits before AppKit starts; `--version` prints the version and exits.
- Bundle ID is com.innolope.limitfuel. Before any setting is read, absent keys are
  copied once from com.claude.usagebar (marker legacy_settings_migrated), never
  overwriting and never deleting the legacy domain; a legacy open-at-login choice
  registers the new identity's login item.
- Popup native and SwiftUI viewport sizes agree, fit the status-item screen, and
  reopen at the top. Tall content stays scrollable; unavailable usage rows are omitted.
- Menu bar shows one percentage per connected provider, with independent persisted
  bucket/window selection in Settings and a session-first default. Settings pickers list
  real windows only and show the one the menu bar uses; missing selections fall back
  without destroying the saved ID; current account data alone supplies usage.
  A separate global Used/Remaining toggle defaults to Remaining and applies to the menu
  bar and popup meters with identical rounding; raw used values still drive warning
  colors, polling and notifications.
- Menu bar uses the app mark only while disconnected, and connected provider
  marks with percentages otherwise. Preserve0%, accessible labels and1x/2x templates.
- Selected menu windows include centered reset text separated from the percentage
  by `·`, with one remaining-time unit: days, hours or rounded-up minutes. Unknown
  resets omit both countdown and separator. No countdown background is drawn.
  Choose units from actual duration: minutes below one hour, hours below one day.
  Advance hour numbers from minute 45 onward and day numbers from hour 12 onward.
- Keep validated menu values in memory through transient fetch/parse failures.
  Auth failure, clear or changed identity removes them; valid responses replace
  all windows. Last-known values never trigger notifications.
- Blur percentage/countdown text after10minutes without that provider's successful
  usage update, reaching1.2pt at30minutes. Logos/backgrounds stay sharp. Exact
  values and age remain accessible; Increase Contrast/Reduce Transparency disables
  blur. Redraw on existing timers/wake; no new permissions or network polls.
- Chrome sync failure does not imply a disconnected Claude API session. While usage
  works, Settings shows the connection and hides background sync failures; Detect stays
  available and shows failures the user started. Expose reconnect on actual auth failure.
- Status alerts use only posts at most 6 hours old: an incident's latest update, or a
  degraded component's last change when no fresh incident covers it. Expiry is silent.
- Codex account/updated after account/read is confirmed with one more account/read
  (same email keeps limits; new email re-reads them). Only a non-ChatGPT account is a
  sign-out. Writes to an exited app-server fail with EPIPE, never SIGPIPE.
- Claude optional weekly/model limits require valid current-response data. Missing
  or invalid values hide the row and clear prior values/resets; numeric0 remains valid.
  Overall Claude Weekly0 is hidden while session usage is positive; show both
  when both are0. Compare unrounded values and preserve explicit menu selections.
- Existing manual credentials/settings survive upgrades; manual save/clear stops
  hourly imports until explicitly enabled again.
- Test with disposable fixtures only, covering encryption, WAL and failure paths.
- Local checks: Tests/run.sh, Tests/lint.sh and universal app compile. No project
  checks existed initially; .codex/quality-gates.json configures the existing
  personal commit hook. Hosted CI and branch protections are separate gates.
- Diagnostics defaults on with a persistent immediate opt-out. Only fixed provider/error
  codes and sanitized crash stacks; no account details, credentials, raw logs or
  request data. Deduplicate until recovery, bound application errors to 20/hour,
  and use offline fake transport tests. Missing Sentry configuration is visible.
- Distribution defaults to Innolope Developer ID; secrets stay in Keychain/local
  ignored files. Packaging requires Accepted notarization, stapling and Gatekeeper;
  publish only fully verified artifacts with clean source provenance. No auto-retry.
- Undecided: release publication ownership, App Store sandbox design, hosted
  branch protections, nonstandard Chrome data directories and Chrome channels.
