import Foundation
import AppKit
import Security
import SQLite3

// Spec-only acceptance: docs/plans/2026-11-01-in-app-sign-in.md, cookie,
// outcome, completeSignIn and UsageManager contracts; failure rows 5-12, 14.
// No sign-in implementation was read. The runner prepends the testable import.
// Plan: cookies -> local rejection -> identity/credential faults -> renewal and
// removal races -> source transitions/auth recovery -> hourly Chrome exclusion.
// What can go wrong: invalid/foreign/expired cookies; duplicate sessions; account
// lookup timeout/auth/parse failures; Keychain partial writes; wrong user/org
// matching; removal during lookup; stale usage; Chrome overwriting web sign-in.
// Oracle: the persisted contract's failure list, not implementation behavior.
// All HTTP, credentials, defaults and Chrome roots are disposable. Deterministic
// tables/permutations and held replies replace random/load tests (no seed).
// Budget: 4 seconds per asynchronous observation; no retries or live services.
// Assumptions: missing-org success may attempt bootstrap; these matching tests
// inject a bootstrap timeout rather than inventing a bootstrap response schema.
// Equal path/domain duplicate ties have no specified winner and are not asserted.
// Not handled: WebKit/UI sections, real Keychain/provider/device behavior,
// compilation/execution against the concurrently written app, mutation testing.

private var checks = 0
private var tests = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fputs("FAIL ClaudeSignIn: \(message)\n", stderr); exit(1) }
}
private func wait(_ message: String, timeout: TimeInterval = 4, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(predicate(), "bounded wait: \(message)")
}
private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
private let organization = "A12BC345-6789-4DEF-8123-456789ABCDEF"
private let otherOrganization = "B23CD456-789A-4EF0-9234-56789ABCDEF0"
private let userUUID = "C34DE567-89AB-4F01-A345-6789ABCDEF01"
private let otherUserUUID = "D45EF678-9ABC-4012-B456-789ABCDEF012"
private let invalidSessionMessage = "claude.ai did not return a session. Sign in again."
private let rejectedMessage = "claude.ai rejected this sign-in. Sign in again."
private let connectionMessage = "LimitFuel could not confirm the account with claude.ai. Check your connection and try again."
private let keychainMessage = "LimitFuel could not save this session to the Keychain. Try again."
private func key(_ id: String, _ field: String) -> String { "claude_account.\(id).\(field)" }
private func header(_ token: String, org: String? = organization) -> String {
    "sessionKey=sk-ant-sid01-test-\(token)" + (org.map { "; lastActiveOrg=\($0)" } ?? "")
}
private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func identityData(email: String = "ana@example.com", uuid: String = userUUID,
                          org: String = organization) -> Data {
    json(["email_address": email, "uuid": uuid,
          "memberships": [["organization": ["uuid": org, "name": "Example workspace"]]]])
}
private func signInIdentity(email: String = "ana@example.com", uuid: String = userUUID) -> ClaudeAccountIdentity {
    ClaudeAccountIdentity(email: email, accountUUID: uuid, organizationName: "Example workspace")
}
private func usageData(_ percent: Double = 37) -> Data {
    json(["five_hour": ["utilization": percent, "resets_at": "2099-01-01T00:00:00Z"],
          "seven_day": ["utilization": 19, "resets_at": "2099-01-08T00:00:00Z"]])
}

// Use the existing in-memory implementation; only fault injection/observation is
// supplied here. A throwing write deliberately makes no underlying mutation.
private final class SignInCredentials: CredentialStore {
    private let lock = NSLock()
    private let memory = InMemoryCredentialStore()
    private var ids = Set<String>()
    private var attempts = 0
    private var failures = false
    private var interactiveReads = 0
    var failWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failures }
        set { lock.lock(); failures = newValue; lock.unlock() }
    }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var promptedReads: Int { lock.lock(); defer { lock.unlock() }; return interactiveReads }
    var contents: [String: String] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: String] = [:]
        for id in ids { result[id] = try? memory.read(account: id, allowInteraction: false) }
        return result
    }
    func read(account: String, allowInteraction: Bool) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if allowInteraction { interactiveReads += 1 }
        return try memory.read(account: account, allowInteraction: allowInteraction)
    }
    func write(_ secret: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        if failures { throw CredentialStoreError.failure(errSecIO) }
        try memory.write(secret, account: account)
        ids.insert(account)
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try memory.delete(account: account)
        ids.remove(account)
    }
}

