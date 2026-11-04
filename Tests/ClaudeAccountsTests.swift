import Foundation
import AppKit
import Security
import SQLite3
import CommonCrypto

// Spec-only: docs/plans/2026-10-31-claude-multi-account.md, A-F.
// No new app implementation was read. Run as a separate acceptance executable.
// Plan: credential boundary -> migration -> account lifecycle/faults -> identity
// -> menu -> per-account history. The plan's What can go wrong table is the oracle.
// All HTTP is intercepted; all secrets, Chrome roots and keychains are disposable.
// Budgets: 4s per asynchronous observation, 5s maximum blocked Chrome read.
// Parser breadth: deterministic boundary table and a 128-scalar ASCII scan;
// no random seed, production load, live provider, or mutation testing is used.
//
// Assumptions (the spec does not fully spell these out):
// - UsageManager's injectable init retains its existing arguments, then appends
//   accountID: String? and credentials: CredentialStore, in that order.
// - Duplicate sessions compare sessionKey even if auxiliary cookies/org differ.
// - Several Chrome profiles sharing one session represent one new session.
// - Organization UUIDs use UUID equality; a missing/mismatching membership gives
//   nil organizationName, and an oversized name does not invalidate the email.
// - Badge positions refer to the supplied account order, including unavailable
//   options; a collision anywhere changes every badge to its numeric position.
// - Notification history does not advance while global alerts are disabled.
// - Pending credential deletions remain queued after a failed launch retry.
// Not handled through A-F's declared seams: notification delivery/text, a real
// Refresh approval prompt, diagnostics payload capture (failure row 20), Keychain
// ACL/signature UI, section G, and deferred rows 17-19. Background no-prompt
// behavior (rows 11/14) is checked on EVERY fake credential read. No API stubs.

private var checks = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fputs("FAIL ClaudeAccounts: \(message)\n", stderr); exit(1) }
}
private func wait(_ message: String, timeout: TimeInterval = 4, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(predicate(), "bounded wait: \(message)")
}
private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
private let organization = "11111111-2222-4333-8444-555555555555"
private let otherOrganization = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
private let identityUUID = "12345678-1234-4234-8234-123456789ABC"
private let otherUser = "87654321-4321-4321-8321-CBA987654321"
private func cookie(_ session: String, org: String = organization) -> String {
    "sessionKey=synthetic-\(session); lastActiveOrg=\(org)"
}
private func key(_ id: String, _ suffix: String) -> String { "claude_account.\(id).\(suffix)" }
private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func usage(_ percent: Double) -> Data {
    json(["five_hour": ["utilization": percent, "resets_at": "2099-01-01T00:00:00Z"],
          "seven_day": ["utilization": 19, "resets_at": "2099-01-08T00:00:00Z"]])
}
private func identity(email: String = "alice@example.test", uuid: String = identityUUID,
                      org: String = organization, name: String = "Synthetic organization") -> Data {
    json(["email_address": email, "uuid": uuid,
          "memberships": [["organization": ["uuid": org, "name": name]]]])
}

private final class FakeCredentials: CredentialStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var readLog: [(String, Bool)] = []
    private var writeLog: [(String, String)] = []
    private var deleteLog: [String] = []
    private var readFault: CredentialStoreError?
    private var writeFault: CredentialStoreError?
    private var deleteFault: CredentialStoreError?
    var readError: CredentialStoreError? {
        get { lock.lock(); defer { lock.unlock() }; return readFault }
        set { lock.lock(); readFault = newValue; lock.unlock() }
    }
    var writeError: CredentialStoreError? {
        get { lock.lock(); defer { lock.unlock() }; return writeFault }
        set { lock.lock(); writeFault = newValue; lock.unlock() }
    }
    var deleteError: CredentialStoreError? {
        get { lock.lock(); defer { lock.unlock() }; return deleteFault }
        set { lock.lock(); deleteFault = newValue; lock.unlock() }
    }
    var reads: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return readLog }
    var writes: [(String, String)] { lock.lock(); defer { lock.unlock() }; return writeLog }
    var deletions: [String] { lock.lock(); defer { lock.unlock() }; return deleteLog }
    var contents: [String: String] { lock.lock(); defer { lock.unlock() }; return values }
    func seed(_ secret: String, account: String) { lock.lock(); values[account] = secret; lock.unlock() }
    func read(account: String, allowInteraction: Bool) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        readLog.append((account, allowInteraction))
        if let readFault { throw readFault }
        return values[account]
    }
    func write(_ secret: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        writeLog.append((account, secret))
        if let writeFault { throw writeFault }
        values[account] = secret
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        deleteLog.append(account)
        if let deleteFault { throw deleteFault }
        values.removeValue(forKey: account)
    }
}

