# LimitFuel for Linux: specification

LimitFuel for Linux is a tray app that shows Claude and Codex plan usage, matching
the macOS app's behavior. All provider logic lives in the cross-platform
`limitfuel-core` crate (`linux/core`), which is unit-tested on any OS. The Tauri
app (`linux/app`) is a thin Linux shell: tray, menu, settings window, storage.

Times are `f64` seconds since the Unix epoch everywhere in the core API.

## Scope

In: tray icon with a text label, a menu listing every usage window, refresh,
a settings window, Chrome/Chromium/Brave session detection, a manually pasted
cookie, Codex through its CLI, threshold notifications, open at login, one
running instance, `--version`, Sentry reporting under the macOS policy.

Deferred: KWallet (KDE users of Chrome paste a cookie instead), Firefox
cookies, Claude extra-usage credits, the update banner, Claude status-page
alerts, the stale-blur effect.

## Assumptions

- Tray: StatusNotifierItem through libayatana-appindicator. Clicking the icon
  opens its menu on every desktop; there is no popover on Linux.
- No tray host on D-Bus (vanilla GNOME without the AppIndicator extension):
  the app opens a small status window instead and says how to get the icon.
- Label: `Claude 95% · 3h  Codex 85% · 5d`, one entry per connected provider,
  the percentage in the user's mode (remaining by default, like macOS).
- Settings live in `$XDG_CONFIG_HOME/limitfuel/settings.json` (mode 0600).
  A pasted cookie is stored in the Secret Service only; when none is running
  it is kept in memory and Settings says it will be forgotten on quit.
- Chrome cookies are re-read hourly and on demand; usage polls every 60 s,
  every 12 s while a five-hour window is above 90% used.
- Codex: `codex app-server` per poll with a 45 s budget, as on macOS.
- Packages: AppImage, `.deb`, `.rpm`. No Flatpak or Snap: their sandboxes
  block Chrome's cookie database and the `codex` CLI.

## Core API (`limitfuel_core`)

### `display`

```rust
pub enum Provider { Claude, Codex }                     // Copy, Eq, Debug
pub enum PercentageMode { Used, Remaining }             // Copy, Eq, Debug, default Remaining
impl PercentageMode {
    pub fn displayed_percent(self, used: f64) -> i64;
}
pub struct WindowOption {                               // Clone, Debug, PartialEq
    pub id: String,
    pub provider: Provider,
    pub label: String,
    pub percent: f64,                                   // percent used, 0..=100 when valid
    pub duration_minutes: Option<i64>,
    pub is_preferred_bucket: bool,
    pub resets_at: Option<f64>,
}
pub const AUTOMATIC: &str = "automatic";
pub fn select_option<'a>(provider: Provider, options: &'a [WindowOption],
                         selection_id: Option<&str>) -> Option<&'a WindowOption>;
pub fn reset_label(resets_at: Option<f64>, now: f64) -> Option<String>;
pub fn tray_label(claude: Option<&WindowOption>, codex: Option<&WindowOption>,
                  mode: PercentageMode, now: f64) -> String;
pub fn duration_label(minutes: i64) -> String;
```

- `displayed_percent`: clamp `used` to 0..=100 (non-finite counts as 0), use
  `100 - used` for `Remaining`, round half away from zero.
- `select_option`: consider only options of `provider` whose `percent` is finite
  and within 0..=100. A `selection_id` other than `AUTOMATIC` that matches one
  of them wins. Otherwise prefer options with `0 < duration_minutes < 1440`
  (falling back to all valid options when there are none), and among those the
  first with `is_preferred_bucket`, else the first.
- `reset_label`: `None` without a reset or when either time is outside
  -62135596800..=253402300799. Remaining `r = resets_at - now`:
  `r <= 0` → `"0m"`; `r >= 86400` → `"{floor((r + 43200) / 86400)}d"`;
  `r >= 3600` → `"{floor((r + 900) / 3600)}h"`; otherwise `"{ceil(r / 60)}m"`.
  So 23h50m is `"24h"`, 2h45m is `"3h"`, 2h44m59s is `"2h"`, 59s is `"1m"`.
- `tray_label`: entries for Claude then Codex, each `"{Name} {p}%"` plus
  `" · {reset}"` when `reset_label` is `Some`, joined by two spaces. Name is
  `Claude` or `Codex`. With no entries: `"LimitFuel"`.
