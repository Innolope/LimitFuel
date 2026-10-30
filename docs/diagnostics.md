# Optional error reporting

LimitFuel defaults `diagnosticsEnabled` to true and retains the choice in its
existing UserDefaults domain. Settings can disable it immediately and across
relaunch. An empty `app/Diagnostics.plist` DSN means reporting is unavailable;
the setting stays on but the SDK does not start. Settings shows that distinction.

The dedicated `limitfuel` project in the Innolope Sentry organization uses the
public DSN supplied in the GitHub production environment. Only that public DSN
is included in `app/Diagnostics.plist`; no auth token is bundled. `SENTRY_ORG`
and `SENTRY_PROJECT` are public metadata. A Sentry auth token is needed only if
a future CI job uploads debug symbols or manages releases. Store such a token in
GitHub Secrets; never put it in Variables, source, configuration, or a build.
The configured endpoint must use HTTPS and the official Sentry ingestion host.

## Payload and limits

Application failures enter through enums only: Claude or Codex, and unavailable,
signIn, protocolFailure, timeout, or invalidData. Only possible defects are sent:

- `signIn` and `unavailable` are never sent. They are account or setup states the
  app already shows, such as a signed-out provider, a missing Codex install or a
  Chrome Keychain grant the background recheck may not prompt for.
- `invalidData` is sent on first occurrence: a response arrived but its shape is
  not one the app understands.
- `timeout` and `protocolFailure` are sent only for a lasting outage: at least 10
  failures in a row spanning at least an hour with no successful poll between
  them. Failures while the Mac has no network route neither count nor break the
  run, so sleep, wake, offline use and one-off server or Codex start-up delays
  never report.

Each provider/error pair is
deduplicated until that provider recovers. A process-wide rolling window permits
20 application report attempts per hour; turning reporting off/on and provider
recovery do not reset this budget. The budget resets when the process exits.
Transport errors are ignored without retry; transport never blocks the policy.

`beforeSend` reconstructs an allowlisted SDK event. It keeps the event UUID,
timestamp, app version, fixed tags, or bounded native stacks with sanitized symbols
and hexadecimal addresses. Crash exception reasons, user/request objects, raw
errors, extras, contexts, breadcrumbs, dynamic messages, registers, frame variables,
source lines, file paths, thread names, debug image metadata and arbitrary tags are
discarded. Unknown crash types become `NativeCrash`. No application log, cookie,
token, email, provider organization identifier, response body or header enters the
reporting API. Native symbols are static compiler symbols, never user strings.

Debug image metadata is deliberately excluded. Frames already containing native
function symbols remain useful; address-only frames will lack the metadata needed
for full server symbolication. No source maps or debug symbols are uploaded by
the build. Frames/exceptions/threads are bounded to 256/8/32 per event.

SDK logging, metrics, session tracking, client reports, memory introspection,
network capture, breadcrumbs, performance tracing, profiling, MetricKit,
Spotlight and swizzling are disabled. Replay is not available in this macOS SDK
slice. The macOS-specific NSApplication exception swizzles remain disabled along
with other swizzling; ordinary native crash handlers are enabled.

## Opt-out and cache lifecycle

Sentry Cocoa 9.30.1 `SentryClientInternal.close` calls `flush`, including when its
shutdown timeout is zero. Therefore LimitFuel first invalidates and cancels its
dedicated ephemeral URLSession. It then closes the SDK on main, uninstalling crash
integrations, and removes only its dedicated diagnostics cache. No application
flush API is called. Any flush attempted internally has an invalidated transport.
Bytes already delivered before the switch cannot be recalled.

Every opt-out rotates the cache generation. Re-enabling gets a new session and
cache directory, so late writes by a cancelled generation are never replayed.
The generation marker is revoked before dispatching teardown to main; a newer
enable must consume any pending purge even when it overtakes worker opt-out.
An enabled relaunch may process its own previous crash reports. Old callback and
policy generations cannot send after off/on. Requests have 10-second request and
15-second resource deadlines, no cookies/credentials/cache, and reject redirects.

Source inspection used these pinned SDK files:

- [SentryClient.m](https://github.com/getsentry/sentry-cocoa/blob/9.30.1/Sources/Sentry/SentryClient.m)
- [SentrySDKInternal.m](https://github.com/getsentry/sentry-cocoa/blob/9.30.1/Sources/Sentry/SentrySDKInternal.m)
- [SentryCrashIntegration.swift](https://github.com/getsentry/sentry-cocoa/blob/9.30.1/Sources/Swift/Integrations/SentryCrash/SentryCrashIntegration.swift)
- [Options.swift](https://github.com/getsentry/sentry-cocoa/blob/9.30.1/Sources/Swift/Options.swift)

## Build and offline verification

`python3 app/scripts/fetch_sentry.py` downloads the official static 9.30.1 release
archive, checks SHA-256
`bf6bc2308b9f1d11cc0d5ad5a324dbe300afa37c8391809ecb6dd3758fa728e2`, and extracts
only the universal macOS slice. It uses a bounded lock/download/extraction,
preserves framework symlinks through `ditto`, and validates cached file sizes and
CRCs against the verified archive. The pinned MIT license is verified separately.
Downloads live under ignored `app/.dependencies` and are reusable offline.
`--offline` verifies the complete cache and fails on missing/corrupt archive,
license or extracted files without downloading or repairing anything. Run the
normal fetcher once before the mandatory offline test suite on a fresh clone.

Compile `AppDiagnostics.swift` and `SentryDiagnostics.swift` with
`-F <printed-framework-directory> -framework Sentry -Xlinker -ObjC`. It is a
static library, so no framework binary is embedded. Copy Diagnostics.plist and
the MIT license into app Resources, and preserve the SDK privacy manifest in a
resource bundle under Resources.

The regular runner compiles `AppDiagnostics.swift` alone with
`-D ACCEPTANCE_TESTS`. The focused SDK privacy suite compiles the two diagnostics
sources plus `Tests/SentryPrivacyTests.swift` with the same flag and SDK linker
flags. Under that flag, default SDK startup and capture are disabled even when
the real SDK is linked. Tests inject SDK lifecycle closures and a URLProtocol
that intercepts all requests; test caches use unique `/private/tmp` paths.

Verified offline: frozen policy tests (defaults, persistence, deduplication,
recovery, cap, timeout and throwing transport), every fixed provider/error pair,
synthetic secret stripping and malformed-address cases, cancellation of a stalled
mock upload, cache deletion/rotation, missing DSN behavior, old callback rejection,
and queued policy-event invalidation. The suite also starts the real SDK against
the intercepting URLProtocol, injects synthetic secrets into scope and a crash-like
event, and checks the actual decompressed HTTP envelope after every SDK processor.
It verifies real start/close/re-enable/close, and the independently reproduced
worker-off/main-on race, including persisted epoch revocation before teardown.
All 2 x 5 provider/error combinations and four malformed-address fixtures are
enumerated; no random seed is used. Network waits are bounded to five seconds and
envelope size to 1 MiB. Load testing and broad fuzzing are unnecessary for this
fixed-enum low-volume boundary; no live service load is generated.

A disposable mutant that restored `event.extra` failed with
`synthetic secret leaked`; the unmodified privacy suite passed afterward.
The fetcher also rejected missing/corrupt offline cache with subprocess execution
replaced by a failing sentinel, establishing no attempted network process.

No live DSN receipt, deliberate real app
crash, Sentry project settings or native device acceptance is established by those
tests. Test author independence applies to the frozen policy suite; the focused
SDK privacy suite was written by the implementation agent.
