# Chrome session detection and refresh

User requested removal of Accessibility requests and donation links, automatic
Chrome cookie detection, usage polling every 60 seconds and cookie rechecks every
3600 seconds. Keep Carbon Cmd+U, manual cookie fallback and existing settings.
This client cannot switch into Plan mode; this persisted plan is the equivalent.

## Acceptance criteria

- A1: No Accessibility checks, prompt or System Settings link; retain Carbon hotkey.
- A2: No donation buttons/links in the app or landing page.
- A3: Detect Chrome on launch, hourly while enabled and on demand, off the UI thread.
  Poll usage every minute; retain the separate three-hour app-update interval.
- A4: Read only Claude cookies from standard Chrome profiles and both Cookies and
  Network/Cookies layouts. Observe committed SQLite WAL changes. Ignore expired,
  unrelated-domain, partitioned and non-API-path cookies.
- A5: Support macOS v10 encryption and database v24 domain hash binding. Corruption,
  unknown encryption, locked/inaccessible databases, Keychain denial, absent Chrome
  and missing login must produce actionable errors and preserve the stored session.
- A6: Require a valid sessionKey; bound cookie counts and header size and reject
  header injection and ambiguous sessions. Never log credentials or encryption keys.
- A7: Pin the chosen Chrome profile, import changed cookies and fetch immediately.
  Coalesce overlaps and discard stale requests/imports after save, selection or clear.
- A8: Open the usage page explicitly in Chrome and report unavailable Chrome.
  Manual fallback remains usable; never prefill it with a saved secret or truncation.
- A9: Preserve legacy manual cookies/settings. No Automation, Accessibility,
  remote debugging, browser flags or extension required.

## What can go wrong

| Category | Trigger and impact | Expected behavior and test | Status |
|---|---|---|---|
| Invalid input | Empty, injection, corrupt DB or ciphertext | Reject without replacing saved session; parser/SQLite/crypto fixtures | Technical default |
| Concurrency | Timer/manual overlap, clear during import/fetch | One active operation; revision discards stale result; fault fixtures | Technical default |
| Idempotency | Repeated clicks, unchanged cookie | No duplicate import/save or extra fetch; state tests | Technical default |
| Timeouts | SQLite lock, slow HTTP, Keychain prompt | 250ms SQLite busy timeout, 20s HTTP, background Keychain never prompts; lock/fault fixtures | Technical default |
| Retries | Network/storage unavailable | No tight retry; next hourly/manual import or minute usage check; failure retained | Technical default |
| Partial failure | Some profiles unreadable | Discovery reports incomplete results rather than guessing a unique identity; pinned profile refresh independent | Technical default |
| Auth | Expiry, logout, multiple profiles, redirects | No profile mixing or credential redirects; expiry/profile/fault fixtures | Multiple-profile policy presented for user edits |
| Data limits | Excess rows/oversized value | 128 relevant cookies, 16KiB header, bounded ciphertext; boundary/fuzz fixtures | Technical default |
| Migrations | Legacy defaults or future Chrome format | Manual fallback remains; unsupported format is visible; legacy fixtures | Required compatibility |

Proposed profile policy: use the only signed-in profile automatically, ask for a
choice when several exist, and pin subsequent rechecks to that choice. The user
was asked for edits before production code; elapsed time is not acceptance.
Manual save disables automatic replacement until explicit Chrome detection.
Clear disables hourly import and invalidates pending work until explicitly enabled.

## Milestones and verification

1. Save spec, derive positive/negative acceptance tests before production changes.
2. Implement isolated Chrome reader, session lifecycle, schedules and UI.
3. Run tests, deterministic parser fuzz, SQLite WAL/lock fixtures, stale-result
   faults and a deliberate failing variant; compile both architectures.
4. Inspect UI where possible, defect preflight, docs and draft PR if access permits.

No existing project AGENTS, NFR, tests, CI or hook configuration was present.
A fresh test author receives only the spec/API packet and uses a different model.
Shared filesystem access is not enforced isolation. Do not read real browser
cookies/Keychain in tests. Real signed-in Chrome and Keychain approval need a local
interactive smoke test. Distribution signing needs the upstream Developer ID and
is separate from compile validation. Rollback is reverting the branch; browser
storage is never modified and existing defaults are retained.

## Implementation notes

The multiple-profile behavior is an implementation assumption, not recorded user
approval: show choices instead of guessing identity. No answer to the optional
edit question was received. Explicit user requests remain in scope.
The spec-only test author used gpt-6.1-sol with no inherited chat. Tests were
frozen independently; lifecycle tests were added from a public API contract before
corrections based on those tests. No meaningful baseline red execution was possible
because the new reader/API did not exist.

External contracts inspected: current Chromium KeychainKeyProvider uses v10,
AES128CBC, PBKDF2-HMAC-SHA1, saltysalt and 1003 iterations:
https://raw.githubusercontent.com/chromium/chromium/main/components/os_crypt/async/browser/keychain_key_provider.mm
Cookie database v24 binds encrypted values to SHA256(host_key):
https://chromium.googlesource.com/chromium/src/+/refs/tags/131.0.6761.0/net/extras/sqlite/sqlite_persistent_cookie_store.cc
Chrome's file-based Keychain requires the legacy interaction guard; LAContext alone
does not suppress its UI. Serialize manual/background reads and restore the prior
process-wide flag. Primary source (FB16959400):
https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc

Observed harness failures: Foundation selected an unwritable sandbox temp path;
fixture root was made explicit. A runner edit accidentally changed the compiler
output argument; fixed without changing assertions. The first reader run exposed
directory trailing-slash differences in URL equality; normalized paths fix it.