- `duration_label`: multiples of 1440 → `"{n}d"`, of 60 → `"{n}h"`, else `"{n}m"`.

### `claude`

```rust
pub enum ClaudeError { SignIn, Offline, Timeout, Protocol, InvalidData }  // Debug, Eq
pub fn org_id_from_cookie(header: &str) -> Option<String>;
pub fn parse_bootstrap(body: &[u8]) -> Result<String, ClaudeError>;
pub fn parse_usage(body: &[u8]) -> Result<Vec<WindowOption>, ClaudeError>;
pub fn parse_iso8601(text: &str) -> Option<f64>;
pub struct ClaudeClient { /* base_url, timeout */ }
impl ClaudeClient {
    pub fn new(base_url: &str, timeout: std::time::Duration) -> Self; // base "https://claude.ai"
    pub fn fetch(&self, cookie_header: &str) -> Result<Vec<WindowOption>, ClaudeError>;
}
```

- `org_id_from_cookie`: the value of a `lastActiveOrg` pair (pairs split on `;`,
  trimmed) when it is a UUID (8-4-4-4-12 hex). Lowercased on return.
- `parse_bootstrap`: `account.lastActiveOrgId` must be a UUID, else `Protocol`.
  Invalid JSON is `Protocol`.
- `parse_usage`: JSON object, else `InvalidData`. `five_hour.utilization` must be
  a number (not a boolean) within 0..=100, else `InvalidData`. Windows, in order:
  - `claude:five_hour`, label `Session · 5h`, 300 min, preferred;
  - `claude:seven_day`, `Weekly · 7d`, 10080 min, preferred, when valid;
  - `claude:seven_day_sonnet`, `Sonnet · 7d`, 10080 min, not preferred, when valid;
  - `claude:seven_day_fable`, `Fable · 7d`, 10080 min, not preferred, from the
    first `limits[]` entry whose `scope.model.display_name` is `"Fable"`, using
    its `percent` and `resets_at`, when valid.
  Optional windows with a missing or invalid percentage are skipped, not errors.
  `resets_at` is ISO 8601 with or without fractional seconds; unparseable → `None`.
- `fetch`: if the cookie holds an org id, skip bootstrap; else GET
  `{base}/api/bootstrap`. Then GET `{base}/api/organizations/{org}/usage`.
  Every request sends the cookie header, `Accept: */*`, a desktop Chrome
  `User-Agent`, and follows no redirects. 401 and 403 → `SignIn`; any other
  non-200 (including a 3xx) → `Protocol`; timeout → `Timeout`; DNS, refused
  or reset connections → `Offline`; bodies over 1 MiB → `InvalidData`.

### `codex`

```rust
pub enum CodexError { Unavailable, SignIn, Protocol, Timeout, InvalidData } // Debug, Eq
pub struct CodexWindow { pub used_percent: f64, pub window_duration_mins: Option<i64>, pub resets_at: Option<f64> }
pub struct CodexBucket { pub id: String, pub name: String, pub primary: Option<CodexWindow>, pub secondary: Option<CodexWindow> }
pub struct CodexSnapshot { pub account_label: Option<String>, pub buckets: Vec<CodexBucket> }
impl CodexSnapshot { pub fn window_options(&self) -> Vec<WindowOption>; }
pub fn parse_limits(body: &[u8]) -> Result<Vec<CodexBucket>, CodexError>;
pub fn window_label(minutes: Option<i64>, role: &str) -> String;
pub fn resolve_executable(custom: Option<&std::path::Path>, path_env: Option<&str>,
                          home: &std::path::Path) -> Option<std::path::PathBuf>;
pub const DEFAULT_TIMEOUT: std::time::Duration;          // 45 s
pub struct CodexClient { pub executable: std::path::PathBuf, pub timeout: std::time::Duration }
impl CodexClient { pub fn fetch(&self) -> Result<CodexSnapshot, CodexError>; }
```

- `parse_limits`: body ≤ 1 MiB JSON object, else `InvalidData`. Buckets come from
  a non-empty `rateLimitsByLimitId` object, else from `rateLimits` (id =
  its `limitId` or `"codex"`), else `InvalidData`. 1..=64 buckets, sorted by id;
  ids 1..=200 chars; `limitName` (default: the id) ≤ 200 chars. A window that is
  absent or null is `None`; one without `usedPercent` is `None`. `usedPercent`
  < 0, a boolean or a non-number is `InvalidData`; `windowDurationMins` must be a
  positive integer; `resetsAt` must be within 0..=253402300799.
