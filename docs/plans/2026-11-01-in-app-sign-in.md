# In-app Claude sign-in

Users sign in to claude.ai inside LimitFuel instead of Chrome. Each sign-in runs in its own
throwaway web view, so any number of Claude accounts can be signed in at once, and none of
them depends on which account a Chrome profile holds. Chrome sync and manual cookies stay.

## Contract

### `ClaudeSignInCookies.header(from cookies: [HTTPCookie], now: Date = Date()) -> String?` (app/ClaudeAccounts.swift)

- Uses only cookies whose `domain`, lowercased and without one leading `.`, is exactly `claude.ai`
  (the Chrome reader's `host_key IN ('claude.ai','.claude.ai')`). `api.claude.ai`, `evilclaude.ai`,
  `claude.ai.example.com`, `anthropic.com`, `accounts.google.com` are ignored.
- Skips cookies with `expiresDate < now`; session cookies (no expiry) are kept.
- Skips a cookie whose name/value fails the Chrome reader's pair rules (`ChromeCookieReader.validPair`,
  made internal) instead of failing the whole header.
- One value per name. Among duplicates the longest `path` wins, then the host-only `claude.ai`
  over `.claude.ai` (the Chrome reader's ordering).
- Output: `name=value` pairs sorted by name, joined with `"; "`.
- Returns nil unless the result passes `ChromeCookieReader.validateHeader` (so a non-empty
  `sessionKey` is required).

### `ClaudeSignInOutcome: Equatable` (app/ClaudeAccounts.swift)

`.added(String)`, `.renewed(String)`, `.alreadyAdded(String)` carry the account label shown to the
user (its email); `.failed(String)` carries a user-facing message.

### `ClaudeAccounts.completeSignIn(_ header: String, completion: @escaping (ClaudeSignInOutcome) -> Void)`

Called on the main thread. `completion` runs exactly once, on the main thread; local failures may
complete before the call returns.

1. Header fails `validateHeader` → `.failed("claude.ai did not return a session. Sign in again.")`.
   No request, nothing stored.
2. Session already tracked (`ClaudeSessionHeader.sameSession` with an account's header) →
   `.alreadyAdded(<that account's label>)`. No request, nothing stored.
3. `GET https://claude.ai/api/account` with `Cookie: <header>` and the same headers UsageManager's
   identity request sends, through the injected `apiSession` (or, when nil, an ephemeral session
   with no cookie storage, no cache and 20 s timeouts).
   - Transport error, non-200, or `ClaudeAccountIdentity.parse(data, organizationID: <lastActiveOrg in header>)`
     returning nil → nothing stored; HTTP 401/403 → `.failed("claude.ai rejected this sign-in. Sign in again.")`,
     anything else → `.failed("LimitFuel could not confirm the account with claude.ai. Check your connection and try again.")`.
4. Matching happens against the accounts that exist when the response arrives. An account matches
   when `UUID(uuidString:)` of its `claudeAccountUUID` equals the resolved account UUID, and its
   `organizationID` and the header's `lastActiveOrg` are equal as UUIDs or either is missing.
   The first listed match wins.
   - Match → `account.adoptSignIn(header, identity:organizationID:)`. `true` → `.renewed(email)`;
     `false` → `.failed("LimitFuel could not save this session to the Keychain. Try again.")`.
   - No match → new account: credential written first (failure → the same Keychain `.failed`,
     nothing persisted); metadata `chrome_sync=false`, `web_sign_in=true`, `email`, `account_uuid`,
     `organization_name`, `organization_id` (header's `lastActiveOrg`, when present); id appended to
     `claude_account_ids`; `claude_accounts_auto_add=false`; account appended, alert naming
     updated, `onChange` called, usage fetched → `.added(email)`.
   - Success clears `chromeMessage`.

### UsageManager (app/LimitFuel.swift)

- `ClaudeAccountStore.fields` gains `web_sign_in`, so removing an account clears it.
- `@Published private(set) var signedInHere: Bool`, loaded from `web_sign_in`.
- `@discardableResult func adoptSignIn(_ header: String, identity: ClaudeAccountIdentity, organizationID: String?) -> Bool`:
  writes the credential first; on a Keychain failure returns false and changes nothing. Otherwise
  stops Chrome sync (`chrome_sync=false`, `chrome_profile_id`/`chrome_profile_name` removed and their
  properties nil, `chromeProfiles=[]`, `chromeMessage=nil`, `chromeNeedsAttention=false`), sets
  `signedInHere`/`web_sign_in`, replaces the session (usage reset when the session identity
  changes), stores the given identity (`email`, `account_uuid`, `organization_name`,
  `organization_id`) without another identity request for this session, clears `errorMessage`
  and `needsSignIn`, fetches usage, returns true. A removed account returns false.
- Manual cookie (`saveSessionCookie`), `clearSessionCookie`, and a Chrome detection that turns
  Chrome sync on all set `signedInHere=false` / `web_sign_in=false`.
- `accountLabel`: email; else `"Claude sign-in"` when `signedInHere`; else `"Manual cookie"` when
  Chrome sync is off; else the Chrome profile name or `"Chrome"`.
- `@Published private(set) var needsSignIn: Bool`: true after claude.ai answers the usage or
  bootstrap request with 401/403; false after a successful usage response and whenever the
  session is replaced or cleared. Detail endpoints (credits, overage, limit resets) never set it:
  they may refuse a Team member without billing access while the session is fine.
- `connectionSummary` stays nil until usage loads; then `"Signed in with LimitFuel"` for a
  signed-in-here account.
- Hourly Chrome refresh never touches a signed-in-here account (it has Chrome sync off).

### Sign-in window (app/ClaudeSignInWindow.swift, UI)

- One window at a time; a second request brings it forward. Fresh `WKWebsiteDataStore.nonPersistent()`
  per window, so nothing is written to disk and every window starts signed out.
- Loads `https://claude.ai/login`. Default WebKit user agent (no browser spoofing).
- Watches the cookie store. Once `ClaudeSignInCookies.header` returns a header that has
  `lastActiveOrg`, or 5 s after the first header without it, calls `completeSignIn` once.
  Success closes the window; `.failed` shows the message with Try Again (same header).
- "Paste Login Link" loads an `https://claude.ai/...` link from the clipboard in the same web
  view, so an emailed magic link completes here. Any other URL is refused with a message.
- Popups (`window.open`) load in the same web view. Edit shortcuts (⌘X/C/V/A/Z) work.
- Entry points: Settings → Claude accounts "Sign In…"; first-run Claude card "Sign In to Claude";
  an account that needs sign-in shows "Sign In Again" (signed-in-here) or "Sign In Here" (Chrome).

## Failure list

| # | Failure | Handling |
|---|---------|----------|
| 1 | Google blocks Google sign-in in embedded web views | Hint in the window: use Continue with email. No user-agent spoofing. |
| 2 | Emailed magic link opens in the default browser | claude.ai shows a code there to type in the window; or Paste Login Link. |
| 3 | Pasted link is not claude.ai | Refused, message shown, nothing loaded. |
| 4 | `sessionKey` set before `lastActiveOrg` | Wait up to 5 s for the org; usage falls back to `/api/bootstrap`. |
| 5 | Identity lookup fails (network, 5xx, parse) | Nothing stored; window stays open with Try Again. |
| 6 | 401/403 on identity lookup | Nothing stored; "Sign in again". |
| 7 | Keychain write fails | Nothing stored or changed; message; Try Again. |
| 8 | Same session signed in twice | `.alreadyAdded`, nothing written. |
| 9 | Same Claude user signs in again (expired or revoked session) | Existing account renewed in place, keeps its position, alert history and badge; Chrome sync turned off. |
| 10 | Same user, other organization | Added as its own account. |
| 11 | Account removed while the lookup runs | Match runs on current accounts; a removed account is never renewed. |
| 12 | Signed-in session expires (~28 days) or is revoked | 401 sets `needsSignIn`; card and settings row show Sign In Again. |
| 13 | User closes the window mid-sign-in | Web view and its cookies are discarded; nothing stored. |
| 14 | Chrome hourly refresh | Skips signed-in-here accounts. |

## Not handled

- Session renewal without the user: claude.ai's `sessionKey` lasts about 28 days; LimitFuel does
  not refresh it in the background.
- Google SSO inside the window when Google blocks it (Continue with email works).

## Verification (2026-11-02)

- `Tests/ClaudeSignInTests.swift`, written from this contract by a separate task: 29 tests, 744 checks
  pass. Breaking the same-user match (renewing any tracked user) fails them.
- Changed after review: detail endpoints no longer set `needsSignIn`; `connectionSummary` waits for
  usage. The suite's detail test now asserts that a 403 there keeps the session signed in.
- Full `Tests/run.sh`, both GUI suites (`run-popup-native.sh`; the popup one is sensitive to where macOS
  places its status item on a crowded notched menu bar) and `Tests/lint.sh` pass.
- The real window, opened by a harness against an in-memory store, loads `https://claude.ai/login`
  ("Sign in - Claude", email field present) in a non-persistent data store; a second open reuses
  the window and closing it releases it. No real sign-in was made.