private enum Endpoint: Equatable { case identity, usage, bootstrap, detail, auxiliary, unknown }
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
    private var pending: [(Endpoint, AccountsProtocol, Reply)] = []
    private var allowedHeaders = Set<String>()
    private var unexpected = 0
    private func canonical(_ cookie: String) -> String {
        cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.sorted().joined(separator: "; ")
    }
    var requests: [(Endpoint, URLRequest)] { lock.lock(); defer { lock.unlock() }; return seen }
    var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
    var unusedCount: Int { lock.lock(); defer { lock.unlock() }; return rules.count }
    func count(_ endpoint: Endpoint) -> Int { requests.filter { $0.0 == endpoint }.count }
    func expect(_ endpoint: Endpoint, _ cookie: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        allowedHeaders.insert(canonical(cookie))
        rules.append(Rule(endpoint: endpoint, header: cookie, reply: reply))
    }
    func expectUsage(_ cookie: String, percent: Double = 37, held: Bool = false) {
        expect(.usage, cookie, Reply(data: usageData(percent), held: held))
    }
    func hasHeld(_ endpoint: Endpoint) -> Bool {
        lock.lock(); defer { lock.unlock() }; return pending.contains { $0.0 == endpoint }
    }
    func handle(_ transport: AccountsProtocol) {
        let request = transport.request
        let url = request.url
        let path = url?.path ?? ""
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let isUsage = path.hasPrefix("/api/organizations/") && path.hasSuffix("/usage")
        let isAuxiliary = (isUsage && items.count == 2 &&
            items.contains { $0.name == "cedar_ember" && $0.value == "1" } &&
            items.contains { $0.name == "skip_spend" && $0.value == "1" }) ||
            (path.hasPrefix("/api/organizations/") && items.isEmpty &&
                (path.hasSuffix("/overage_spend_limit") || path.hasSuffix("/prepaid/credits")))
        let endpoint: Endpoint = path == "/api/account" && items.isEmpty ? .identity :
            path == "/api/bootstrap" && items.isEmpty ? .bootstrap :
            isUsage && items.isEmpty ? .usage : isUsage && isAuxiliary ? .detail :
            isAuxiliary ? .auxiliary : .unknown
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        lock.lock()
        seen.append((endpoint, request))
        let safe = url?.scheme == "https" && url?.host == "claude.ai" && request.httpMethod == "GET"
        var reply: Reply?
        if safe, let index = rules.firstIndex(where: { $0.endpoint == endpoint && canonical($0.header) == canonical(cookie) }) {
            reply = rules.remove(at: index).reply
        }
        else if safe && (endpoint == .auxiliary || endpoint == .detail) && allowedHeaders.contains(canonical(cookie)) { reply = Reply() }
        guard let reply else {
            unexpected += 1; lock.unlock()
            transport.client?.urlProtocol(transport, didFailWithError: URLError(.unsupportedURL)); return
        }
        if reply.held { pending.append((endpoint, transport, reply)) }
        lock.unlock()
        if !reply.held { transport.deliver(reply) }
    }
    func release(_ endpoint: Endpoint) {
        lock.lock()
        let batch = pending.filter { $0.0 == endpoint }
        pending.removeAll { $0.0 == endpoint }
        lock.unlock()
        batch.forEach { $0.1.deliver($0.2) }
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
    override func stopLoading() {} // Held replies are deliberately released by the test.
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

private final class CompletionProbe {
    private let lock = NSLock()
    private var values: [(ClaudeSignInOutcome, Bool)] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func record(_ value: ClaudeSignInOutcome) {
        lock.lock(); values.append((value, Thread.isMainThread)); lock.unlock()
    }
    func expect(_ expected: ClaudeSignInOutcome) {
        wait("sign-in completion") { self.count > 0 }
        lock.lock(); let result = values; lock.unlock()
        check(result.count == 1 && result.first?.0 == expected, "exact sign-in outcome, once")
        check(result.allSatisfy { $0.1 }, "completion runs on the main thread")
    }
    func verifyOnce() {
        lock.lock(); let result = values; lock.unlock()
        check(result.count == 1 && result.allSatisfy { $0.1 }, "completion remains exactly once on main after HTTP drains")
    }
}
private final class Fixture {
    let suite = "LimitFuel.SignIn.\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let store = SignInCredentials()
    let server = OfflineServer()
    let session: URLSession
    var owners: [ClaudeAccounts] = []
    var probes: [CompletionProbe] = []
    init(_ base: URL) throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set([String](), forKey: "claude_account_ids")
        defaults.set(false, forKey: "claude_accounts_auto_add")
        for name in ["usage_notifications_enabled", "status_notifications_enabled", "diagnostics_enabled"] {
            defaults.set(false, forKey: name)
        }
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountsProtocol.self]
        config.httpAdditionalHeaders = ["X-Acceptance-Fixture": suite]
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
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
    func seed(_ id: String, cookie: String, email: String? = nil, uuid: String? = nil,
              org: String? = organization, web: Bool = false, chrome: Bool = false,
              profile: String? = nil) throws {
        var ids = defaults.stringArray(forKey: "claude_account_ids") ?? []
        ids.append(id); defaults.set(ids, forKey: "claude_account_ids")
        defaults.set(chrome, forKey: key(id, "chrome_sync"))
        defaults.set(web, forKey: key(id, "web_sign_in"))
        if let email { defaults.set(email, forKey: key(id, "email")) }
        if let uuid { defaults.set(uuid, forKey: key(id, "account_uuid")) }
        if let org { defaults.set(org, forKey: key(id, "organization_id")) }
        if let profile {
            defaults.set("Default", forKey: key(id, "chrome_profile_id"))
            defaults.set(profile, forKey: key(id, "chrome_profile_name"))
        }
        try store.write(cookie, account: id)
    }
    func begin(_ owner: ClaudeAccounts, _ cookie: String) -> CompletionProbe {
        check(Thread.isMainThread, "completeSignIn invoked on main")
        let probe = CompletionProbe(); probes.append(probe)
        owner.completeSignIn(cookie) { probe.record($0) }
        return probe
    }
    func metadata() -> NSDictionary { (defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary }
    func drain() {
        var inspecting = false
        var empty = false
        wait("all injected HTTP and main publications drain") {
            if !inspecting && !empty {
                inspecting = true
                self.session.getAllTasks { tasks in
                    DispatchQueue.main.async { empty = tasks.isEmpty; inspecting = false }
                }
            }
            return empty
        }
        settle()
    }
    func finish() {
        drain()
        probes.forEach { $0.verifyOnce() }
        check(server.unexpectedCount == 0, "no unexpected HTTP, implicit identity lookup or retry")
        check(server.unusedCount == 0, "every declared request occurred")
        check(store.promptedReads == 0, "background credential reads never prompt")
        check(!String(describing: metadata()).contains("sessionKey="), "credentials never enter UserDefaults")
        session.invalidateAndCancel()
        owners.removeAll()
        defaults.removePersistentDomain(forName: suite)
        AccountsProtocol.lock.lock(); AccountsProtocol.servers.removeValue(forKey: suite); AccountsProtocol.lock.unlock()
        try? FileManager.default.removeItem(at: root)
    }
}
private func withFixture(_ base: URL, _ body: (Fixture) throws -> Void) throws {
    let fixture = try Fixture(base); defer { fixture.finish() }; try body(fixture)
}
private func unchanged(_ account: UsageManager) -> () -> Void {
    let label = account.accountLabel, email = account.email, org = account.organizationName
    let signedIn = account.signedInHere, chrome = account.chromeDetectionEnabled
    let profiles = account.chromeProfiles.map(\.id), message = account.chromeMessage
    let attention = account.chromeNeedsAttention, error = account.errorMessage
    let needsSignIn = account.needsSignIn, fetched = account.hasFetchedData
    let options = account.menuBarOptions, percent = account.sessionUtilization
    return {
        check(account.accountLabel == label && account.email == email && account.organizationName == org, "identity unchanged")
        check(account.signedInHere == signedIn && account.chromeDetectionEnabled == chrome, "source unchanged")
        check(account.chromeProfiles.map(\.id) == profiles && account.chromeMessage == message && account.chromeNeedsAttention == attention, "Chrome state unchanged")
        check(account.errorMessage == error && account.needsSignIn == needsSignIn, "error/auth state unchanged")
        check(account.hasFetchedData == fetched && account.menuBarOptions == options && account.sessionUtilization == percent, "usage unchanged")
    }
}

@main struct ClaudeSignInTests {
    static func main() throws {
        _ = NSApplication.shared
        check(Thread.isMainThread, "acceptance executable starts on main")
        guard let location = ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] else {
            check(false, "CLAUDE_TEST_TMPDIR required; no real Chrome or Keychain fallback"); return
        }
        let base = URL(fileURLWithPath: location).appendingPathComponent("claude-sign-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cases: [(String, (URL) throws -> Void)] = [
            ("testCookieDomainsAndSorting", { _ in testCookieDomainsAndSorting() }),
            ("testCookieExpiryBoundary", { _ in testCookieExpiryBoundary() }),
            ("testCookieInvalidPairIsSkipped", { _ in testCookieInvalidPairIsSkipped() }),
            ("testCookieDuplicatePrecedence", { _ in testCookieDuplicatePrecedence() }),
            ("testCookieRequiresSessionKey", { _ in testCookieRequiresSessionKey() }),
            ("invalid headers", testInvalidHeaders),
            ("already tracked session", testAlreadyAdded),
            ("new account and request", testNewAccount),
            ("renew in place", testRenewal),
            ("missing organization", testMissingOrganizationRenewal),
            ("different organization", testOtherOrganization),
            ("first listed match", testFirstMatch),
            ("identity rejection", testRejectedIdentity),
            ("identity connection failures", testConnectionFailures),
            ("new credential failure", testNewKeychainFailure),
            ("renewal credential failure", testRenewalKeychainFailure),
            ("remove during lookup", testRemovalDuringLookup),
            ("removed adopt", testRemovedAdopt),
            ("adopt write failure", testAdoptKeychainFailure),
            ("adopt success/reset", testAdoptSuccess),
            ("label precedence", testLabels),
            ("authentication recovery", testNeedsSignIn),
            ("bootstrap authentication and clear", testBootstrapNeedsSignIn),
            ("usage-detail refusal keeps session", testDetailNeedsSignIn),
            ("manual cookie source", testManualCookie),
            ("clear source", testClearCookie),
            ("remove metadata", testRemoveMetadata),
            ("Chrome detection source transition", testChromeDetectionSource),
            ("hourly Chrome exclusion", testChromeRefresh)
        ]
        for (name, body) in cases { try body(base); tests += 1; print("PASS ClaudeSignIn: \(name)") }
        check(AccountsProtocol.unownedRequests == 0, "all HTTP belongs to a disposable fixture")
        print("ClaudeSignInTests passed (\(tests) tests, \(checks) checks)")
    }

    static func testInvalidHeaders(_ base: URL) throws {
        for cookie in ["", "auxiliary=value", "sessionKey=", "sessionKey=x\r\nInjected: yes", "sessionKey=x\u{0000}",
                       "sessionKey=" + String(repeating: "x", count: 1_048_577)] {
            try withFixture(base) { f in
                let owner = f.load(), before = f.metadata(), writes = f.store.writeCount
                var changes = 0; owner.onChange = { changes += 1 }
                f.begin(owner, cookie).expect(.failed(invalidSessionMessage))
                f.drain()
                check(f.server.requests.isEmpty && f.store.writeCount == writes, "invalid header has no HTTP or credential writes")
                check(owner.accounts.isEmpty && f.metadata().isEqual(before) && changes == 0, "invalid header stores/changes nothing")
            }
        }
    }

    static func testAlreadyAdded(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("existing", cookie: header("same"), email: "ana@example.com", uuid: userUUID)
            let owner = f.load(), original = owner.accounts[0], before = f.metadata(), writes = f.store.writeCount
            var changes = 0; owner.onChange = { changes += 1 }
            // Auxiliary cookies and their order are not the session identity.
            f.begin(owner, "auxiliary=changed; " + header("same")).expect(.alreadyAdded("ana@example.com"))
            f.drain()
            check(f.server.requests.isEmpty && f.store.writeCount == writes, "already-added avoids lookup/write")
            check(owner.accounts.count == 1 && owner.accounts[0] === original, "already-added retains same object")
            check(f.metadata().isEqual(before) && changes == 0, "already-added changes no metadata")
        }
    }

    static func testNewAccount(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("existing", cookie: header("existing"), email: "ben@example.com", uuid: otherUserUUID)
            f.defaults.set(true, forKey: "claude_accounts_auto_add")
            let owner = f.load(), original = owner.accounts[0], cookie = header("new")
            // Establish a real stale Chrome message through the declared seam.
            check(!owner.addManualCookie("sessionKey="), "invalid manual cookie supplies an existing source error")
            check(owner.chromeMessage != nil, "fixture has a Chrome message to clear")
            var changes = 0; owner.onChange = { changes += 1 }
            f.server.expect(.identity, cookie, Reply(data: identityData()))
            f.server.expectUsage(cookie)
            f.begin(owner, cookie).expect(.added("ana@example.com"))
            wait("new usage fetched") { owner.accounts.count == 2 && owner.accounts[1].hasFetchedData }
            f.drain()
            let account = owner.accounts[1], id = account.accountID
            check(owner.accounts[0] === original && id != "existing", "new account appends after existing object")
            check(f.store.contents[id] == cookie && f.store.contents["existing"] == header("existing"), "credential stored only under new id")
            check(f.defaults.stringArray(forKey: "claude_account_ids") == ["existing", id], "ids appended in display order")
            check(!f.defaults.bool(forKey: "claude_accounts_auto_add"), "sign-in disables auto-add")
            check(f.defaults.object(forKey: key(id, "chrome_sync")) as? Bool == false, "Chrome sync explicitly off")
            check(f.defaults.bool(forKey: key(id, "web_sign_in")) && account.signedInHere, "web source persisted/published")
            check(f.defaults.string(forKey: key(id, "email")) == "ana@example.com" && account.accountLabel == "ana@example.com", "email persisted and displayed")
            check(f.defaults.string(forKey: key(id, "account_uuid")) == userUUID, "account UUID persisted")
            check(f.defaults.string(forKey: key(id, "organization_name")) == "Example workspace", "organization name persisted")
            check(f.defaults.string(forKey: key(id, "organization_id")) == organization, "header organization persisted")
            check(changes > 0 && owner.chromeMessage == nil, "onChange called and prior Chrome message cleared")
            check(account.sessionUtilization == 37 && account.connectionSummary == "Signed in with LimitFuel", "usage and sign-in summary published")
            let request = f.server.requests.first { $0.0 == .identity }!.1
            check(request.url?.absoluteString == "https://claude.ai/api/account" && request.httpMethod == "GET", "identity request exact URL/method")
            check(request.value(forHTTPHeaderField: "Cookie") == cookie, "identity carries full Cookie header")
            let usageRequest = f.server.requests.first { $0.0 == .usage }!.1
            for field in ["User-Agent", "Accept", "Origin", "Referer"] {
                check(request.value(forHTTPHeaderField: field) == usageRequest.value(forHTTPHeaderField: field), "identity uses existing authenticated header: \(field)")
            }
            check(f.server.count(.identity) == 1, "successful sign-in does not repeat identity lookup after usage")
        }
    }

    static func testRenewal(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("before", cookie: header("before"), uuid: otherUserUUID)
            try f.seed("renew", cookie: header("old", org: organization.lowercased()), email: "old@example.com",
                       uuid: userUUID.lowercased(), org: organization.lowercased(), chrome: true, profile: "Work profile")
            try f.seed("after", cookie: header("after", org: otherOrganization), uuid: otherUserUUID, org: otherOrganization)
            f.defaults.set(90, forKey: key("renew", "last_notified_threshold"))
            let owner = f.load(), originals = owner.accounts, account = originals[1], cookie = header("renewed")
            f.server.expect(.identity, cookie, Reply(data: identityData()))
            f.server.expectUsage(cookie)
            f.begin(owner, cookie).expect(.renewed("ana@example.com"))
            wait("renewed usage") { account.hasFetchedData }
            check(owner.accounts.count == 3 && zip(owner.accounts, originals).allSatisfy { $0.0 === $0.1 }, "renewal retains every object and position")
            check(f.defaults.stringArray(forKey: "claude_account_ids") == ["before", "renew", "after"], "renewal creates no id")
            check(f.store.contents["renew"] == cookie, "renewal replaces credential")
            check(account.signedInHere && !account.chromeDetectionEnabled && account.accountLabel == "ana@example.com", "renewal changes source and identity")
            check(f.defaults.bool(forKey: key("renew", "web_sign_in")) && !f.defaults.bool(forKey: key("renew", "chrome_sync")), "renewal persists source flags")
            for field in ["chrome_profile_id", "chrome_profile_name"] {
                check(f.defaults.object(forKey: key("renew", field)) == nil, "renewal removes pinned profile \(field)")
            }
            check(f.defaults.integer(forKey: key("renew", "last_notified_threshold")) == 90, "renewal preserves alert history")
            check(f.defaults.string(forKey: key("renew", "email")) == "ana@example.com" && f.defaults.string(forKey: key("renew", "organization_id")) == organization, "renewal replaces identity metadata")
            check(account.chromeProfiles.isEmpty && account.chromeMessage == nil && !account.chromeNeedsAttention, "renewal clears Chrome detection state")
        }
    }

    static func testMissingOrganizationRenewal(_ base: URL) throws {
        for (oldOrg, newOrg) in [(nil, organization), (organization, nil), (nil, nil)] as [(String?, String?)] {
            try withFixture(base) { f in
                try f.seed("renew", cookie: header("old", org: oldOrg), email: "old@example.com", uuid: userUUID, org: oldOrg)
                let owner = f.load(), account = owner.accounts[0], cookie = header("new", org: newOrg)
                f.server.expect(.identity, cookie, Reply(data: identityData()))
                if newOrg != nil { f.server.expectUsage(cookie) }
                else { f.server.expect(.bootstrap, cookie, Reply(error: .timedOut)) }
                f.begin(owner, cookie).expect(.renewed("ana@example.com"))
                f.drain()
                check(owner.accounts.count == 1 && owner.accounts[0] === account, "missing org on either side still renews")
                check(f.store.contents["renew"] == cookie && account.signedInHere, "missing-org renewal replaces credential/source")
                check(f.defaults.string(forKey: key("renew", "organization_id")) == newOrg, "renewal uses header org, including absent org")
            }
        }
    }

    static func testOtherOrganization(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("first-org", cookie: header("old"), email: "ana@example.com", uuid: userUUID)
            let owner = f.load(), original = owner.accounts[0], cookie = header("new", org: otherOrganization)
            f.server.expect(.identity, cookie, Reply(data: identityData(org: otherOrganization)))
            f.server.expectUsage(cookie)
            f.begin(owner, cookie).expect(.added("ana@example.com"))
            wait("other-org usage") { owner.accounts.count == 2 && owner.accounts[1].hasFetchedData }
            check(owner.accounts[0] === original && f.store.contents["first-org"] == header("old"), "different organization leaves original credential/object")
            check(f.defaults.string(forKey: key(owner.accounts[1].accountID, "organization_id")) == otherOrganization, "other organization added separately")
        }
    }

    static func testFirstMatch(_ base: URL) throws {
        try withFixture(base) { f in
            // Distinct organizations are valid independent accounts. The new
            // header has no org, so both match and the first listed must win.
            try f.seed("first", cookie: header("one"), uuid: userUUID)
            try f.seed("second", cookie: header("two", org: otherOrganization), uuid: userUUID, org: otherOrganization)
            let owner = f.load(), originals = owner.accounts, cookie = header("replacement", org: nil)
            f.server.expect(.identity, cookie, Reply(data: identityData()))
            f.server.expect(.bootstrap, cookie, Reply(error: .timedOut))
            f.begin(owner, cookie).expect(.renewed("ana@example.com"))
            f.drain()
            check(owner.accounts.first === originals[0] && f.store.contents["first"] == cookie, "first listed match renewed")
            check(owner.accounts.count == 2 && owner.accounts[1] === originals[1], "later match retains its object/position")
            check(f.store.contents["second"] == header("two", org: otherOrganization), "later candidate credential untouched")
        }
    }

    static func testRejectedIdentity(_ base: URL) throws {
        for status in [401, 403] {
            try assertLookupFailure(base, reply: Reply(status: status), message: rejectedMessage)
        }
    }
    static func testConnectionFailures(_ base: URL) throws {
        for reply in [Reply(status: 500), Reply(error: .timedOut), Reply(error: .notConnectedToInternet),
                      Reply(data: Data("<html>unavailable</html>".utf8)), Reply(data: json(["uuid": userUUID])),
                      Reply(data: Data("[]".utf8)), Reply(status: 204)] {
            try assertLookupFailure(base, reply: reply, message: connectionMessage)
        }
    }
    fileprivate static func assertLookupFailure(_ base: URL, reply: Reply, message: String) throws {
        try withFixture(base) { f in
            try f.seed("keep", cookie: header("keep"), email: "ben@example.com", uuid: otherUserUUID)
            let owner = f.load(), account = owner.accounts[0], before = f.metadata()
            let credentials = f.store.contents, writes = f.store.writeCount, state = unchanged(account)
            var changes = 0; owner.onChange = { changes += 1 }
            f.server.expect(.identity, header("failed"), reply)
            f.begin(owner, header("failed")).expect(.failed(message))
            f.drain(); state()
            check(owner.accounts.count == 1 && owner.accounts[0] === account, "lookup failure leaves accounts intact")
            check(f.metadata().isEqual(before) && f.store.contents == credentials && f.store.writeCount == writes, "lookup failure stores nothing")
            check(changes == 0 && f.server.count(.identity) == 1 && f.server.count(.usage) == 0, "failed lookup does not publish/fetch/retry")
        }
    }

    static func testNewKeychainFailure(_ base: URL) throws {
        try withFixture(base) { f in
            let owner = f.load(), before = f.metadata()
            f.store.failWrites = true
            f.server.expect(.identity, header("new"), Reply(data: identityData()))
            var changes = 0; owner.onChange = { changes += 1 }
            f.begin(owner, header("new")).expect(.failed(keychainMessage))
            f.drain()
            check(owner.accounts.isEmpty && f.store.contents.isEmpty && f.metadata().isEqual(before), "new write failure commits no credential, id or metadata")
            check(changes == 0 && f.store.writeCount == 1 && f.server.count(.usage) == 0, "new write failure does not publish/fetch")
        }
    }
    static func testRenewalKeychainFailure(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("renew", cookie: header("old"), email: "old@example.com", uuid: userUUID, chrome: true, profile: "Work")
            let owner = f.load(), account = owner.accounts[0], before = f.metadata(), state = unchanged(owner.accounts[0])
            let credentials = f.store.contents, writes = f.store.writeCount
            f.store.failWrites = true
            var changes = 0; owner.onChange = { changes += 1 }
            f.server.expect(.identity, header("new"), Reply(data: identityData()))
            f.begin(owner, header("new")).expect(.failed(keychainMessage))
            f.drain(); state()
            check(owner.accounts.count == 1 && owner.accounts[0] === account, "failed renewal retains same object")
            check(f.metadata().isEqual(before) && f.store.contents == credentials && changes == 0, "failed renewal changes nothing")
            check(f.store.writeCount == writes + 1 && f.server.count(.usage) == 0, "failed renewal attempts one write, no fetch")
        }
    }

    static func testRemovalDuringLookup(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("removed", cookie: header("old"), email: "ana@example.com", uuid: userUUID, web: true)
            let owner = f.load(), removed = owner.accounts[0], cookie = header("replacement")
            f.server.expect(.identity, cookie, Reply(data: identityData(), held: true))
            let probe = f.begin(owner, cookie)
            wait("lookup held before removal") { f.server.hasHeld(.identity) }
            check(probe.count == 0, "no completion before identity arrives")
            owner.remove(removed)
            let removedState = unchanged(removed)
            f.server.expectUsage(cookie)
            f.server.release(.identity)
            probe.expect(.added("ana@example.com"))
            wait("replacement account usage") { owner.accounts.count == 1 && owner.accounts[0].hasFetchedData }
            removedState()
            let account = owner.accounts[0]
            check(account !== removed && account.accountID != "removed", "removed account never renewed")
            check(f.store.contents["removed"] == nil && f.store.contents[account.accountID] == cookie, "new credential id, no resurrection")
            check(f.defaults.object(forKey: key("removed", "web_sign_in")) == nil, "removed metadata stays absent")
            check(f.defaults.stringArray(forKey: "claude_account_ids") == [account.accountID], "only new account persisted")
        }
    }

    static func testRemovedAdopt(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("removed", cookie: header("old"), uuid: userUUID, web: true)
            let owner = f.load(), account = owner.accounts[0]
            owner.remove(account)
            let before = f.metadata(), credentials = f.store.contents, writes = f.store.writeCount, state = unchanged(account)
            check(!account.adoptSignIn(header("new"), identity: signInIdentity(), organizationID: organization), "removed adopt returns false")
            f.drain(); state()
            check(f.metadata().isEqual(before) && f.store.contents == credentials && f.store.writeCount == writes, "removed adopt does not write or resurrect")
            check(f.server.requests.isEmpty && owner.accounts.isEmpty, "removed adopt does not fetch/add")
        }
    }
    static func testAdoptKeychainFailure(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("account", cookie: header("old"), email: "old@example.com", uuid: userUUID, chrome: true, profile: "Work")
            let owner = f.load(), account = owner.accounts[0]
            account.parseUsageData(usageData(64))
            let before = f.metadata(), credentials = f.store.contents, writes = f.store.writeCount, state = unchanged(account)
            f.store.failWrites = true
            check(!account.adoptSignIn(header("new"), identity: signInIdentity(), organizationID: organization), "adopt write failure returns false")
            f.drain(); state()
            check(f.metadata().isEqual(before) && f.store.contents == credentials && f.store.writeCount == writes + 1, "adopt write failure changes no metadata/credential")
            check(f.server.requests.isEmpty, "adopt write failure does not fetch")
        }
    }
    static func testAdoptSuccess(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("account", cookie: header("old"), email: "old@example.com", uuid: userUUID, chrome: true, profile: "Work")
            let owner = f.load(), account = owner.accounts[0], cookie = header("adopted")
            account.parseUsageData(usageData(64))
            f.server.expectUsage(cookie, held: true)
            check(account.adoptSignIn(cookie, identity: signInIdentity(), organizationID: organization), "adopt succeeds")
            wait("new usage held") { f.server.hasHeld(.usage) }
            check(!account.hasFetchedData && account.menuBarOptions.isEmpty, "changed session clears previous usage before response")
            check(account.signedInHere && !account.chromeDetectionEnabled && !account.needsSignIn && account.errorMessage == nil, "adopt replaces source and clears error/auth state")
            check(account.email == "ana@example.com" && account.organizationName == "Example workspace", "given identity available without another request")
            check(account.chromeProfiles.isEmpty && account.chromeMessage == nil && !account.chromeNeedsAttention, "Chrome state cleared")
            f.server.release(.usage)
            wait("adopted usage") { account.hasFetchedData }
            check(account.connectionSummary == "Signed in with LimitFuel" && f.server.count(.identity) == 0, "sign-in summary, no duplicate identity request")
            check(f.store.contents["account"] == cookie && f.defaults.bool(forKey: key("account", "web_sign_in")), "adopt persists credential/source")
        }
    }

    static func testLabels(_ base: URL) throws {
        struct Case { let email: String?; let web: Bool; let chrome: Bool; let profile: String?; let label: String }
        let cases = [
            Case(email: "ana@example.com", web: true, chrome: false, profile: "Work", label: "ana@example.com"),
            Case(email: "ana@example.com", web: false, chrome: true, profile: "Work", label: "ana@example.com"),
            Case(email: nil, web: true, chrome: false, profile: "Work", label: "Claude sign-in"),
            Case(email: nil, web: false, chrome: false, profile: "Work", label: "Manual cookie"),
            Case(email: nil, web: false, chrome: true, profile: "Work", label: "Work"),
            Case(email: nil, web: false, chrome: true, profile: nil, label: "Chrome")
        ]
        for item in cases {
            try withFixture(base) { f in
                try f.seed("label", cookie: header("label"), email: item.email, web: item.web, chrome: item.chrome, profile: item.profile)
                let account = f.load().accounts[0]
                check(account.signedInHere == item.web, "web sign-in loaded from metadata")
                check(account.accountLabel == item.label, "accountLabel fallback order: \(item.label)")
            }
        }
    }

    static func testNeedsSignIn(_ base: URL) throws {
        for status in [401, 403] {
            try withFixture(base) { f in
                let owner = f.load(), cookie = header("auth")
                f.server.expect(.identity, cookie, Reply(data: identityData()))
                f.server.expectUsage(cookie)
                f.begin(owner, cookie).expect(.added("ana@example.com"))
                wait("initial success") { owner.accounts.first?.hasFetchedData == true }
                f.drain()
                let account = owner.accounts[0]
                check(!account.needsSignIn, "200 usage clears needsSignIn")
                f.server.expect(.usage, cookie, Reply(status: status))
                account.fetchUsage()
                wait("usage auth failure") { account.needsSignIn && !account.isLoading }
                check(!account.hasFetchedData, "auth failure invalidates usage")
                f.server.expectUsage(cookie)
                account.fetchUsage()
                wait("same session 200 recovery") { account.hasFetchedData && !account.isLoading }
                check(!account.needsSignIn, "successful usage clears prior sign-in requirement")
                f.server.expect(.usage, cookie, Reply(status: status))
                account.fetchUsage()
                wait("second auth failure") { account.needsSignIn && !account.isLoading }
                let replacement = header("auth-renewed")
                f.server.expectUsage(replacement, held: true)
                check(account.adoptSignIn(replacement, identity: signInIdentity(), organizationID: organization), "renew expired session")
                check(!account.needsSignIn && account.errorMessage == nil, "adopt clears auth/error before network success")
                wait("renewal usage held") { f.server.hasHeld(.usage) }
                f.server.release(.usage)
                wait("renewed success") { account.hasFetchedData }
            }
        }
    }

    static func testManualCookie(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("manual", cookie: header("old"), web: true)
            let owner = f.load(), account = owner.accounts[0], cookie = header("manual")
            check(account.signedInHere, "manual transition begins signed in here")
            f.server.expectUsage(cookie)
            f.server.expect(.identity, cookie, Reply(data: identityData()))
            account.saveSessionCookie(cookie)
            check(!account.signedInHere && !f.defaults.bool(forKey: key("manual", "web_sign_in")), "manual save immediately clears web source")
            wait("manual usage and identity") { account.hasFetchedData && account.email == "ana@example.com" }
            check(account.connectionSummary == "Connected with a manual cookie", "manual source displayed after success")
        }
    }

    static func testBootstrapNeedsSignIn(_ base: URL) throws {
        for status in [401, 403] {
            try withFixture(base) { f in
                let cookie = header("bootstrap-auth", org: nil)
                try f.seed("bootstrap", cookie: cookie, email: "ana@example.com", uuid: userUUID, org: nil, web: true)
                let account = f.load().accounts[0]
                f.server.expect(.bootstrap, cookie, Reply(status: status))
                account.fetchUsage()
                wait("bootstrap auth failure") { account.needsSignIn && !account.isLoading }
                check(!account.hasFetchedData, "bootstrap auth failure exposes sign-in requirement")
                account.clearSessionCookie()
                check(!account.needsSignIn && !account.signedInHere, "clear resets actual bootstrap auth failure/source")
                check(!f.defaults.bool(forKey: key("bootstrap", "web_sign_in")), "clear persists source reset after auth failure")
            }
        }
    }

    static func testDetailNeedsSignIn(_ base: URL) throws {
        for status in [401, 403] {
            try withFixture(base) { f in
                let owner = f.load(), cookie = header("detail-auth")
                f.server.expect(.identity, cookie, Reply(data: identityData()))
                f.server.expectUsage(cookie)
                f.begin(owner, cookie).expect(.added("ana@example.com"))
                wait("detail fixture initial usage") { owner.accounts.first?.hasFetchedData == true }
                f.drain()
                let account = owner.accounts[0]
                // Hold the detail response until the main 200 has published, so
                // this tests the detail-auth path without choosing race policy.
                f.server.expectUsage(cookie)
                f.server.expect(.detail, cookie, Reply(status: status, held: true))
                account.fetchUsage()
                wait("detail response held after main usage") { f.server.hasHeld(.detail) && account.hasFetchedData }
                f.server.release(.detail)
                wait("detail refusal handled") { !account.isLoading }
                // A Team member without billing access gets 403 here while the session is fine.
                check(!account.needsSignIn && account.hasFetchedData, "detail \(status) keeps the session signed in")
            }
        }
    }
    static func testClearCookie(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("clear", cookie: header("old"), web: true)
            let account = f.load().accounts[0]
            account.clearSessionCookie()
            check(!account.signedInHere && !account.needsSignIn && !f.defaults.bool(forKey: key("clear", "web_sign_in")), "clear resets web/auth source")
            check(f.store.contents["clear"] == nil, "clear deletes stored session")
        }
    }
    static func testRemoveMetadata(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("remove", cookie: header("old"), web: true)
            let owner = f.load(); owner.remove(owner.accounts[0])
            check(f.defaults.object(forKey: key("remove", "web_sign_in")) == nil, "remove deletes web_sign_in field entirely")
            check(owner.accounts.isEmpty && f.store.contents["remove"] == nil, "remove deletes account/credential")
        }
    }

    static func testChromeRefresh(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("web", cookie: header("web"), email: "ana@example.com", uuid: userUUID, web: true)
            try f.seed("chrome", cookie: header("chrome"), email: "ben@example.com", uuid: otherUserUUID,
                       chrome: true, profile: "Work")
            try encryptedChromeFixture(f.root)
            let calls = ChromeCalls()
            let reader = ChromeCookieReader(root: f.root, passwordProvider: { try calls.deny($0) })
            let owner = f.load(reader: reader), web = owner.accounts[0], chrome = owner.accounts[1]
            let webState = unchanged(web), writes = f.store.writeCount, cookie = f.store.contents["web"]
            owner.refreshChromeAccounts()
            // A real eligible control account proves the refresh had time to run;
            // encrypted fixture forces each detection through the counting seam.
            wait("Chrome control attempted detection") { calls.count > 0 && !chrome.isDetectingChrome }
            f.drain(); webState()
            check(calls.count > 0 && calls.interactions.allSatisfy { !$0 }, "Chrome control detects noninteractively")
            check(!web.isDetectingChrome && web.chromeMessage == nil, "web account never runs Chrome detection")
            check(f.store.contents["web"] == cookie && f.store.writeCount == writes && web.signedInHere, "hourly refresh cannot replace web credential/source")
            check(f.server.requests.isEmpty, "hourly Chrome exclusion needs no HTTP")
        }
    }

    static func testChromeDetectionSource(_ base: URL) throws {
        try withFixture(base) { f in
            try f.seed("source", cookie: header("web"), web: true)
            try chromeFixture(f.root, plaintextSession: "sk-ant-sid01-test-imported")
            let owner = f.load(), account = owner.accounts[0], imported = header("imported")
            f.server.expectUsage(imported)
            f.server.expect(.identity, imported, Reply(data: identityData()))
            account.detectChromeSession(interactive: true)
            wait("explicit Chrome detection enables sync") { !account.isDetectingChrome && account.chromeDetectionEnabled }
            check(!account.signedInHere && !f.defaults.bool(forKey: key("source", "web_sign_in")), "enabling Chrome sync clears web source")
            check(f.defaults.bool(forKey: key("source", "chrome_sync")), "Chrome source persisted")
            wait("Chrome usage/identity") { account.hasFetchedData && account.email == "ana@example.com" }
        }
    }
}