- `window_label`: 300 → `Session · 5h`, 10080 → `Weekly · 7d`, other positive →
  `"{role} · {duration_label}"`, none → `role`.
- `window_options`: one option per present window, primary then secondary, per
  bucket in order. id `codex:{sha256 hex of bucket id}:{primary|secondary}`.
  Label is the window label, prefixed with `"{name} · "` when there is more than
  one bucket or any bucket name is not `codex` (case-insensitive); duplicate
  names show as `"{name} ({id})"`. Preferred when the bucket id is `codex`.
- `resolve_executable`: a custom path is used only if it is an executable file.
  Otherwise the first executable among each `path_env` directory + `/codex`,
  then `~/.local/bin/codex`, `~/.npm-global/bin/codex`, `/usr/local/bin/codex`,
  `/usr/bin/codex`.
- `fetch`: run `{exe} app-server --listen stdio://` in its own process group with
  stderr discarded. JSON lines: send `initialize` (id 1), then `initialized`,
  `account/read` with `refreshToken: false` (id 2), `account/rateLimits/read`
  (id 3). Ignore notifications. A server request (has `method` and `id`) gets a
  `-32601` error reply and fails with `SignIn`. An account that is not
  `type: "chatgpt"` is `SignIn`. An `account/updated` notification after the
  account read whose `authMode` is a string other than `chatgpt` is `SignIn`;
  otherwise (`chatgpt`, null or absent), re-read the account (id 4) and, when its email differs, the limits (id 5); a
  further update during that is `Protocol`. Missing executable or spawn failure
  → `Unavailable`. EOF or a JSON-RPC error → `Protocol`. Output over 1 MiB →
  `InvalidData`. The whole exchange shares one deadline → `Timeout`. On every
  exit the process group gets SIGTERM, then SIGKILL 0.5 s later.
  `account_label` is the account email, at most 200 chars.

### `cookies`

```rust
pub enum CookieError { Unavailable, Database, Keyring, Encryption, InvalidCookie, Profile } // Debug, Eq
pub struct ChromeProfile { pub id: String, pub name: String }
pub struct ChromeSession { pub profile: ChromeProfile, pub cookie_header: String }
pub trait KeyProvider { fn password(&self, allow_interaction: bool) -> Result<Vec<u8>, CookieError>; }
pub fn derive_key(password: &[u8]) -> [u8; 16];
pub fn decrypt_value(encrypted: &[u8], host: &str, db_version: i64,
                     v11_password: &mut dyn FnMut() -> Result<Vec<u8>, CookieError>) -> Result<String, CookieError>;
pub fn validate_header(header: &str) -> bool;
pub struct Browser { pub name: &'static str, pub root: std::path::PathBuf, pub keyring_application: &'static str }
pub fn browsers(config_dir: &std::path::Path) -> Vec<Browser>;
pub fn discover(root: &std::path::Path, profile_id: Option<&str>, allow_interaction: bool,
                now: f64, keys: &dyn KeyProvider) -> Result<Vec<ChromeSession>, CookieError>;
```

- `derive_key`: PBKDF2-HMAC-SHA1, salt `saltysalt`, 1 iteration, 16 bytes.
- `decrypt_value`: prefix `v10` uses `derive_key(b"peanuts")`; `v11` uses
  `derive_key` of the keyring password, requested lazily only for `v11`.
  AES-128-CBC, IV of 16 spaces, PKCS#7. Ciphertext after the prefix must be a
  non-empty multiple of 16 and the whole value ≤ 32768 bytes. When
  `db_version >= 24` the plaintext must start with SHA-256(host), which is
  stripped. Any other prefix, bad padding, a hash mismatch or non-UTF-8 →
  `Encryption`. A keyring failure passes through unchanged.
