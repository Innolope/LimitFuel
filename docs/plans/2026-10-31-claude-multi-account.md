# Claude accounts in the Keychain, several accounts, account emails

User requests (2026-10-31):

1. Move the Claude session cookie out of UserDefaults into the macOS Keychain.
   Today the full `Cookie` header (with `sessionKey`) sits in plaintext in
   `~/Library/Preferences/com.innolope.limitfuel.plist`, readable by any process
   running as the user without a prompt.
2. Track several Claude accounts. Each account gets its own menu bar entry with
   its own limit percentage.
3. The popup names each account by its email instead of "Chrome".

Tier: Standard (ships to users, stores credentials; no money or server-side
effects). Acceptance tests for sections A-F are written from this contract by
Codex (gpt-6.1-sol), separately from the implementation. The popup and Settings
UI (section G) is verified natively and by rendered previews.

Probe (read-only, the user's own stored session): `GET https://claude.ai/api/account`
returns 200 with `email_address`, `uuid` and `memberships[].organization.{uuid,name}`.
`/api/bootstrap` carries the same `account` object plus large unrelated payloads,
so identity uses `/api/account`.

## Contract

### A. Credential storage

```swift
enum CredentialStoreError: Error, Equatable {
    case interactionRequired      // the Keychain must ask the user first
    case failure(OSStatus)
}

protocol CredentialStore: AnyObject {
    func read(account: String, allowInteraction: Bool) throws -> String?  // nil: no item
    func write(_ secret: String, account: String) throws                  // create or replace
    func delete(account: String) throws                                    // a missing item is not an error
}

final class KeychainCredentialStore: CredentialStore {
    static let service = "com.innolope.limitfuel.claude-session"
    init(service: String = KeychainCredentialStore.service, keychain: SecKeychain? = nil)
}

enum ClaudeCredentials {
    static var standard: CredentialStore   // Keychain; in ACCEPTANCE_TESTS builds a process-wide in-memory store
}
```

- Generic password items: service `com.innolope.limitfuel.claude-session`,
  account = LimitFuel's account id, value = the full Cookie header as UTF-8.
- The item lives in the login keychain (the file-based keychain). The data
  protection keychain needs a provisioning-profile entitlement that Developer ID
  builds do not carry. The item is encrypted at rest and its access list trusts
  only the app that created it.
- `keychain` targets a specific keychain file; tests pass a temporary keychain
  and never touch the login keychain.
- `read(allowInteraction: false)` never shows UI. A locked keychain or an access
  list that no longer trusts this build (ad-hoc rebuilds change the signature)
  throws `.interactionRequired`.

### B. Account storage and migration

UserDefaults keeps only non-secret metadata:

| Key | Value |
| --- | --- |
| `claude_account_ids` | `[String]`, account ids in display order |
| `claude_account.<id>.chrome_sync` | `Bool`, refresh this account's cookie from Chrome hourly |
| `claude_account.<id>.chrome_profile_id` / `.chrome_profile_name` | pinned Chrome profile |
| `claude_account.<id>.email` / `.organization_name` / `.account_uuid` | resolved identity |
| `claude_account.<id>.last_notified_threshold` | `Int`, usage alert history |
| `claude_account.<id>.legacy_cookie_pending` | `Bool`, Keychain migration not finished |
| `claude_accounts_auto_add` | `Bool`, first-run Chrome adoption allowed |
| `claude_credential_deletions` | `[String]`, ids whose Keychain delete failed; retried at launch |

Migration from 1.0.x keys (`claude_session_cookie`, `chrome_detection_enabled`,
`chrome_profile_id`, `last_notified_threshold`) runs whenever accounts load, and
is idempotent:

- No legacy cookie and no `claude_account_ids`: write an empty id list;
  `claude_accounts_auto_add` = legacy `chrome_detection_enabled` ?? true; remove
  the legacy flags.
- Legacy cookie whose `sessionKey` already belongs to a stored account: remove the
  legacy cookie and flags.
- Otherwise the legacy cookie becomes a new account appended to the list:
  `chrome_sync` = legacy `chrome_detection_enabled` ?? false, the pinned profile
  and alert threshold carry over. The cookie is written to the credential store
  first. Only when that write succeeds is the plaintext removed. When it fails
  the account is marked `legacy_cookie_pending`, keeps working from the legacy
  value, and the write is retried at the next load.
- `UsageManager(... accountID: nil)` uses the first account, creating one when
  the list is empty (`chrome_sync` = `claude_accounts_auto_add`).

### C. Accounts

```swift
final class ClaudeAccounts: ObservableObject {
    @Published private(set) var accounts: [UsageManager]
    @Published private(set) var isDetectingChrome: Bool
    @Published private(set) var chromeMessage: String?
    @Published private(set) var chromeChoices: [ChromeProfile]   // signed-in profiles not yet added
    init(defaults: UserDefaults = .standard, credentials: CredentialStore = ClaudeCredentials.standard,
         chromeReader: ChromeCookieReader = ChromeCookieReader(), apiSession: URLSession? = nil,
         delegate: AppDelegate? = nil)
    @discardableResult func addManualCookie(_ header: String) -> Bool
    func detectChromeSessions(interactive: Bool)
    func addChromeProfile(_ profileID: String)
    func remove(_ account: UsageManager)
    func fetchAll()
    func refreshChromeAccounts()
}
```

- `init` migrates, builds one `UsageManager` per id in order, retries pending
  credential deletions, and makes no network request.
- `addManualCookie` trims and validates the header (`ChromeCookieReader.validateHeader`).
  Invalid header, a `sessionKey` already used by an account, or a failed
  credential write: returns false, sets `chromeMessage`, persists nothing.
  Success appends a manual account (`chrome_sync` false), stores the cookie only
  in the credential store, starts its fetch and sets `claude_accounts_auto_add` false.
- `detectChromeSessions` reads every Chrome profile (Keychain interaction only
  when `interactive`). Sessions whose `sessionKey` an account already uses are not
  offered. A profile pinned by an account is offered again once it is signed in to
  another Claude account (2026-11-01 correction: Chrome keeps one claude.ai sign-in
  per profile, and the original rule hid that session). With no accounts and
  (`interactive` or auto-add allowed), or when `interactive`, exactly one new
  session is added directly. Several new sessions are published as
  `chromeChoices` and nothing is added. A background check with accounts present
  never adds anything.
- `addChromeProfile` adds the chosen profile's session as a Chrome-synced
  account pinned to that profile. Repeated calls for one profile add one account.
- `remove` cancels the account's requests (late responses are ignored), deletes
  its credential (a failed delete is queued in `claude_credential_deletions`),
  removes its metadata keys and id, and sets `claude_accounts_auto_add` false.
- `refreshChromeAccounts` runs each Chrome-synced account's background
  `detectChromeSession()`, and the first-run discovery while the list is empty
  and auto-add is allowed.
- Accounts are independent: one account's 401, timeout or Chrome failure never
  changes another account's usage, menu entry or alert history.
- An account with a resolved Claude user takes a changed session from its profile
  only after `GET /api/account` confirms the same user. Another user's session is
  left for Add from Chrome, and the account keeps its own session and says so.

### D. Account identity

```swift
struct ClaudeAccountIdentity: Equatable {
    let email: String
    let accountUUID: String
    let organizationName: String?
}

extension UsageManager {
    var accountID: String { get }
    var email: String? { get }               // @Published
    var organizationName: String? { get }    // @Published
    var accountLabel: String { get }         // email, else Chrome profile name, else "Manual cookie"
    func fetchIdentityIfNeeded()
    static func parseAccountIdentity(_ data: Data, organizationID: String?) -> ClaudeAccountIdentity?
}
```

- After an account's first successful usage response for a session, `ClaudeAccounts`
  requests `GET https://claude.ai/api/account` once per session identity
  (`sessionKey` + `lastActiveOrg`) per run, with the same headers as usage.
  Failure or invalid data leaves the identity unchanged and is not retried until
  the session changes or the app restarts.
- Valid identity: `email_address` 3-320 UTF-8 bytes containing "@" and no
  whitespace or control characters; `uuid` a UUID; organization name from the
  membership whose `organization.uuid` is the account's organization, at most
  100 characters, else nil.
- A new session identity clears the stored identity before it is resolved again.
- If a resolved account matches an earlier account's `accountUUID` and
  organization, the later account is removed and `chromeMessage` says it was
  already added.
- The email is account metadata. It never reaches diagnostics.

### E. Menu bar

```swift
struct MenuBarEntry { ...; var badge: String? = nil; var accountLabel: String? = nil }

struct ClaudeMenuBarAccount {
    let option: MenuBarWindowOption?
    var isStale = false
    var updatedAt: Date? = nil
    let label: String
}

enum MenuBarStatus {
    static func accountBadges(_ labels: [String]) -> [String?]
    static func selectedEntries(claudeAccounts: [ClaudeMenuBarAccount], codex: MenuBarWindowOption?,
                                codexIsStale: Bool = false, codexUpdatedAt: Date? = nil,
                                percentageMode: MenuBarPercentageMode? = nil) -> [MenuBarEntry]
}
```

- One Claude entry per account that has a valid option, in account order, then
  Codex. The Claude window preference applies to every account.
- One account: no badge, and output equals the existing single-account
  `selectedEntries(claude:codex:...)`.
- Two or more accounts: each Claude entry carries a badge and its label. The badge
  is the first letter or digit of the label's part before "@", uppercased. When
  two accounts would share a badge, every account uses its 1-based position
  instead. A label without a letter or digit uses its position.
- Accessibility with badges: `Claude <label> 42% remaining, ...`.
- The badge is drawn over the Claude mark and does not change entry width.

### F. Notifications

- Each account keeps its own alert threshold history.
- With two or more accounts the alert names the account:
  `<label> reached 75% of its 5-hour session limit`.
- The global `usage_notifications_enabled` switch is read when the alert is due,
  so changing it applies to every account at once.

### G. Popup and Settings (native verification)

- Dashboard: one Claude card per account, header detail = account label (the
  email once known). No accounts: one Claude card with the connect controls.
- Settings, Claude accounts: one row per account (label, source, status, Remove),
  then Add from Chrome (with profile choices) and Add Manual Cookie.

## What can go wrong

| # | Category | Trigger and invariant | Mark |
| --- | --- | --- | --- |
| 1 | Invalid input | Manual header without `sessionKey`, with control characters or oversized: rejected, nothing stored | handle |
| 2 | Invalid input | `/api/account` returns HTML, no email, a 400-char email or control characters: label falls back to the source | handle |
| 3 | Concurrency | Account removed while its usage or identity request is in flight: late reply cannot repopulate it or rewrite its credential | handle |
| 4 | Concurrency | Hourly Chrome refresh finishes after its account was removed: ignored | handle |
| 5 | Idempotency | Add Chrome profile clicked twice: one account | handle |
| 6 | Idempotency | Crash between the Keychain write and removing the plaintext: next launch removes the plaintext, no duplicate account | handle |
| 7 | Idempotency | Same Claude account added twice (same `sessionKey`, or two Chrome profiles signed into one account): one account | handle |
| 8 | Timeouts | `/api/account` times out: no retry loop; retried after a new session or restart | handle |
| 9 | Partial failure | Keychain write fails during migration: plaintext kept, app keeps working, retried next launch | handle |
| 10 | Partial failure | Keychain write fails when adding an account: account not added, message shown | handle |
| 11 | Partial failure | Keychain read needs approval (ad-hoc rebuild, locked keychain): no background prompt; account shows a message; Refresh asks once | handle |
| 12 | Partial failure | Keychain delete fails on Remove: account removed, delete retried at next launch | handle |
| 13 | Auth | One account gets 401/403: only that account resets and loses its menu entry | handle |
| 14 | Auth | Background Keychain reads of LimitFuel's own items never prompt | handle |
| 15 | Migration | 1.0.x Chrome-pinned user: one Chrome account on the same profile, same cookie, alert history kept, no new Chrome Safe Storage prompt | handle |
| 16 | Migration | User removed every account: hourly check never re-adds one | handle |
| 17 | Data limits | Five or more accounts make the menu bar item wide | defer |
| 18 | Migration | Downgrade to 1.0.x after migrating: old build finds no stored cookie and re-detects from Chrome or asks for a manual cookie | defer |
| 19 | Observability | Account B recovering clears the dedupe for account A's failure, so A's repeat failure can report again (still capped at 20/hour) | defer |
| 20 | Observability | Email, cookie and account ids never reach diagnostics | handle |

## Spec corrections to existing tests

Tests that asserted the cookie, pinned profile or alert threshold under the 1.0.x
UserDefaults keys now assert the credential store and the per-account keys. The
behaviour they check (import, pinning, rotation, manual-wins, clear) is unchanged.

## Work and evidence

1. Acceptance tests for A-F (`Tests/ClaudeAccountsTests.swift`) were written by
   Codex gpt-6.1-sol from this contract without reading the new code. The
   implementation was then fitted to them. Assumptions the test author recorded
   and the implementation adopted: `UsageManager(... apiSession:, accountID:,
   credentials:)` argument order; organization UUIDs compare as UUIDs, so case
   does not matter; only a label without a letter falls back to its position.
2. Defects the suite found in the first implementation, all fixed:
   - the identity request counted as an in-flight usage request, so a Refresh
     during it was dropped. Identity lookups now run outside usage coalescing.
   - `isLoading` went false when the main usage reply arrived while the extra
     usage, credit and reset requests were still running, so a click in that gap
     was dropped (pre-existing). It now clears when every request has finished.
   - when the later of two duplicate accounts resolved first, it was never
     removed. Duplicate removal now keeps the first-listed account either way.
   - the identity lookup also fired from `parseUsageData`, which does no network
     I/O. It now runs only after a real HTTP 200 usage reply.
3. Menu bar badges and the per-account popup and Settings were checked in
   rendered previews (light and dark, 4x) before the live check.

### Failure-list sweep

| # | Where handled | Proof |
| --- | --- | --- |
| 1 | `ClaudeAccounts.addManualCookie` validates with `ChromeCookieReader.validateHeader` before any write | ClaudeAccountsTests manualAdds |
| 2 | `ClaudeAccountIdentity.parse` | ClaudeAccountsTests parseIdentityTable, identityRequests |
| 3 | `UsageManager.disconnect` sets `removed`, changes the connection revision; replies check both | ClaudeAccountsTests removedHTTPReplies |
| 4 | Chrome replies check the connection revision; `replaceSessionCookie` ignores removed accounts | ClaudeAccountsTests removedChromeReply |
| 5 | `addChromeSession` drops the choice and rejects a pinned profile | ClaudeAccountsTests chromeDiscovery |
| 6 | `migrateLegacy` marks `legacy_cookie_pending` before the write; a pending account is finished, not duplicated | ClaudeAccountsTests migrationBranches |
| 7 | `isTracked` on add; `removeDuplicates(of:)` after identity | ClaudeAccountsTests manualAdds, chromeDiscovery, duplicateResolvedAccounts |
| 8 | `identityRequestedFor` is set before the request; no retry path | ClaudeAccountsTests identityRequests |
| 9 | `finishLegacy` removes plaintext only after a successful write; `loadSessionCookie` falls back to the pending plaintext | ClaudeAccountsTests migrationBranches |
| 10 | `ClaudeAccounts.add` writes the credential before any metadata | ClaudeAccountsTests manualAdds |
| 11 | `loadSessionCookie` maps `.interactionRequired` to `credentialNeedsApproval`; Refresh calls `refreshAllowingKeychainApproval` | ClaudeAccountsTests credentialReadFaults (background half); the prompt itself is manual |
| 12 | `ClaudeAccountStore.deleteCredential` queues failures; `retryDeletions` at init | ClaudeAccountsTests removeAndRetry |
| 13 | Each account is its own `UsageManager` | ClaudeAccountsTests accountIsolation |
| 14 | Every background read passes `allowInteraction: false`; `KeychainInteraction` disables keychain UI for the call | ClaudeAccountsTests (all fixtures assert it) |
| 15 | `migrateLegacy` copies the Chrome flag, profile and threshold | ClaudeAccountsTests migrationBranches; UsageManagerTests |
| 16 | `remove` turns `claude_accounts_auto_add` off; background discovery needs it | ClaudeAccountsTests removeAndRetry |
| 20 | No new diagnostics payloads; email stays in UserDefaults | SentryPrivacyTests unchanged and passing |