private final class ChromeCalls {
    private let lock = NSLock()
    private var values: [Bool] = []
    var interactions: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
    var count: Int { interactions.count }
    func deny(_ interactive: Bool) throws -> Data {
        lock.lock(); values.append(interactive); lock.unlock()
        throw ChromeCookieError.keychain
    }
}
private func encryptedChromeFixture(_ root: URL) throws { try chromeFixture(root, plaintextSession: nil) }
private func chromeFixture(_ root: URL, plaintextSession: String?) throws {
    let directory = root.appendingPathComponent("Default")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    check(sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK, "open disposable Chrome fixture")
    defer { sqlite3_close(db) }
    check(sqlite3_exec(db, "CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','23'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,top_frame_site_key TEXT)", nil, nil, nil) == SQLITE_OK, "create disposable Chrome schema")
    var statement: OpaquePointer?
    check(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES('.claude.ai','sessionKey',?,?,'/',0,1,'')", -1, &statement, nil) == SQLITE_OK, "prepare synthetic session")
    defer { sqlite3_finalize(statement) }
    let encrypted = Data("v10".utf8) + Data(repeating: 0, count: 16)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, plaintextSession ?? "", -1, transient)
    if plaintextSession == nil {
        _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
    } else { sqlite3_bind_null(statement, 2) }
    check(sqlite3_step(statement) == SQLITE_DONE, "insert synthetic session cookie")
    var organizationStatement: OpaquePointer?
    check(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES('.claude.ai','lastActiveOrg',?,NULL,'/',0,1,'')", -1, &organizationStatement, nil) == SQLITE_OK, "prepare synthetic organization")
    defer { sqlite3_finalize(organizationStatement) }
    sqlite3_bind_text(organizationStatement, 1, organization, -1, transient)
    check(sqlite3_step(organizationStatement) == SQLITE_DONE, "insert synthetic organization cookie")
}

private func signInCookie(_ name: String, _ value: String, domain: String = "claude.ai", path: String = "/", expires: Date? = nil) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
    if let expires { properties[.expires] = expires }
    guard let cookie = HTTPCookie(properties: properties) else { fatalError("Foundation rejected cookie fixture \(name)") }
    // Foundation lowercases domains when constructing HTTPCookie; dots, path
    // and deliberately invalid values must otherwise survive unchanged.
    check(cookie.name == name && cookie.value == value && cookie.domain == domain.lowercased() && cookie.path == path, "Foundation retains fixture \(name)")
    check(cookie.expiresDate == expires, "Foundation retains expiry \(name)")
    return cookie
}

