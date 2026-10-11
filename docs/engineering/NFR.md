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
  rate-limit RPCs; 20-second child deadline, forced cleanup, 1MiB output and 64 buckets.
- LimitFuel retains com.claude.usagebar for settings migration.
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