- `validate_header`: ≤ 16384 bytes, printable ASCII, ≤ 128 `name=value` pairs
  split on `;` and trimmed, unique names that are RFC 6265 tokens, values free of
  space, `"`, `,`, `;` and `\`, and a non-empty `sessionKey`.
- `browsers`: Google Chrome (`google-chrome`, keyring application `chrome`),
  Chromium (`chromium`, `chromium`) and Brave (`BraveSoftware/Brave-Browser`,
  `brave`), in that order, rooted at `config_dir`.
- `discover`: profiles are `Default` and `Profile <digits>` directories directly in
  `root`, sorted, that resolve inside `root`; names come from `Local State`
  `profile.info_cache.<id>.name` (≤ 4 MiB file, names cut to 100 chars), else
  the id. A missing root → `Ok(vec![])`; an unreadable root → `Unavailable`. A
  given `profile_id` that is invalid, missing, not a directory or resolves
  outside `root` → `Profile`; when scanning, such entries are skipped. Database:
  `Network/Cookies`, else `Cookies`; a profile without one is skipped (error
  `Profile` when it was the requested profile). Opened read-only.
  `meta.version` must be a positive integer, else `Database`. Rows: host
  `claude.ai` or `.claude.ai`, path `/`, `/api` or `/api/`, not expired
  (`expires_utc` 0, or greater than now in Chrome time, microseconds since
  1601-01-01), `top_frame_site_key = ''` when that column exists. A profile with
  no such `sessionKey` row is skipped without asking for the keyring password.
  At most 128 rows. An auxiliary cookie that fails to decrypt, is oversized or
  has a value `validate_header` would reject is dropped; a failing `sessionKey`
  fails the profile with its error, as do two different `sessionKey` values. An
  encrypted value over 32768 bytes is `InvalidCookie` (checked before
  decrypting). The first value per name wins (rows ordered
  `sessionKey` first, then longest path, shortest host, name). The header is
  `name=value` pairs sorted by name, joined by `"; "`, and must pass
  `validate_header`, else `InvalidCookie`. The keyring password is fetched at
  most once per call.

### `schedule`

```rust
pub const USAGE_INTERVAL: f64 = 60.0;
pub const FAST_USAGE_INTERVAL: f64 = 12.0;
pub const COOKIE_INTERVAL: f64 = 3600.0;
pub fn polling_interval(options: &[WindowOption], now: f64) -> f64;
pub fn next_poll_delay(interval: f64, last_started_at: Option<f64>, now: f64) -> f64;
```

- `polling_interval`: `FAST_USAGE_INTERVAL` when any option has a finite percent
  > 90, `duration_minutes == Some(300)`, and a reset that is `None` or after now;
  else `USAGE_INTERVAL`.
- `next_poll_delay`: `interval` without a last start, else
  `max(1, last_started_at + interval - now)`.

### `diagnostics`

```rust
pub enum DiagnosticProvider { Claude, Codex }
pub enum DiagnosticCode { Unavailable, SignIn, ProtocolFailure, Timeout, InvalidData }
pub struct ReportPolicy { /* state */ }
impl ReportPolicy {
    pub const PERSISTENT_COUNT: u32 = 10;
    pub const PERSISTENT_SECONDS: f64 = 3600.0;
    pub const HOURLY_CAP: usize = 20;
    pub fn new() -> Self;
    pub fn record_failure(&mut self, provider: DiagnosticProvider, code: DiagnosticCode,
                          now: f64, online: bool) -> bool;   // true = send one event
    pub fn record_recovery(&mut self, provider: DiagnosticProvider);
    pub fn reset(&mut self);                                  // on opt-out/opt-in
}
impl From<ClaudeError> for Option<DiagnosticCode>;          // Offline → None
impl From<CodexError> for Option<DiagnosticCode>;
impl From<CookieError> for Option<DiagnosticCode>;          // see below
```

- `SignIn` and `Unavailable` never send. `InvalidData` sends on first occurrence.
  `Timeout` and `ProtocolFailure` send only when `online`, after at least
  `PERSISTENT_COUNT` online failures in a row for that provider spanning at
  least `PERSISTENT_SECONDS`; offline failures neither count nor break the run.
- Each provider/code pair sends at most once until that provider recovers.
  Recovery also clears the provider's run. At most `HOURLY_CAP` sends in any
  rolling hour (an attempt at exactly 3600 s after an earlier one no longer
  counts it); recovery does not reset the cap.
- Mapping: Claude `Offline` → none, `Timeout` → Timeout, `Protocol` →
  ProtocolFailure, `InvalidData` → InvalidData, `SignIn` → SignIn. Codex maps
  name for name. Cookies: `Keyring` → SignIn, `Encryption`/`InvalidCookie` →
  InvalidData, `Unavailable`/`Profile` → Unavailable, `Database` →
  ProtocolFailure. All Claude-provider.

### `notify`

```rust
pub const THRESHOLDS: [u8; 4] = [25, 50, 75, 90];
pub struct ThresholdTracker { /* state, bounded to 256 keys */ }
impl ThresholdTracker {
    pub fn new() -> Self;
    pub fn observe(&mut self, key: &str, used: f64, resets_at: Option<f64>) -> Option<u8>;
}
```

- The tracking key is `key` plus the reset time. Returns the highest threshold
  reached when it exceeds the highest already recorded for that key, else
  `None`. A lower reading never lowers the record. A new reset time starts a
  new record. At most 256 keys; the oldest is evicted first.

## App behavior (`linux/app`)

- `limitfuel --version` prints `LimitFuel {version}` and exits 0 before any GUI.
- A second launch focuses the existing instance's settings window and exits.
- Claude polling runs only with a cookie; Codex polling only with an executable.
- A failed poll keeps the last values, marked stale in the menu; a sign-in
  failure clears that provider.
- Menu: one disabled line per window (`Claude · Session · 5h: 95% left, resets in
  3h`), `Refresh Now`, `Settings…`, `Quit LimitFuel`.
- Settings: Chrome detection with a profile picker, a pasted cookie, the Codex
  path, the window shown in the tray per provider, used/remaining, usage
  notifications, open at login, error reporting.
- Background cookie rechecks never prompt. Only the Detect button may unlock
  the keyring.

## What can go wrong

Marks: **handle**, **defer**, **out** (of scope).

Invalid inputs
1. handle: usage JSON missing `five_hour`, or utilization as string/bool/NaN/150 → InvalidData, no crash.
2. handle: optional Claude windows malformed → skipped; session still shown.
3. handle: Codex limits with negative percent, fractional duration, reset past year 9999, 65 buckets → InvalidData.
4. handle: pasted cookie with `;` injection, spaces, quotes, duplicate names or no `sessionKey` → rejected before any request.
5. handle: `Local State` huge or invalid JSON → profile ids used as names.
6. handle: a profile directory that is a symlink outside the browser root → Profile when requested, skipped when scanning.

Concurrency
7. handle: a poll still running when the timer fires → the new poll is skipped, never overlapped.
8. handle: two app instances → second exits after focusing the first.
9. handle: Chrome writing the cookie DB (WAL) while we read → read-only open, busy timeout, no copy of the secret file.
10. handle: settings change (cookie cleared) while a fetch is in flight → stale result discarded by a revision counter.

Idempotency
11. handle: the same threshold reading on every poll → one notification per threshold per reset window.
12. handle: one outage → at most one Sentry event per provider/code until recovery.

Timeouts
13. handle: claude.ai hangs → 20 s request timeout, last values kept and marked stale.
14. handle: Codex app-server cold start up to ~20 s → 45 s budget; whole process group killed on any exit.
15. handle: keyring prompt never answered in the background → background reads never prompt.

Retries
16. handle: failures retry only on the next scheduled poll; no tight loops (cadence anchored to start times, minimum 1 s).

Partial failure
17. handle: Claude fails, Codex works → tray shows Codex alone; Claude marked stale/last known.
18. handle: one auxiliary cookie undecryptable → dropped; `sessionKey` failure fails the profile.
19. handle: no tray host → fallback status window instead of an invisible app.

Auth and authz
20. handle: 401/403 → SignIn, values cleared, Settings asks to detect again; never reported.
21. handle: keyring locked or denied → Keyring error with guidance; never reported.
22. handle: Codex signed in with an API key → SignIn with guidance.

Data limits
23. handle: response bodies > 1 MiB, Codex output > 1 MiB, cookie values > 32 KiB, > 128 cookie rows → rejected.
24. handle: threshold memory bounded to 256 keys.

Migration paths
25. out: no earlier Linux release; settings start empty. Versioned `settings.json` (`"version": 1`) so later changes can migrate.

Observability
26. handle: Sentry events carry provider and code only, under the macOS policy; opt-out in Settings stops sending immediately.
27. defer: native crashes (WebKitGTK segfaults) are not captured; Rust panics are.