private enum Endpoint: Equatable { case usage, identity, auxiliary, unknown }
private struct Reply {
    var status = 200
    var data = Data("{}".utf8)
    var error: URLError.Code? = nil
    var held = false
}
private final class OfflineServer {
    struct Rule { let endpoint: Endpoint; let header: String; let reply: Reply }
    private let lock = NSLock()
    private var rules: [Rule] = []
    private var seen: [(Endpoint, URLRequest)] = []
    private var pending: [(Endpoint, String, AccountsProtocol, Reply)] = []
    private var allowedHeaders = Set<String>()
    private var unexpected = 0
    // Chrome's full header may list the same cookies in a different order.
    // The contract specifies cookie contents, not Chrome serialization order.
    private func canonicalCookie(_ header: String) -> String {
        header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.sorted().joined(separator: "; ")
    }
    func expect(_ endpoint: Endpoint, _ header: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        allowedHeaders.insert(canonicalCookie(header))
        rules.append(Rule(endpoint: endpoint, header: header, reply: reply))
    }
    func fetch(_ header: String, percent: Double = 37, identity identityReply: Reply? = Reply()) {
        expect(.usage, header, Reply(data: usage(percent)))
        if let identityReply { expect(.identity, header, identityReply) }
    }
    var requests: [(Endpoint, URLRequest)] { lock.lock(); defer { lock.unlock() }; return seen }
    var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
    var unusedCount: Int { lock.lock(); defer { lock.unlock() }; return rules.count }
    func count(_ endpoint: Endpoint, _ header: String? = nil) -> Int {
        requests.filter { $0.0 == endpoint && (header == nil || $0.1.value(forHTTPHeaderField: "Cookie") == header) }.count
    }
    func hasHeld(_ endpoint: Endpoint) -> Bool {
        lock.lock(); defer { lock.unlock() }; return pending.contains { $0.0 == endpoint }
    }
    func handle(_ transport: AccountsProtocol) {
        let request = transport.request
        let url = request.url
        let path = url?.path ?? ""
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let usagePath = path.hasPrefix("/api/organizations/") && path.hasSuffix("/usage")
        let auxiliary = (usagePath && items.count == 2 &&
            items.contains { $0.name == "cedar_ember" && $0.value == "1" } &&
            items.contains { $0.name == "skip_spend" && $0.value == "1" }) ||
            (path.hasPrefix("/api/organizations/") && items.isEmpty &&
                (path.hasSuffix("/overage_spend_limit") || path.hasSuffix("/prepaid/credits")))
        let endpoint: Endpoint = path == "/api/account" && items.isEmpty ? .identity :
            usagePath && items.isEmpty ? .usage : auxiliary ? .auxiliary : .unknown
        let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
        lock.lock()
        seen.append((endpoint, request))
        let safe = url?.scheme == "https" && url?.host == "claude.ai" && request.httpMethod == "GET"
        var reply: Reply?
        if safe && endpoint == .auxiliary && allowedHeaders.contains(canonicalCookie(header)) { reply = Reply() }
        else if safe, let index = rules.firstIndex(where: { $0.endpoint == endpoint && canonicalCookie($0.header) == canonicalCookie(header) }) {
            reply = rules.remove(at: index).reply
        }
        guard let reply else {
            unexpected += 1; lock.unlock()
            transport.client?.urlProtocol(transport, didFailWithError: URLError(.unsupportedURL)); return
        }
        if reply.held { pending.append((endpoint, header, transport, reply)) }
        lock.unlock()
        if !reply.held { transport.deliver(reply) }
    }
    func release(_ endpoint: Endpoint) {
        lock.lock()
        let batch = pending.filter { $0.0 == endpoint }
        pending.removeAll { $0.0 == endpoint }
        lock.unlock()
        batch.forEach { $0.2.deliver($0.3) }
    }
}
private final class AccountsProtocol: URLProtocol {
    static let lock = NSLock()
    static var servers: [String: OfflineServer] = [:]
    static var unownedRequests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let server = Self.servers[request.value(forHTTPHeaderField: "X-Acceptance-Fixture") ?? ""]
        if server == nil { Self.unownedRequests += 1 }
        Self.lock.unlock()
        if let server { server.handle(self) }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    }
    override func stopLoading() {} // Deliver deliberately late completions after cancel.
    func deliver(_ reply: Reply) {
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        guard let url = request.url else { check(false, "offline request URL"); return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class Fixture {
    let suite = "LimitFuel.Acceptance.\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let store = FakeCredentials()
    let server = OfflineServer()
    let session: URLSession
    var owners: [ClaudeAccounts] = []
    init(_ base: URL) throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "usage_notifications_enabled")
        defaults.set(false, forKey: "status_notifications_enabled")
        defaults.set(false, forKey: "diagnostics_enabled")
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountsProtocol.self]
        config.httpAdditionalHeaders = ["X-Acceptance-Fixture": suite]
        session = URLSession(configuration: config)
        AccountsProtocol.lock.lock(); AccountsProtocol.servers[suite] = server; AccountsProtocol.lock.unlock()
    }
    func reader() -> ChromeCookieReader {
        ChromeCookieReader(root: root, passwordProvider: { _ in Data("synthetic-password".utf8) })
    }
    func load(reader: ChromeCookieReader? = nil) -> ClaudeAccounts {
        let result = ClaudeAccounts(defaults: defaults, credentials: store,
            chromeReader: reader ?? self.reader(), apiSession: session, delegate: nil)
        owners.append(result)
        return result
    }
    func seed(_ id: String, header: String, sync: Bool = false, profile: String? = nil) {
        var ids = defaults.stringArray(forKey: "claude_account_ids") ?? []
        ids.append(id); defaults.set(ids, forKey: "claude_account_ids")
        defaults.set(sync, forKey: key(id, "chrome_sync"))
        if let profile { defaults.set(profile, forKey: key(id, "chrome_profile_id")) }
        store.seed(header, account: id)
    }
    func finish() {
        settle()
        check(server.unexpectedCount == 0, "no unexpected HTTP, retries or unknown endpoints")
        check(server.unusedCount == 0, "every declared usage/identity request occurred")
        check(store.reads.allSatisfy { !$0.1 }, "ALL background own-item reads forbid Keychain interaction (11,14)")
        session.invalidateAndCancel()
        owners.removeAll()
        defaults.removePersistentDomain(forName: suite)
        AccountsProtocol.lock.lock(); AccountsProtocol.servers.removeValue(forKey: suite); AccountsProtocol.lock.unlock()
        try? FileManager.default.removeItem(at: root)
    }
}
private func withFixture(_ base: URL, _ body: (Fixture) throws -> Void) throws {
    let f = try Fixture(base); defer { f.finish() }; try body(f)
}
private func noLegacyFlags(_ defaults: UserDefaults) {
    for old in ["claude_session_cookie", "chrome_detection_enabled", "chrome_profile_id", "last_notified_threshold"] {
        check(defaults.object(forKey: old) == nil, "legacy key removed: \(old)")
    }
}
private func noPlaintext(_ f: Fixture) {
    let values = f.defaults.persistentDomain(forName: f.suite) ?? [:]
    check(!String(describing: values).contains("sessionKey="), "no Cookie header in account metadata")
}
private let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private func chromeDB(_ root: URL, profile: String = "Default", session: String = "chrome",
                      encrypted: Data = Data()) throws {
    let directory = root.appendingPathComponent(profile)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    check(sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK, "open disposable Cookies")
    defer { sqlite3_close(db) }
    check(sqlite3_exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO meta VALUES('version','23'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,top_frame_site_key TEXT)", nil, nil, nil) == SQLITE_OK, "fixture schema")
    for (name, value) in [("sessionKey", encrypted.isEmpty ? "synthetic-\(session)" : ""), ("lastActiveOrg", organization)] {
        var stmt: OpaquePointer?
        check(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES('.claude.ai',?,?,?,'/',0,1,'')", -1, &stmt, nil) == SQLITE_OK, "prepare fixture row")
        sqlite3_bind_text(stmt, 1, name, -1, sqlTransient)
        sqlite3_bind_text(stmt, 2, value, -1, sqlTransient)
        if name == "sessionKey" && !encrypted.isEmpty {
            _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32($0.count), sqlTransient) }
        } else { sqlite3_bind_null(stmt, 3) }
        check(sqlite3_step(stmt) == SQLITE_DONE, "insert synthetic cookie")
        sqlite3_finalize(stmt)
    }
}
private func encryptedSession(_ session: String) throws -> Data {
    let pass = Array("synthetic-password".utf8), salt = Array("saltysalt".utf8)
    var aesKey = [UInt8](repeating: 0, count: 16)
    let derivation = pass.withUnsafeBytes {
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), $0.baseAddress!.assumingMemoryBound(to: Int8.self),
            pass.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &aesKey, 16)
    }
    check(derivation == kCCSuccess, "synthetic encryption key")
    let bytes = Array("synthetic-\(session)".utf8), iv = [UInt8](repeating: 32, count: 16)
    var output = [UInt8](repeating: 0, count: bytes.count + 16), written = 0
    let capacity = output.count
    check(CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
        aesKey, 16, iv, bytes, bytes.count, &output, capacity, &written) == kCCSuccess, "encrypt disposable session")
    return Data("v10".utf8) + Data(output.prefix(written))
}
private final class ChromeGate {
    private let lock = NSLock()
    private var calls: [Bool] = []
    let release = DispatchSemaphore(value: 0)
    var interactions: [Bool] { lock.lock(); defer { lock.unlock() }; return calls }
    func password(_ interactive: Bool) throws -> Data {
        lock.lock(); calls.append(interactive); lock.unlock()
        guard release.wait(timeout: .now() + 5) == .success else { throw ChromeCookieError.keychain }
        return Data("synthetic-password".utf8)
    }
}

@main struct ClaudeAccountsTests {
    static func main() throws {
        _ = NSApplication.shared
        guard let location = ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] else {
            check(false, "CLAUDE_TEST_TMPDIR is required; never fall back to a user's keychain/Chrome"); return
        }
        let base = URL(fileURLWithPath: location).appendingPathComponent("claude-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try credentialRoundTrip(base)
        try migrationBranches(base)
        try manualAdds(base)
        try chromeDiscovery(base)
        try pinnedProfileSwitchedUser(base)
        try removeAndRetry(base)
        try removedHTTPReplies(base)
        try removedChromeReply(base)
        try credentialReadFaults(base)
        try accountIsolation(base)
        parseIdentityTable()
        try identityRequests(base)
        try duplicateResolvedAccounts(base)
        menuAccounts()
        try perAccountHistory(base)
        check(AccountsProtocol.unownedRequests == 0, "no HTTP escaped fixture routing")
        print("PASS ClaudeAccounts: \(checks) checks; contract A-F, offline fixtures; syntax alone is not runtime proof")
    }