extension ClaudeSignInTests {
    static func testCookieDomainsAndSorting() {
        let cookies = [signInCookie("z", "dot", domain: ".claude.ai"), signInCookie("sessionKey", "good", domain: "CLAUDE.AI"), signInCookie("a", "host"), signInCookie("sub", "bad", domain: "api.claude.ai"), signInCookie("suffix", "bad", domain: "evilclaude.ai"), signInCookie("suffix2", "bad", domain: "claude.ai.example.com"), signInCookie("anthropic", "bad", domain: "anthropic.com"), signInCookie("google", "bad", domain: "accounts.google.com"), signInCookie("doubleDot", "bad", domain: "..claude.ai")]
        check(ClaudeSignInCookies.header(from: cookies) == "a=host; sessionKey=good; z=dot", "only exact host and single-dot domains accepted, case folded and sorted")
    }

    static func testCookieExpiryBoundary() {
        // Foundation caps cookie expiry at 400 days ahead and keeps whole seconds.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let cookies = [signInCookie("sessionKey", "good"), signInCookie("past", "old", expires: now.addingTimeInterval(-1)), signInCookie("at", "boundary", expires: now), signInCookie("future", "new", expires: now.addingTimeInterval(1)), signInCookie("session", "noExpiry")]
        check(ClaudeSignInCookies.header(from: cookies, now: now) == "at=boundary; future=new; session=noExpiry; sessionKey=good", "only expiry strictly before now is excluded")
        check(ClaudeSignInCookies.header(from: [signInCookie("sessionKey", "expired", expires: now.addingTimeInterval(-1))], now: now) == nil,
              "expired sessionKey cannot authorize a header")
    }

