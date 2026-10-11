# Spec-only test author packet

Read only this packet and docs/plans/2026-10-11-chrome-cookie-refresh.md. Do not
inspect production implementations, parent chat or other repository source.
Write only Tests/ChromeCookieReaderTests.swift and Tests/run.sh.
Use a standalone dependency-free Swift executable, Foundation, CommonCrypto and
SQLite3. Tests must use disposable directories/databases and injected passwords;
never access real Chrome or Keychain. Public contracts (implementation pending):

```swift
struct ChromeProfile: Equatable { let id: String; let name: String }
struct ChromeSession { let profile: ChromeProfile; let cookieHeader: String }
struct ChromeCookieReader {
  init(root: URL, passwordProvider: @escaping (Bool) throws -> Data)
  func discover(profileID: String? = nil, allowInteraction: Bool = false,
                now: Date = Date()) throws -> [ChromeSession]
  static func decrypt(_ encrypted: Data, host: String, version: Int,
                      password: Data) throws -> String
  static func validateHeader(_ header: String) -> Bool
}
enum RefreshSchedule {
  static let usageInterval: TimeInterval // 60
  static let cookieInterval: TimeInterval // 3600
  static let updateInterval: TimeInterval // 10800
}
```

Chrome root has Default and Profile N subdirectories, Local State optionally
contains profile.info_cache[id].name. Each profile can have Cookies or
Network/Cookies. Minimal fixture DB: meta(key TEXT PRIMARY KEY, value TEXT),
cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,
expires_utc INTEGER,is_secure INTEGER,top_frame_site_key TEXT).
expires_utc is microseconds since 1601-01-01; 0 is a session cookie.
Only host claude.ai or .claude.ai, paths applicable to /api/ requests, unexpired
and unpartitioned cookies are eligible. Require sessionKey. No matching session
returns []; unreadable/malformed relevant storage throws. Discovery scans every
profile and may return multiple sessions; selection belongs to the UI layer.
Pinned discovery reads only that profile; invalid/traversing IDs throw.
Header validation: semicolon-delimited name=value; require nonempty sessionKey,
reject duplicate sessionKey, control/non-ASCII/injection characters and >16384 UTF8
bytes. At most 128 eligible cookie rows (129 throws). Cookie values can contain =.
Decryption: v10 prefix, PBKDF2-HMAC-SHA1(password,saltysalt,1003), AES128 CBC,
16 space IV, PKCS7. v24+ plaintext starts with SHA256(host) which must match.
Unknown prefix, invalid padding, invalid UTF8, mismatched domain hash throw.

Use assert-style tests with clear failures and exit nonzero. Compile app/ChromeCookies.swift
and your tests into a temporary directory. Compiler available at
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
Use a temporary -module-cache-path and -lsqlite3. Include deterministic invalid
input fuzz and WAL/busy-lock scenarios, record seed/budget. Identify ambiguities
instead of relaxing expectations. Return explicit Assumptions and Not handled.