    // A; 11/14 are additionally checked through FakeCredentials on every fixture.
    static func credentialRoundTrip(_ base: URL) throws {
        let path = base.appendingPathComponent("isolated.keychain-db").path
        let password = "synthetic-keychain-password"
        var keychain: SecKeychain?
        let created = password.withCString { bytes in
            path.withCString { SecKeychainCreate($0, UInt32(password.utf8.count), bytes, false, nil, &keychain) }
        }
        check(created == errSecSuccess && keychain != nil, "create dedicated unlocked keychain")
        guard let keychain else { return }
        defer { check(SecKeychainDelete(keychain) == errSecSuccess, "delete dedicated keychain") }
        check(password.withCString { SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true) } == errSecSuccess,
              "unlock only the temporary keychain")
        let service = "LimitFuel.Acceptance.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service, keychain: keychain)
        let missing = try store.read(account: "absent", allowInteraction: false)
        check(missing == nil, "missing credential returns nil")
        try store.delete(account: "absent")
        for secret in [cookie("roundtrip"), cookie("replacement") + "; auxiliary=a=b; unicode=é"] {
            try store.write(secret, account: "first")
            let actual = try store.read(account: "first", allowInteraction: false)
            check(actual == secret, "full UTF-8 Cookie round-trip and replace")
        }
        try store.write(cookie("second"), account: "second")
        let isolated = KeychainCredentialStore(service: service + ".other", keychain: keychain)
        let otherService = try isolated.read(account: "first", allowInteraction: false)
        check(otherService == nil, "service isolation")
        try store.delete(account: "first"); try store.delete(account: "first")
        let deleted = try store.read(account: "first", allowInteraction: false)
        let second = try store.read(account: "second", allowInteraction: false)
        check(deleted == nil, "delete and delete-missing")
        check(second == cookie("second"), "deleting one account preserves another")
    }

    // B: all load/migration branches; rows 6,9,15,16.
    static func migrationBranches(_ base: URL) throws {
        for flag: Bool? in [nil, false, true] {
            try withFixture(base) { f in
                if let flag { f.defaults.set(flag, forKey: "chrome_detection_enabled") }
                f.defaults.set("Default", forKey: "chrome_profile_id")
                f.defaults.set(75, forKey: "last_notified_threshold")
                let accounts = f.load()
                check(accounts.accounts.isEmpty, "no legacy cookie creates no account")
                check(f.defaults.stringArray(forKey: "claude_account_ids") == [], "empty account list persisted")
                check(f.defaults.bool(forKey: "claude_accounts_auto_add") == (flag ?? true), "first-run adoption honors legacy flag")
                noLegacyFlags(f.defaults)
                _ = f.load(); settle()
                check(f.server.requests.isEmpty && f.store.writes.isEmpty, "empty migration is idempotent and offline")
            }
        }
        for flag: Bool? in [nil, false, true] {
            try withFixture(base) { f in
                f.seed("existing", header: cookie("existing"))
                f.defaults.set(cookie("legacy"), forKey: "claude_session_cookie")
                if let flag { f.defaults.set(flag, forKey: "chrome_detection_enabled") }
                f.defaults.set("Profile 7", forKey: "chrome_profile_id")
                f.defaults.set(90, forKey: "last_notified_threshold")
                let neverReadChrome = ChromeCookieReader(root: f.root, passwordProvider: { _ in
                    check(false, "migration must not request Chrome Safe Storage"); throw ChromeCookieError.keychain
                })
                let first = f.load(reader: neverReadChrome)
                check(first.accounts.count == 2 && first.accounts[0].accountID == "existing", "migration appends in order")
                let id = first.accounts[1].accountID
                check(f.store.contents[id] == cookie("legacy"), "legacy credential stored under new id")
                check(f.defaults.bool(forKey: key(id, "chrome_sync")) == (flag ?? false), "legacy saved cookie defaults to manual")
                check(f.defaults.string(forKey: key(id, "chrome_profile_id")) == "Profile 7", "legacy pin kept")
                check(f.defaults.integer(forKey: key(id, "last_notified_threshold")) == 90, "legacy alert history kept")
                noLegacyFlags(f.defaults); noPlaintext(f)
                let writes = f.store.writes.count
                let again = f.load()
                check(again.accounts.map(\.accountID) == ["existing", id], "reload preserves ids and order")
                check(f.store.writes.count == writes, "reload never rewrites migrated credential")
                check(f.server.requests.isEmpty, "migration never fetches usage/identity or Chrome Safe Storage")
            }
        }
        // A crash after write but before deleting plaintext: equal sessionKey,
        // intentionally different auxiliary cookies; no new credential/id.
        try withFixture(base) { f in
            f.seed("already-written", header: cookie("crash") + "; extra=new")
            f.defaults.set(cookie("crash") + "; extra=old", forKey: "claude_session_cookie")
            f.defaults.set(true, forKey: "chrome_detection_enabled")
            f.defaults.set(75, forKey: "last_notified_threshold")
            let accounts = f.load()
            check(accounts.accounts.map(\.accountID) == ["already-written"], "same session migration cannot duplicate after crash")
            check(f.store.writes.isEmpty && f.store.contents["already-written"] == cookie("crash") + "; extra=new", "stored credential wins crash recovery")
            noLegacyFlags(f.defaults)
            _ = f.load(); check(f.store.writes.isEmpty, "crash recovery is idempotent")
        }
        for error in [CredentialStoreError.interactionRequired, .failure(errSecIO)] {
            try withFixture(base) { f in
                f.defaults.set(cookie("pending"), forKey: "claude_session_cookie")
                f.defaults.set(true, forKey: "chrome_detection_enabled")
                f.defaults.set("Default", forKey: "chrome_profile_id")
                f.defaults.set(75, forKey: "last_notified_threshold")
                f.store.writeError = error
                let first = f.load()
                check(first.accounts.count == 1, "failed migration still exposes working account")
                let id = first.accounts[0].accountID
                check(f.defaults.bool(forKey: key(id, "legacy_cookie_pending")), "failed migration marked pending")
                check(f.defaults.string(forKey: "claude_session_cookie") == cookie("pending"), "failed write retains plaintext")
                check(f.store.contents.isEmpty, "failed write never claims custody")
                f.server.fetch(cookie("pending"))
                first.fetchAll()
                wait("pending legacy session still fetches") { first.accounts[0].hasFetchedData && !first.accounts[0].isLoading }
                wait("pending identity attempted") { f.server.count(.identity) == 1 }
                let stillPending = f.load()
                check(stillPending.accounts.map(\.accountID) == [id], "another failed load never appends a pending duplicate")
                check(f.defaults.string(forKey: "claude_session_cookie") == cookie("pending") &&
                      f.defaults.bool(forKey: key(id, "legacy_cookie_pending")), "failed retry preserves pending plaintext custody")
                f.store.writeError = nil
                let attempts = f.store.writes.count
                let next = f.load()
                check(next.accounts.map(\.accountID) == [id], "migration retry reuses pending id")
                check(f.store.writes.count == attempts + 1 && f.store.contents[id] == cookie("pending"), "next load retries custody")
                check(!f.defaults.bool(forKey: key(id, "legacy_cookie_pending")), "successful retry clears pending")
                check(f.defaults.integer(forKey: key(id, "last_notified_threshold")) == 75, "retry preserves threshold")
                noLegacyFlags(f.defaults)
                _ = f.load(); check(f.store.writes.count == attempts + 1, "successful retry is final")
            }
        }
        // Existing accounts without a legacy cookie are preserved, including a
        // deliberately disabled auto-add setting after the user removed all.
        for empty in [false, true] {
            try withFixture(base) { f in
                f.defaults.set([String](), forKey: "claude_account_ids")
                f.defaults.set(false, forKey: "claude_accounts_auto_add")
                if !empty {
                    f.seed("primary", header: cookie("primary"))
                    f.seed("secondary", header: cookie("secondary"))
                }
                _ = f.load()
                let manager = UsageManager(statusItem: nil, delegate: nil, defaults: f.defaults,
                    chromeReader: f.reader(), apiSession: f.session, accountID: nil, credentials: f.store)
                let ids = f.defaults.stringArray(forKey: "claude_account_ids") ?? []
                check(ids.count == (empty ? 1 : 2) && manager.accountID == ids.first, "nil accountID selects or creates primary")
                if !empty { check(manager.accountID == "primary", "nil accountID reuses first existing id") }
                else { check(!f.defaults.bool(forKey: key(manager.accountID, "chrome_sync")), "created primary inherits auto-add false") }
                check(f.server.requests.isEmpty, "primary construction stays offline")
            }
        }
        try withFixture(base) { f in
            f.defaults.set([String](), forKey: "claude_account_ids")
            f.defaults.set(true, forKey: "claude_accounts_auto_add")
            let manager = UsageManager(statusItem: nil, delegate: nil, defaults: f.defaults,
                chromeReader: f.reader(), apiSession: f.session, accountID: nil, credentials: f.store)
            check(f.defaults.bool(forKey: key(manager.accountID, "chrome_sync")), "new primary inherits auto-add true")
        }
    }

    // C manual adds; rows 1,7,10.
    static func manualAdds(_ base: URL) throws {
        try withFixture(base) { f in
            let accounts = f.load()
            let before = f.defaults.persistentDomain(forName: f.suite)! as NSDictionary
            let invalid = ["", "aux=one", "sessionKey=", "sessionKey=x\r\nInjected: yes",
                           "sessionKey=x\u{0000}", "sessionKey=" + String(repeating: "x", count: 1_048_577)]
            for header in invalid {
                check(!accounts.addManualCookie(header), "invalid manual header rejected")
                check(accounts.accounts.isEmpty && accounts.chromeMessage != nil, "invalid add reports failure without account")
                check(f.store.writes.isEmpty && f.server.requests.isEmpty, "invalid add has no secret or HTTP side effect")
                check((f.defaults.persistentDomain(forName: f.suite)! as NSDictionary) == before, "invalid add persists nothing")
            }
            for fault in [CredentialStoreError.interactionRequired, .failure(errSecIO)] {
                f.store.writeError = fault
                check(!accounts.addManualCookie(cookie("write-fault")), "credential write failure rejects manual add")
                check(accounts.accounts.isEmpty && accounts.chromeMessage != nil && f.store.contents.isEmpty, "failed manual custody never publishes account")
                check((f.defaults.persistentDomain(forName: f.suite)! as NSDictionary) == before, "failed add persists no metadata/auto-add change")
            }
            f.store.writeError = nil
            let valid = cookie("manual") + "; auxiliary=a=b"
            f.server.fetch(valid)
            check(accounts.addManualCookie(" \n\t" + valid + " \t\n"), "trimmed valid manual cookie accepted")
            check(accounts.accounts.count == 1, "successful add appends one account")
            let account = accounts.accounts[0], id = account.accountID
            check(f.store.contents[id] == valid, "only trimmed full Cookie stored")
            check(!f.defaults.bool(forKey: key(id, "chrome_sync")) && !f.defaults.bool(forKey: "claude_accounts_auto_add"), "manual source disables automatic adoption")
            check(f.defaults.stringArray(forKey: "claude_account_ids") == [id], "successful manual id persisted")
            wait("manual usage and identity") { account.hasFetchedData && !account.isLoading && f.server.count(.identity) == 1 }
            check(account.accountLabel == "Manual cookie", "unresolved manual identity uses literal fallback")
            let writes = f.store.writes.count
            for duplicate in [valid, cookie("manual") + "; auxiliary=different", cookie("manual", org: otherOrganization)] {
                check(!accounts.addManualCookie(duplicate), "same sessionKey rejected irrespective of other cookies")
                check(accounts.accounts.count == 1 && accounts.chromeMessage != nil, "duplicate reports message without second account")
            }
            check(f.store.writes.count == writes, "duplicates never rewrite credentials")
            noPlaintext(f)
        }
    }

    // C Chrome discovery and profile idempotency; rows 5,7,15,16.
    static func chromeDiscovery(_ base: URL) throws {
        for interactive in [false, true] {
            for autoAdd in [false, true] {
                try withFixture(base) { f in
                    f.defaults.set([String](), forKey: "claude_account_ids")
                    f.defaults.set(autoAdd, forKey: "claude_accounts_auto_add")
                    try chromeDB(f.root)
                    let accounts = f.load()
                    if interactive || autoAdd { f.server.fetch(cookie("chrome")) }
                    accounts.detectChromeSessions(interactive: interactive)
                    wait("single profile discovery") { !accounts.isDetectingChrome }
                    if interactive || autoAdd {
                        check(accounts.accounts.count == 1, "one new eligible session added directly")
                        let id = accounts.accounts[0].accountID
                        check(f.defaults.bool(forKey: key(id, "chrome_sync")), "Chrome add enables sync")
                        check(f.defaults.string(forKey: key(id, "chrome_profile_id")) == "Default", "Chrome account pinned")
                        check(f.store.contents[id]?.contains("sessionKey=synthetic-chrome") == true, "Chrome session has credential custody")
                        wait("Chrome account fetch") { accounts.accounts[0].hasFetchedData && f.server.count(.identity) == 1 }
                    } else { check(accounts.accounts.isEmpty && f.store.writes.isEmpty, "disabled first-run adoption adds nothing") }
                    noPlaintext(f)
                }
            }
        }
        for interactive in [false, true] {
            try withFixture(base) { f in
                try chromeDB(f.root, session: "first")
                try chromeDB(f.root, profile: "Profile 1", session: "second")
                let accounts = f.load()
                accounts.detectChromeSessions(interactive: interactive)
                wait("several signed-in choices") { !accounts.isDetectingChrome }
                check(accounts.accounts.isEmpty && accounts.chromeChoices.count == 2, "ambiguous sessions publish choices, add nothing")
                check(f.store.writes.isEmpty && f.server.requests.isEmpty, "choices have no credential or HTTP effects")
                f.server.fetch(cookie("second"))
                accounts.addChromeProfile("Profile 1"); accounts.addChromeProfile("Profile 1")
                wait("double-click one profile") { accounts.accounts.count == 1 && accounts.accounts[0].hasFetchedData && f.server.count(.identity) == 1 }
                check(f.store.contents.count == 1 && f.store.writes.count == 1, "double Chrome add writes one credential")
                let id = accounts.accounts[0].accountID
                check(f.defaults.string(forKey: key(id, "chrome_profile_id")) == "Profile 1", "choice pins selected profile")
                accounts.detectChromeSessions(interactive: false)
                wait("background discovery with accounts present") { !accounts.isDetectingChrome }
                check(accounts.accounts.count == 1 && f.store.writes.count == 1, "background discovery never adds with accounts present")
                check(!accounts.chromeChoices.contains { $0.id == "Profile 1" }, "pinned profiles are never offered")
            }
        }
        try withFixture(base) { f in
            try chromeDB(f.root, session: "same")
            try chromeDB(f.root, profile: "Profile 1", session: "same")
            f.server.fetch(cookie("same"))
            let accounts = f.load()
            accounts.detectChromeSessions(interactive: true)
            wait("profiles sharing one session") { !accounts.isDetectingChrome }
            check(accounts.accounts.count == 1 && accounts.chromeChoices.isEmpty, "one distinct new session is adopted once across profiles")
            wait("deduplicated Chrome account fetch") { accounts.accounts[0].hasFetchedData && f.server.count(.identity) == 1 }
            accounts.detectChromeSessions(interactive: true)
            wait("already-used session detection") { !accounts.isDetectingChrome }
            check(accounts.accounts.count == 1 && accounts.chromeChoices.isEmpty && f.store.writes.count == 1, "used session is never offered again")
        }
        // 2026-11-01 spec correction: Chrome keeps one claude.ai sign-in per profile. Signing in to
        // another Claude account in a pinned profile makes that profile's new session addable.
        try withFixture(base) { f in
            f.seed("pinned", header: cookie("older"), sync: true, profile: "Default")
            try chromeDB(f.root, session: "other")
            f.server.fetch(cookie("other"), identity: Reply(data: identity(email: "support@example.test", uuid: otherUser)))
            let accounts = f.load()
            accounts.detectChromeSessions(interactive: true)
            wait("another sign-in in a pinned profile is added") {
                accounts.accounts.count == 2 && accounts.accounts[1].email == "support@example.test"
            }
            check(f.defaults.string(forKey: key(accounts.accounts[1].accountID, "chrome_profile_id")) == "Default",
                  "the new account is pinned to the profile it came from")
            check(f.store.contents["pinned"] == cookie("older"), "adding never touches the pinned account's session")
            accounts.detectChromeSessions(interactive: true)
            wait("second detection") { !accounts.isDetectingChrome }
            check(accounts.accounts.count == 2 && accounts.chromeMessage?.contains("one claude.ai sign-in per profile") == true,
                  "nothing new explains one sign-in per Chrome profile")
        }
    }

    // An account refreshes from its profile only while that profile holds the same Claude user.
    static func pinnedProfileSwitchedUser(_ base: URL) throws {
        for (sameUser, signedOut) in [(true, false), (false, false), (false, true)] {
            try withFixture(base) { f in
                f.seed("owner", header: cookie("mine"), sync: true, profile: "Default")
                f.defaults.set(identityUUID, forKey: key("owner", "account_uuid"))
                try chromeDB(f.root, session: "theirs")
                f.server.expect(.identity, cookie("theirs"), Reply(data: identity(uuid: sameUser ? identityUUID.lowercased() : otherUser)))
                if sameUser { f.server.fetch(cookie("theirs")) }
                let accounts = f.load(), owner = accounts.accounts[0]
                if signedOut {
                    // claude.ai has already ended this account's own session.
                    f.server.expect(.usage, cookie("mine"), Reply(status: 403))
                    owner.fetchUsage()
                    wait("own session refused") { owner.needsSignIn && !owner.isLoading }
                    check(owner.errorMessage == ClaudeUsageProblem.signedOut, "a refused session reads as signed out")
                }
                owner.detectChromeSession()
                if sameUser {
                    wait("same user's new session adopted") {
                        f.store.contents["owner"]?.contains("synthetic-theirs") == true && owner.hasFetchedData
                            && f.server.count(.identity) == 2
                    }
                } else {
                    wait("other user's session checked") { f.server.count(.identity) == 1 && !owner.isDetectingChrome }
                    settle()
                    check(f.store.contents["owner"] == cookie("mine") && owner.sessionHeader == cookie("mine"),
                          "another Claude user's session never replaces this account's")
                    check(f.defaults.string(forKey: key("owner", "account_uuid")) == identityUUID,
                          "the account keeps its identity")
                    check(owner.chromeMessage?.contains("different Claude account") == true,
                          "the account explains the profile switched users")
                    if signedOut {
                        check(owner.connectionHint.contains("can't renew from it") && !owner.connectionHint.contains("keeps its saved session"),
                              "a signed-out account is not told it keeps its session")
                    } else {
                        check(owner.chromeMessage?.contains("keeps its saved session") == true, "a working account keeps its session")
                    }
                }
            }
        }
    }

    // C remove/delete reconciliation and all-removed adoption; rows 12,16.
    static func removeAndRetry(_ base: URL) throws {
        for failure in [false, true] {
            try withFixture(base) { f in
                f.seed("remove", header: cookie("remove"), sync: true, profile: "Default")
                f.seed("keep", header: cookie("keep"))
                let suffixes = ["chrome_sync", "chrome_profile_id", "chrome_profile_name", "email", "organization_name",
                                "account_uuid", "last_notified_threshold", "legacy_cookie_pending"]
                for suffix in ["chrome_profile_name", "email", "organization_name", "account_uuid"] {
                    f.defaults.set("synthetic-metadata", forKey: key("remove", suffix))
                }
                f.defaults.set(75, forKey: key("remove", "last_notified_threshold"))
                f.defaults.set(false, forKey: key("remove", "legacy_cookie_pending"))
                f.defaults.set(90, forKey: key("keep", "last_notified_threshold"))
                let accounts = f.load()
                if failure { f.store.deleteError = .failure(errSecIO) }
                accounts.remove(accounts.accounts[0])
                check(accounts.accounts.map(\.accountID) == ["keep"], "remove affects only selected account")
                check(f.defaults.stringArray(forKey: "claude_account_ids") == ["keep"], "removed id is absent durably")
                for suffix in suffixes { check(f.defaults.object(forKey: key("remove", suffix)) == nil, "remove deletes metadata \(suffix)") }
                check(f.defaults.integer(forKey: key("keep", "last_notified_threshold")) == 90, "remove preserves other alert history")
                check(!f.defaults.bool(forKey: "claude_accounts_auto_add"), "remove disables adoption")
                check(f.store.deletions == ["remove"], "remove attempts credential delete")
                if failure {
                    check(f.defaults.stringArray(forKey: "claude_credential_deletions") == ["remove"], "failed delete durably queued")
                    _ = f.load()
                    check(f.store.deletions == ["remove", "remove"], "next init retries failed deletion")
                    check(f.defaults.stringArray(forKey: "claude_credential_deletions") == ["remove"], "failed retry keeps queue")
                    f.store.deleteError = nil
                    _ = f.load()
                    check(f.store.contents["remove"] == nil, "later successful retry deletes orphan credential")
                    check((f.defaults.stringArray(forKey: "claude_credential_deletions") ?? []).isEmpty, "successful retry drains queue")
                    let attempts = f.store.deletions.count
                    _ = f.load(); check(f.store.deletions.count == attempts, "drained delete queue is idempotent")
                } else { check(f.store.contents["remove"] == nil, "successful Remove deletes credential") }
                accounts.remove(accounts.accounts[0])
                try chromeDB(f.root)
                accounts.refreshChromeAccounts(); accounts.detectChromeSessions(interactive: false)
                wait("no adoption after removing all") { !accounts.isDetectingChrome }
                check(accounts.accounts.isEmpty && f.store.writes.isEmpty, "hourly discovery never re-adds removed accounts")
                let relaunched = f.load()
                relaunched.refreshChromeAccounts(); settle()
                check(relaunched.accounts.isEmpty && f.server.requests.isEmpty, "all-removed preference survives restart")
            }
        }
    }

    // C request cancellation/generation boundaries; row 3, both endpoint classes.
    static func removedHTTPReplies(_ base: URL) throws {
        for endpoint in [Endpoint.usage, .identity] {
            try withFixture(base) { f in
                f.seed("late", header: cookie("late"))
                let accounts = f.load(), account = accounts.accounts[0]
                f.server.expect(.usage, cookie("late"), Reply(data: usage(95), held: endpoint == .usage))
                if endpoint == .identity {
                    f.server.expect(.identity, cookie("late"), Reply(data: identity(), held: true))
                }
                accounts.fetchAll()
                wait("request held before Remove") { f.server.hasHeld(endpoint) }
                accounts.remove(account)
                let writes = f.store.writes.count
                let removedUsage = account.menuBarOptions
                let removedFetched = account.hasFetchedData
                let removedEmail = account.email
                f.server.release(endpoint); settle()
                check(accounts.accounts.isEmpty && account.hasFetchedData == removedFetched && account.menuBarOptions == removedUsage,
                      "late response cannot repopulate or change removed account usage")
                check(account.email == removedEmail, "late identity cannot update detached account")
                check(f.store.contents["late"] == nil && f.store.writes.count == writes, "late response cannot recreate deleted credential")
                check(f.defaults.object(forKey: key("late", "email")) == nil && f.defaults.object(forKey: key("late", "account_uuid")) == nil, "late identity cannot recreate metadata")
                check(f.defaults.stringArray(forKey: "claude_account_ids") == [], "late response cannot restore removed id")
            }
        }
    }

    // C hourly Chrome response after removal; row 4.
    static func removedChromeReply(_ base: URL) throws {
        try withFixture(base) { f in
            f.seed("late-chrome", header: cookie("old"), sync: true, profile: "Default")
            try chromeDB(f.root, encrypted: encryptedSession("rotated"))
            let gate = ChromeGate()
            defer { gate.release.signal() }
            let reader = ChromeCookieReader(root: f.root, passwordProvider: { try gate.password($0) })
            let accounts = f.load(reader: reader), account = accounts.accounts[0]
            accounts.refreshChromeAccounts()
            wait("hourly Chrome read blocked off main") { !gate.interactions.isEmpty }
            check(gate.interactions == [false], "hourly Chrome never requests interaction")
            accounts.remove(account)
            let writes = f.store.writes.count
            gate.release.signal()
            wait("removed Chrome operation finishes") { !account.isDetectingChrome }
            settle()
            check(accounts.accounts.isEmpty && f.store.contents[account.accountID] == nil, "late Chrome refresh cannot restore account/credential")
            check(f.store.writes.count == writes && f.server.requests.isEmpty, "late Chrome result causes no writes or fetch")
            check(f.defaults.stringArray(forKey: "claude_account_ids") == [], "late Chrome refresh leaves ids empty")
        }
    }

    // A/C background denial recovery; rows 11,14. No real approval dialog.
    static func credentialReadFaults(_ base: URL) throws {
        for fault in [CredentialStoreError.interactionRequired, .failure(errSecIO)] {
            try withFixture(base) { f in
                f.seed("locked", header: cookie("locked"))
                f.store.readError = fault
                let accounts = f.load()
                accounts.fetchAll(); accounts.refreshChromeAccounts(); settle()
                check(accounts.accounts.count == 1 && !accounts.accounts[0].hasFetchedData, "read fault retains metadata account without false usage")
                check(accounts.accounts[0].errorMessage != nil || accounts.accounts[0].chromeMessage != nil || accounts.chromeMessage != nil,
                      "credential read fault is visible")
                check(!f.store.reads.isEmpty && f.store.reads.allSatisfy { !$0.1 }, "denied own-item reads never prompt")
                check(f.store.writes.isEmpty && f.store.deletions.isEmpty && f.server.requests.isEmpty, "read failure never overwrites or deletes secret")
                f.store.readError = nil
                let recovered = f.load()
                f.server.fetch(cookie("locked"))
                recovered.fetchAll()
                wait("credential becomes readable on next init") { recovered.accounts[0].hasFetchedData && f.server.count(.identity) == 1 }
            }
        }
    }

    // C independent transport/auth/Chrome faults; rows 11,13,14.
    static func accountIsolation(_ base: URL) throws {
        for status in [401, 403, 0] {
            try withFixture(base) { f in
                f.seed("a", header: cookie("a")); f.seed("b", header: cookie("b"))
                f.defaults.set(75, forKey: key("a", "last_notified_threshold"))
                f.defaults.set(90, forKey: key("b", "last_notified_threshold"))
                let accounts = f.load(), a = accounts.accounts[0], b = accounts.accounts[1]
                f.server.fetch(cookie("a"), percent: 37); f.server.fetch(cookie("b"), percent: 64)
                accounts.fetchAll()
                wait("both accounts have independent usage") { a.hasFetchedData && b.hasFetchedData && f.server.count(.identity) == 2 }
                let bOptions = b.menuBarOptions
                let bHistory = f.defaults.integer(forKey: key("b", "last_notified_threshold"))
                let reply = status == 0 ? Reply(error: .timedOut) : Reply(status: status)
                f.server.expect(.usage, cookie("a"), reply)
                let before = f.server.count(.usage, cookie("a"))
                a.fetchUsage()
                wait("one-account failure completes") { f.server.count(.usage, cookie("a")) == before + 1 && !a.isLoading }
                settle()
                check(b.hasFetchedData && b.sessionUtilization == 64 && b.menuBarOptions == bOptions, "other account keeps usage and menu entries after fault")
                check(f.defaults.integer(forKey: key("b", "last_notified_threshold")) == bHistory, "other account keeps alert history after fault")
                if status != 0 { check(!a.hasFetchedData && a.menuBarOptions.isEmpty, "401/403 drops only failing account menu data") }
            }
        }
        try withFixture(base) { f in
            f.seed("a", header: cookie("a"), sync: true, profile: "Default")
            f.seed("b", header: cookie("b"))
            f.defaults.set(90, forKey: key("b", "last_notified_threshold"))
            try chromeDB(f.root, encrypted: Data("v10".utf8) + Data(repeating: 0, count: 16))
            var interactions: [Bool] = []
            let captureLock = NSLock()
            let reader = ChromeCookieReader(root: f.root, passwordProvider: { interactive in
                captureLock.lock(); interactions.append(interactive); captureLock.unlock()
                throw ChromeCookieError.keychain
            })
            let accounts = f.load(reader: reader), a = accounts.accounts[0], b = accounts.accounts[1]
            f.server.fetch(cookie("a")); f.server.fetch(cookie("b"), percent: 64)
            accounts.fetchAll()
            wait("healthy before Chrome failure") { a.hasFetchedData && b.hasFetchedData && f.server.count(.identity) == 2 }
            let options = b.menuBarOptions
            accounts.refreshChromeAccounts()
            wait("background Chrome failure") { !a.isDetectingChrome && a.chromeMessage != nil }
            captureLock.lock(); let recorded = interactions; captureLock.unlock()
            check(recorded == [false], "background Chrome Safe Storage denial is noninteractive")
            check(b.hasFetchedData && b.menuBarOptions == options && f.defaults.integer(forKey: key("b", "last_notified_threshold")) == 90, "Chrome failure never changes another account")
        }
    }

    // D validation boundaries; row 2. Tests UTF-8 byte limits independently of
    // Swift character count, plus every ASCII control scalar and whitespace.
    static func parseIdentityTable() {
        struct Case { let data: Data; let org: String?; let email: String?; let name: String? }
        let longEmail = String(repeating: "a", count: 308) + "@example.test" // 321 bytes
        let cases: [Case] = [
            Case(data: identity(), org: organization, email: "alice@example.test", name: "Synthetic organization"),
            Case(data: Data("<html>sign in</html>".utf8), org: organization, email: nil, name: nil),
            Case(data: json(["uuid": identityUUID]), org: organization, email: nil, name: nil),
            Case(data: identity(email: String(repeating: "a", count: 387) + "@example.test"), org: organization, email: nil, name: nil),
            Case(data: identity(email: longEmail), org: organization, email: nil, name: nil),
            Case(data: identity(email: String(repeating: "a", count: 307) + "@example.test"), org: organization,
                 email: String(repeating: "a", count: 307) + "@example.test", name: "Synthetic organization"),
            Case(data: identity(email: "a@b"), org: organization, email: "a@b", name: "Synthetic organization"),
            Case(data: identity(email: "@b"), org: organization, email: nil, name: nil),
            Case(data: identity(email: "without-at"), org: organization, email: nil, name: nil),
            Case(data: identity(email: "alice@example.test "), org: organization, email: nil, name: nil),
            Case(data: identity(email: "alice@exam ple.test"), org: organization, email: nil, name: nil),
            Case(data: identity(email: String(repeating: "é", count: 160) + "@x"), org: organization, email: nil, name: nil),
            Case(data: identity(uuid: "not-a-uuid"), org: organization, email: nil, name: nil),
            Case(data: identity(), org: otherOrganization, email: "alice@example.test", name: nil),
            Case(data: identity(), org: nil, email: "alice@example.test", name: nil),
            Case(data: identity(name: String(repeating: "x", count: 101)), org: organization, email: "alice@example.test", name: nil),
            Case(data: identity(name: String(repeating: "界", count: 100)), org: organization, email: "alice@example.test", name: String(repeating: "界", count: 100)),
            Case(data: json(["email_address": 17, "uuid": identityUUID]), org: organization, email: nil, name: nil),
            Case(data: Data("[]".utf8), org: organization, email: nil, name: nil)
        ]
        for (index, item) in cases.enumerated() {
            let parsed = UsageManager.parseAccountIdentity(item.data, organizationID: item.org)
            check(parsed?.email == item.email, "identity email table case \(index)")
            check(parsed?.organizationName == item.name, "identity organization table case \(index)")
            if item.email != nil { check(parsed?.accountUUID.lowercased() == identityUUID.lowercased(), "identity UUID preserved") }
            else { check(parsed == nil, "invalid identity rejected atomically") }
        }
        for scalar in 0..<128 {
            let character = String(UnicodeScalar(scalar)!)
            if CharacterSet.controlCharacters.contains(UnicodeScalar(scalar)!) || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(scalar)!) {
                for at in [0, 5] {
                    let email = at == 0 ? character + "alice@example.test" : "alice" + character + "@example.test"
                    check(UsageManager.parseAccountIdentity(identity(email: email), organizationID: organization) == nil,
                          "control/space scalar \(scalar) rejected at \(at)")
                }
            }
        }
        let memberships: [String: Any] = ["email_address": "alice@example.test", "uuid": identityUUID,
            "memberships": [["organization": ["uuid": otherOrganization, "name": "Wrong first"]],
                            ["organization": ["uuid": organization, "name": "Right second"]]]]
        check(UsageManager.parseAccountIdentity(json(memberships), organizationID: organization)?.organizationName == "Right second", "membership matched by UUID, never first membership")
        check(UsageManager.parseAccountIdentity(identity(org: otherOrganization.lowercased()), organizationID: otherOrganization)?.organizationName == "Synthetic organization",
              "organization UUID matching is case insensitive")
    }

    // D request scope, failures and restart/session retry; rows 2,8.
    static func identityRequests(_ base: URL) throws {
        let failures = [Reply(data: Data("<html>sign in</html>".utf8)), Reply(data: json(["uuid": identityUUID])),
                        Reply(data: identity(email: String(repeating: "a", count: 400) + "@x")),
                        Reply(data: identity(email: "bad\n@example.test")), Reply(error: .timedOut)]
        for firstReply in failures {
            try withFixture(base) { f in
                f.seed("identity", header: cookie("identity"))
                let accounts = f.load(), account = accounts.accounts[0]
                check(f.server.requests.isEmpty, "init never resolves identity")
                f.server.fetch(cookie("identity"), identity: firstReply)
                accounts.fetchAll()
                wait("identity failure completes") { account.hasFetchedData && !account.isLoading && f.server.count(.identity) == 1 }
                settle()
                check(account.email == nil && account.accountLabel == "Manual cookie", "invalid/timed-out identity retains source fallback")
                for _ in 0..<2 {
                    f.server.fetch(cookie("identity"), identity: nil)
                    let before = f.server.count(.usage)
                    accounts.fetchAll(); account.fetchIdentityIfNeeded(); account.fetchIdentityIfNeeded()
                    wait("usage refetch without identity retry") { f.server.count(.usage) == before + 1 && !account.isLoading }
                }
                settle(); check(f.server.count(.identity) == 1, "identity failure is once per session per run")
                let restarted = f.load()
                f.server.fetch(cookie("identity"), identity: Reply(data: identity()))
                restarted.fetchAll()
                wait("restart retries failed identity") { restarted.accounts[0].email == "alice@example.test" }
                check(f.server.count(.identity) == 2, "restart grants exactly one new identity attempt")
            }
        }
        try withFixture(base) { f in
            f.seed("cached", header: cookie("cached"))
            f.defaults.set("remembered@example.test", forKey: key("cached", "email"))
            f.defaults.set("Remembered organization", forKey: key("cached", "organization_name"))
            f.defaults.set(identityUUID, forKey: key("cached", "account_uuid"))
            let accounts = f.load(), account = accounts.accounts[0]
            check(account.email == "remembered@example.test", "same-session cached identity loads")
            f.server.fetch(cookie("cached"), identity: Reply(data: Data("<html>unavailable</html>".utf8)))
            accounts.fetchAll()
            wait("cached identity invalid response") { account.hasFetchedData && f.server.count(.identity) == 1 }
            settle()
            check(account.email == "remembered@example.test" && account.organizationName == "Remembered organization",
                  "invalid identity response leaves cached identity unchanged")
            check(f.defaults.string(forKey: key("cached", "email")) == "remembered@example.test", "invalid identity never deletes cached metadata")
        }
        try withFixture(base) { f in
            f.seed("identity", header: cookie("first"))
            let accounts = f.load(), account = accounts.accounts[0]
            f.server.fetch(cookie("first"), identity: Reply(data: identity()))
            accounts.fetchAll()
            wait("valid identity published") { account.email == "alice@example.test" }
            check(account.accountLabel == "alice@example.test" && account.organizationName == "Synthetic organization", "resolved label and org published")
            check(f.defaults.string(forKey: key("identity", "email")) == account.email &&
                  f.defaults.string(forKey: key("identity", "account_uuid"))?.lowercased() == identityUUID.lowercased(), "identity is nonsecret account metadata")
            let identityRequest = f.server.requests.first { $0.0 == .identity }!.1
            let usageRequest = f.server.requests.first { $0.0 == .usage }!.1
            for field in ["Cookie", "User-Agent", "Accept", "Origin", "Referer"] {
                check(identityRequest.value(forHTTPHeaderField: field) == usageRequest.value(forHTTPHeaderField: field), "identity uses usage authentication/header: \(field)")
            }
            // Auxiliary cookie rotation does not change the session identity.
            let auxiliary = cookie("first") + "; auxiliary=changed"
            f.server.fetch(auxiliary, identity: nil)
            account.saveSessionCookie(auxiliary)
            wait("auxiliary cookie refresh") { account.hasFetchedData && !account.isLoading && f.server.count(.usage, auxiliary) == 1 }
            account.fetchIdentityIfNeeded(); settle()
            check(f.server.count(.identity) == 1 && account.email == "alice@example.test", "auxiliary cookie preserves once-per-identity result")
            // Both parts of (sessionKey, lastActiveOrg) independently invalidate.
            for header in [cookie("second"), cookie("second", org: otherOrganization)] {
                f.server.expect(.usage, header, Reply(data: usage(37), held: true))
                f.server.expect(.identity, header, Reply(data: identity(email: "new@example.test", org: header.contains(otherOrganization) ? otherOrganization : organization)))
                account.saveSessionCookie(header)
                check(account.email == nil && account.organizationName == nil, "new session clears published identity immediately")
                check(f.defaults.object(forKey: key("identity", "email")) == nil && f.defaults.object(forKey: key("identity", "account_uuid")) == nil, "new session clears persisted identity before resolution")
                wait("new session usage held") { f.server.hasHeld(.usage) }
                f.server.release(.usage)
                wait("new identity resolves once") { account.email == "new@example.test" }
            }
            check(f.server.count(.identity) == 3, "sessionKey change and org change each allow one request")
        }
        try withFixture(base) { f in
            f.seed("chrome", header: cookie("chrome"), sync: true, profile: "Default")
            f.defaults.set("Work profile", forKey: key("chrome", "chrome_profile_name"))
            let accounts = f.load()
            f.server.fetch(cookie("chrome"), identity: Reply(data: Data("<html>no identity</html>".utf8)))
            accounts.fetchAll()
            wait("Chrome identity fallback") { accounts.accounts[0].hasFetchedData && f.server.count(.identity) == 1 }
            settle(); check(accounts.accounts[0].accountLabel == "Work profile", "invalid identity falls back to Chrome profile name")
        }
    }

    // D resolved duplicate elimination; row 7. Deliberately resolve later first.
    static func duplicateResolvedAccounts(_ base: URL) throws {
        for sameOrg in [true, false] {
            try withFixture(base) { f in
                let second = cookie("second", org: sameOrg ? organization : otherOrganization)
                f.seed("earlier", header: cookie("first")); f.seed("later", header: second)
                let accounts = f.load()
                f.server.fetch(cookie("first"), identity: Reply(data: identity(), held: true))
                f.server.fetch(second, identity: Reply(data: identity(email: "alias@example.test", org: sameOrg ? organization : otherOrganization)))
                accounts.fetchAll()
                wait("later resolves before earlier") { accounts.accounts[1].email == "alias@example.test" && f.server.hasHeld(.identity) }
                f.server.release(.identity)
                if sameOrg {
                    wait("later duplicate removed after earlier resolves") { accounts.accounts.count == 1 }
                    check(accounts.accounts[0].accountID == "earlier", "display order chooses survivor regardless of reply order")
                    check(accounts.chromeMessage?.localizedCaseInsensitiveContains("already") == true, "duplicate identity explains already added")
                    check(f.store.contents["later"] == nil && f.defaults.stringArray(forKey: "claude_account_ids") == ["earlier"], "resolved duplicate credential/id removed")
                } else {
                    wait("both different-org identities settle") { accounts.accounts[0].email != nil }
                    check(accounts.accounts.map(\.accountID) == ["earlier", "later"], "same UUID in different organizations remains independent")
                }
            }
        }
    }

    // E: ordering, badge collisions, single-account compatibility, accessibility.
    static func menuAccounts() {
        let badges: [([String], [String?])] = [
            ([], []), (["alice@example.test"], [nil]),
            (["alice@example.test", "bob@example.test"], ["A", "B"]),
            (["alice@example.test", "Amy@example.test", "bob@example.test"], ["1", "2", "3"]),
            (["!!!@example.test", "bob@example.test"], ["1", "B"]),
            (["7alice@example.test", "2bob@example.test"], ["7", "2"]),
            (["...alice@example.test", "bob@example.test"], ["A", "B"]),
            (["@alice.example", "bob@example.test"], ["1", "B"]),
            (["", "!!!"], ["1", "2"]),
            (["Work profile", "Manual cookie"], ["W", "M"])
        ]
        for (labels, expected) in badges {
            check(MenuBarStatus.accountBadges(labels) == expected, "badge table \(labels)")
        }
        func option(_ used: Double, provider: MenuBarProvider = .claude) -> MenuBarWindowOption {
            MenuBarWindowOption(id: "session", provider: provider, label: "Session", percent: used,
                durationMinutes: 300, isPreferredBucket: true, resetsAt: Date(timeIntervalSince1970: 4_000_000_000))
        }
        let updated = Date(timeIntervalSince1970: 2_000_000_000)
        for mode: MenuBarPercentageMode? in [nil, .used, .remaining] {
            for stale in [false, true] {
                let account = ClaudeMenuBarAccount(option: option(58), isStale: stale, updatedAt: updated, label: "alice@example.test")
                let old = MenuBarStatus.selectedEntries(claude: option(58), codex: option(12, provider: .codex),
                    claudeIsStale: stale, claudeUpdatedAt: updated, percentageMode: mode)
                let new = MenuBarStatus.selectedEntries(claudeAccounts: [account], codex: option(12, provider: .codex), percentageMode: mode)
                check(new == old && new.first?.badge == nil, "single-account API preserves exact legacy output")
            }
        }
        let entries = MenuBarStatus.selectedEntries(claudeAccounts: [
            ClaudeMenuBarAccount(option: option(58), isStale: true, updatedAt: updated, label: "alice@example.test"),
            ClaudeMenuBarAccount(option: nil, label: "no-data@example.test"),
            ClaudeMenuBarAccount(option: option(23), label: "bob@example.test")
        ], codex: option(12, provider: .codex), codexIsStale: true, codexUpdatedAt: updated, percentageMode: .remaining)
        check(entries.count == 3 && entries.map(\.provider) == [.claude, .claude, .codex], "available Claude accounts in input order, then Codex")
        check(entries.map(\.percent) == [42, 77, 88], "each account's own valid option supplies percentage")
        check(entries[0].accountLabel == "alice@example.test" && entries[1].accountLabel == "bob@example.test", "entries carry their own account labels")
        check(entries[0].badge == "A" && entries[1].badge == "B" && entries[2].badge == nil, "badges belong only to Claude accounts")
        check(entries[0].isStale && entries[0].updatedAt == updated && !entries[1].isStale && entries[2].isStale, "per-account stale/update metadata independent")
        let accessible = MenuBarStatus.accessibilityLabel(for: entries)
        check(accessible.contains("Claude alice@example.test 42% remaining") && accessible.contains("Claude bob@example.test 77% remaining"), "badged accessibility identifies each account and percentage meaning")
        var withoutBadges = entries
        for index in withoutBadges.indices { withoutBadges[index].badge = nil }
        check(MenuBarStatus.image(for: entries).size.width == MenuBarStatus.image(for: withoutBadges).size.width, "badge overlay never changes entry width")
        let positioned = MenuBarStatus.selectedEntries(claudeAccounts: [
            ClaudeMenuBarAccount(option: option(0), label: "alice@example.test"),
            ClaudeMenuBarAccount(option: nil, label: "amy@example.test"),
            ClaudeMenuBarAccount(option: option(100), label: "bob@example.test")
        ], codex: nil, percentageMode: .used)
        check(positioned.map(\.badge) == ["1", "3"] && positioned.map(\.percent) == [0, 100], "collision positions use complete input order and retain 0%")
        for invalid in [Double.nan, .infinity, -1, 101] {
            let invalidEntries = MenuBarStatus.selectedEntries(claudeAccounts: [
                ClaudeMenuBarAccount(option: option(invalid), label: "alice@example.test"),
                ClaudeMenuBarAccount(option: option(23), label: "bob@example.test")
            ], codex: nil)
            check(invalidEntries.count == 1 && invalidEntries[0].accountLabel == "bob@example.test", "invalid account option cannot poison another entry")
        }
        check(MenuBarStatus.selectedEntries(claudeAccounts: [], codex: nil).isEmpty, "empty accounts are disconnected")
    }

    // F: independent persistence and read-at-due global disabled switch.
    // Seeded histories avoid delivering any notification to the real desktop.
    static func perAccountHistory(_ base: URL) throws {
        try withFixture(base) { f in
            f.seed("a", header: cookie("a")); f.seed("b", header: cookie("b"))
            f.defaults.set(90, forKey: key("a", "last_notified_threshold"))
            f.defaults.set(75, forKey: key("b", "last_notified_threshold"))
            let accounts = f.load(), a = accounts.accounts[0], b = accounts.accounts[1]
            // Both histories already exceed or equal the parsed level. Nothing
            // should notify, and one manager cannot load the other's history.
            f.defaults.set(true, forKey: "usage_notifications_enabled")
            for _ in 0..<2 {
                a.parseUsageData(usage(95)); a.updateStatusBar()
                b.parseUsageData(usage(80)); b.updateStatusBar()
                check(f.defaults.integer(forKey: key("a", "last_notified_threshold")) == 90, "A retains its own dedupe threshold")
                check(f.defaults.integer(forKey: key("b", "last_notified_threshold")) == 75, "B retains independent dedupe threshold")
            }
            // Change the global preference AFTER both managers were created.
            // Clearing only B resets B; disabling alerts must then suppress its
            // due threshold without using a cached true preference.
            f.defaults.set(false, forKey: "usage_notifications_enabled")
            b.clearSessionCookie()
            check(f.defaults.integer(forKey: key("a", "last_notified_threshold")) == 90, "clearing B does not reset A alert history")
            let bHistory = f.defaults.integer(forKey: key("b", "last_notified_threshold"))
            b.parseUsageData(usage(95)); b.updateStatusBar()
            check(f.defaults.integer(forKey: key("b", "last_notified_threshold")) == bHistory, "switch read when B threshold is due; disabled alerts do not advance")
            a.clearSessionCookie()
            let aHistory = f.defaults.integer(forKey: key("a", "last_notified_threshold"))
            a.parseUsageData(usage(95)); a.updateStatusBar()
            check(f.defaults.integer(forKey: key("a", "last_notified_threshold")) == aHistory, "same changed global switch applies to A")
            check(f.defaults.object(forKey: "last_notified_threshold") == nil, "no shared legacy threshold is recreated")
        }
    }
}
