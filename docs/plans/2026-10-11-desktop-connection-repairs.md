# Desktop connection repairs

Source baseline: ce7b0dd36936454d366cb76d6b295705982c2257, Innolope/LimitFuel.
The user launched the installed app and reported an unrelated menu-bar glyph,
undetected Codex login, and a Chrome Keychain prompt followed by no connection.
They also asked whether Sentry integration makes sense.

Runtime Plan mode cannot be enabled in this client. This persisted plan is the
equivalent, saved before production changes. Work uses an isolated worktree to
avoid another process changing the shared app/build output.

## Acceptance criteria

- D1: The menu bar always shows one monochrome LED Segments app mark followed by
  connected-provider percentages only, in Claude then Codex order. Hide unavailable
  percentages, retain provider names in accessibility/tooltip text, and keep the
  popup reachable with neither connected. User explicitly chose this layout.
- D2: An already ChatGPT-authenticated Codex installation is detected despite
  ordinary startup account notifications. Account changes after the account
  snapshot still invalidate the fetch, so usage never crosses account identities.
  API-key/no-login/unsupported server requests remain explicit errors.
- D3: A valid Claude session is discoverable alongside ordinary browser cookies
  containing JSON, quoted values or Unicode. Unrelated cookie values must never
  corrupt an HTTP header or cause valid authentication to disappear. Invalid,
  ambiguous, expired, oversized or unsupported authentication cookies still fail.
- D4: Background detection never prompts; explicit detection explains Chrome
  Keychain access, shows progress, shows failure/recovery and exposes profile
  choices in the same UI where Detect was clicked. Never ask for a password inside
  LimitFuel or bypass macOS Keychain authorization.
- D5: Existing manual sessions, hourly discovery, request coalescing, stale-result
  invalidation and 60/12-second polling behavior remain intact.
- D6: Sentry crash and connection-error reporting is enabled by default, with a
  persistent Settings switch that stops reporting immediately and across relaunch.
  User explicitly requested this default. No cookies, tokens, account emails,
  organization IDs, raw request headers, bodies or application logs enter reports.
  Use the Innolope organization; report only fixed provider/error codes, version
  and sanitized crash stacks. Deduplicate persistent errors until recovery and
  bound application error reports to 20/hour; telemetry never blocks connection
  recovery and tests use a fake transport. No auth token enters source or builds.

## What can go wrong

| Category | Trigger and expected behavior | Test / decision |
| --- | --- | --- |
| Invalid inputs | Ordinary auxiliary cookie syntax must not invalidate a valid session; malformed credentials must fail | Synthetic SQLite/encryption cases; accepted repair |
| Concurrency | Double Detect, sign-out/manual save during import, account changes during RPC | Preserve coalescing/revision guards; startup-vs-post-account notification fixtures |
| Idempotency | Repeated detection/refresh cannot duplicate timers or alerts | Existing lifecycle suite plus repeated startup notification fixture |
| Timeouts | Keychain denial, locked SQLite, hung app-server/network | No silent spin; retain existing bounded SQLite/HTTP/child deadlines; explanatory state |
| Retries | Expired login or transient transport failure | Explicit Refresh/Detect recovery and existing timer budgets; no automatic login loops |
| Partial failure | Cookie decrypt error, RPC EOF, multiple profiles, missing icon asset | No fabricated connection/usage; expose failure/profile choice; deterministic icon fallback |
| Auth | Chrome consent, API-key Codex, initial auth notice, actual account change | Respect OS consent; no raw secrets in logs; session-only acceptance and stale-result rejection |
| Data limits | Oversized cookie/blob/RPC output, huge profile/cookie counts | Preserve bounded reads/headers/1MiB RPC/64 buckets and existing negative tests |
| Migrations | Existing manual cookie/settings and installed app replacement | Retain bundle/settings keys; publish PR and preserve installed app for rollback |

Technical failure cases above were presented in chat before implementation, using
the user's reported bugs and prior accepted security/scheduling behavior. The user
explicitly chose app-icon-plus-percentages and Sentry on by default with opt-out.

## Evidence and milestones

1. Inspect safe metadata only. Actual Chrome DB version24 has valid, unexpired
   sessionKey plus many non-auth cookies. A live CLI 0.160.1 probe emitted
   account/updated before account/read, returned a ChatGPT account and usage limits.
   It printed only protocol methods/status; no account or credential values.
2. Freeze independent tests from the accepted subset before changing production.
   A fresh different-model author gets only public contracts and synthetic fixtures;
   filesystem isolation is instructed, not enforced.
3. Implement core repairs, then add any explicitly chosen layout/telemetry scope.
4. Run configured tests/lint, visual light/dark previews, universal build, separate
   finder/verifier and a disposable regression mutant. No load testing against live
   accounts; parser/property breadth uses fixed-seed offline fixtures.
5. Publish a PR assigned to innolope-dev; verify exact-head hosted checks. Rebuild
   from committed clean source and replace the installed app with a retained rollback
   copy. Do not automatically dismiss system consent or upload private diagnostics.

## Rollback and unresolved items

Revert this PR or restore the prior installed bundle. Preserve user settings and
credentials. Pending: real interactive Keychain approval verification, provider
acceptance, native UI acceptance and Sentry receipt verification.

## Implementation progress

- Frozen spec-only tests reproduced baseline Chrome encryption failure with an
  otherwise valid session, Codex sign-in failure on startup account updates, and
  differing menu icon pixels across provider states. Fixture-only adaptations use
  the writable temp root and a real Python interpreter via PATH; deadlines and
  assertions were preserved.
- Core implementation processes sessionKey first, rejects malformed names and
  credentials, skips unsafe auxiliary values, probes for eligible auth before
  Keychain access, and distinguishes startup from established-account updates.
- Sentry provisioning returned HTTP403: Innolope disables this feature for the
  connected member. A public DSN/admin-created project was requested. Reporting
  must display unavailable until configured; no unrelated DSN is reused.
- The user subsequently configured the dedicated public DSN, organization and
  project in GitHub production Variables. The DSN was validated and copied into
  the client configuration. No Sentry auth token is used or included in source.
- Root handles core/UI/build wiring; gpt-6-astra implements Sentry against frozen
  gpt-6.1-sol tests. Review is read-only. Fresh reviewer creation hit the client
  thread limit, so a separate existing finder context is reused. Filesystem
  isolation remains instructed.
- The strict menu gate exposed width-dependent downsampling of implicit Retina
  lockFocus snapshots. Independent forced2x reproduction confirmed identical
  source pixels but different1x edge alpha. The rendering now uses a vector drawing
  handler at the destination resolution; all original geometry and assertions stay.