    static func testCookieInvalidPairIsSkipped() {
        let cookies = [signInCookie("sessionKey", "good"), signInCookie("bad", "bad;value"), signInCookie("ok", "value")]
        check(ClaudeSignInCookies.header(from: cookies) == "ok=value; sessionKey=good", "malformed pair is skipped without losing valid session")
    }

    static func testCookieDuplicatePrecedence() {
        let session = signInCookie("sessionKey", "good")
        let shortHost = signInCookie("choice", "shortHost", path: "/")
        let longDot = signInCookie("choice", "longDot", domain: ".claude.ai", path: "/long")
        let longHost = signInCookie("choice", "longHost", path: "/long")
        let cases = [[shortHost, longDot], [longDot, shortHost], [longDot, longHost], [longHost, longDot], [shortHost, longDot, longHost], [longHost, longDot, shortHost]]
        for (index, duplicates) in cases.enumerated() {
            let expected = index < 2 ? "longDot" : "longHost"
            check(ClaudeSignInCookies.header(from: [session] + duplicates) == "choice=\(expected); sessionKey=good", "longest path then host-only wins independent of input order case \(index)")
        }
    }

    static func testCookieRequiresSessionKey() {
        check(ClaudeSignInCookies.header(from: []) == nil, "empty cookies return nil")
        check(ClaudeSignInCookies.header(from: [signInCookie("other", "value")]) == nil, "absent sessionKey returns nil")
        check(ClaudeSignInCookies.header(from: [signInCookie("sessionKey", ""), signInCookie("other", "value")]) == nil, "empty sessionKey returns nil")
        check(ClaudeSignInCookies.header(from: [signInCookie("sessionKey", "bad", domain: "api.claude.ai")]) == nil, "excluded domain cannot supply sessionKey")
    }
}
