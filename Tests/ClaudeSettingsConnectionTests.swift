import Foundation
import AppKit
import SQLite3

// Frozen contract F acceptance. Only disposable SQLite and injected HTTP/Keychain faults.
fileprivate func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

private final class ConnectionProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statuses: [Int] = []
    private static var starts = 0
    private static var unexpected = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    static var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
    static func enqueue(_ status: Int) { lock.lock(); statuses.append(status); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { fatalError("fixture request needs a URL") }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let main = url.path.hasSuffix("/usage") && items.isEmpty
        let auxiliary = (url.path.hasSuffix("/usage") && items.count == 2 &&
            items.contains { $0.name == "cedar_ember" && $0.value == "1" } &&
            items.contains { $0.name == "skip_spend" && $0.value == "1" }) ||
            (url.path.hasSuffix("/overage_spend_limit") && items.isEmpty) ||
            (url.path.hasSuffix("/prepaid/credits") && items.isEmpty)
        Self.lock.lock()
        if main { Self.starts += 1 }
        let declared = !main || !Self.statuses.isEmpty
        let status = main && declared ? Self.statuses.removeFirst() : 200
        if (!main && !auxiliary) || !declared { Self.unexpected += 1 }
        Self.lock.unlock()
        guard (main || auxiliary) && declared else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let body = main ? Data(#"{"five_hour":{"utilization":37,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":19,"resets_at":"2099-01-08T00:00:00Z"}}"#.utf8) : Data("{}".utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class KeychainFault {
    private let lock = NSLock()
    private var interactions: [Bool] = []
    var attempts: [Bool] { lock.lock(); defer { lock.unlock() }; return interactions }
    func deny(_ interactive: Bool) throws -> Data {
        lock.lock(); interactions.append(interactive); lock.unlock()
        throw ChromeCookieError.keychain
    }
}

@main
struct ClaudeSettingsConnectionTests {
    private static let org = "11111111-2222-4333-8444-555555555555"
    private static let cookie = "sessionKey=synthetic-settings; lastActiveOrg=\(org)"

    private static func controls(_ manager: UsageManager) {
        check(manager.showsClaudeConnectionControls == !manager.hasFetchedData,
              "connect controls depend only on successfully fetched Claude usage")
    }
    private static func wait(_ manager: UsageManager, _ label: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !predicate() && Date() < deadline {
            controls(manager)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        controls(manager)
        check(predicate(), "bounded wait: \(label)")
    }
    private static func settle(_ manager: UsageManager, _ session: URLSession) {
        var inspecting = false
        var drained = false
        wait(manager, "injected HTTP and main publication settle") {
            if !manager.isLoading && !inspecting && !drained {
                inspecting = true
                session.getAllTasks { tasks in
                    DispatchQueue.main.async { drained = tasks.isEmpty; inspecting = false }
                }
            }
            return !manager.isLoading && drained
        }
    }
    private static func encryptedDatabase(_ root: URL) throws {
        let directory = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        check(sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK, "open disposable Chrome database")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','23'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,top_frame_site_key TEXT);", nil, nil, nil) == SQLITE_OK, "create Chrome fixture schema")
        var statement: OpaquePointer?
        check(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES('.claude.ai','sessionKey','',?,'/',0,1,'')", -1, &statement, nil) == SQLITE_OK, "prepare encrypted session fixture")
        defer { sqlite3_finalize(statement) }
        let encrypted = Data("v10".utf8) + Data(repeating: 0, count: 16)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        check(sqlite3_step(statement) == SQLITE_DONE, "insert encrypted session fixture")
    }
    private static func withFixture(_ work: (UsageManager, URLSession, KeychainFault) throws -> Void) throws {
        let suite = "LimitFuel.Acceptance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(cookie, forKey: "claude_session_cookie")
        defaults.set(true, forKey: "chrome_detection_enabled")
        defaults.set(false, forKey: "usage_notifications_enabled")
        defaults.set(false, forKey: "status_notifications_enabled")
        let base = ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("ClaudeSettingsConnection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try encryptedDatabase(root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fault = KeychainFault()
        let reader = ChromeCookieReader(root: root, passwordProvider: { try fault.deny($0) })
        let manager = UsageManager(statusItem: nil, delegate: nil, defaults: defaults,
                                   chromeReader: reader, apiSession: session)
        controls(manager)
        try work(manager, session, fault)
        controls(manager)
    }
    private static func connect(_ manager: UsageManager, _ session: URLSession) {
        let before = ConnectionProtocol.requestCount
        ConnectionProtocol.enqueue(200)
        manager.fetchUsageWithOrgId(org)
        wait(manager, "successful synthetic usage") {
            ConnectionProtocol.requestCount == before + 1 && manager.hasFetchedData && !manager.isLoading
        }
        settle(manager, session)
        check(manager.sessionUtilization == 37 && manager.weeklyUsage == 19, "known usage establishes connection")
    }
    private static func keychainMessage(_ manager: UsageManager) {
        check(manager.settingsChromeMessage?.range(of: "keychain", options: .caseInsensitive) != nil,
              "Settings exposes the Keychain failure text")
        check(manager.settingsChromeMessage == manager.chromeMessage,
              "Settings shows the actual published Chrome failure text")
    }
    private static func detect(_ manager: UsageManager, _ fault: KeychainFault, interactive: Bool) {
        let before = fault.attempts.count
        manager.detectChromeSession(interactive: interactive)
        wait(manager, "Keychain-denied Chrome detection") {
            fault.attempts.count == before + 1 && !manager.isDetectingChrome && manager.chromeMessage != nil
        }
        check(fault.attempts.last == interactive, "only explicit Detect may request Keychain interaction")
    }
    private static func backgroundFailureWhileConnected() throws {
        try withFixture { manager, session, fault in
            connect(manager, session)
            let usage = manager.menuBarOptions
            let display = manager.menuBarDisplayOptions
            let requests = ConnectionProtocol.requestCount
            detect(manager, fault, interactive: false)
            check(manager.settingsChromeMessage == nil, "working usage hides background Keychain failure")
            check(manager.connectionSummary?.hasPrefix("Connected via Chrome") == true, "enabled sync retains Chrome connection summary")
            check(manager.hasFetchedData && manager.menuBarOptions == usage && manager.menuBarDisplayOptions == display,
                  "background sync failure preserves working usage")
            check(ConnectionProtocol.requestCount == requests, "failed Chrome discovery never refetches usage")
        }
    }
    private static func interactiveFailureWithManualCookie() throws {
        try withFixture { manager, session, fault in
            connect(manager, session)
            detect(manager, fault, interactive: false)
            let backgroundMessage = manager.chromeMessage
            check(backgroundMessage?.range(of: "keychain", options: .caseInsensitive) != nil,
                  "background discovery publishes the injected Keychain failure")
            check(manager.settingsChromeMessage == nil, "background denial is hidden before manual save")
            let before = ConnectionProtocol.requestCount
            ConnectionProtocol.enqueue(200)
            manager.saveSessionCookie("sessionKey=synthetic-manual; lastActiveOrg=\(org)")
            controls(manager)
            wait(manager, "manual cookie fetched") {
                ConnectionProtocol.requestCount == before + 1 && manager.hasFetchedData && !manager.isLoading
            }
            settle(manager, session)
            check(!manager.chromeDetectionEnabled, "manual save disables automatic Chrome sync")
            check(manager.connectionSummary == "Connected with a manual cookie", "manual save updates connection summary")
            let usage = manager.menuBarOptions
            let display = manager.menuBarDisplayOptions
            let attempts = fault.attempts.count
            // Disabled automatic sync makes background Detect a no-op; it cannot call the denied reader.
            manager.detectChromeSession()
            controls(manager)
            check(fault.attempts.count == attempts && !manager.isDetectingChrome,
                  "disabled background detection never invokes the Chrome reader")
            check(manager.settingsChromeMessage == nil, "disabled background sync does not show a reconnect failure")
            check(manager.connectionSummary == "Connected with a manual cookie", "disabled background check preserves manual connection")
            check(manager.hasFetchedData && manager.menuBarOptions == usage && manager.menuBarDisplayOptions == display,
                  "disabled background check preserves working manual usage")
            detect(manager, fault, interactive: true)
            keychainMessage(manager)
            check(manager.connectionSummary == "Connected with a manual cookie", "interactive Chrome failure keeps manual connection")
            check(manager.hasFetchedData && manager.menuBarOptions == usage, "interactive failure preserves working usage")
        }
    }
    private static func failureBeforeFirstSuccess() throws {
        try withFixture { manager, _, fault in
            check(!manager.hasFetchedData && manager.connectionSummary == nil, "no connection summary before usage succeeds")
            detect(manager, fault, interactive: false)
            keychainMessage(manager)
            check(manager.connectionSummary == nil && manager.showsClaudeConnectionControls,
                  "first-connection Keychain failure remains actionable")
        }
    }
    private static func authFailureAfterHiddenSyncFailure() throws {
        try withFixture { manager, session, fault in
            connect(manager, session)
            detect(manager, fault, interactive: false)
            check(manager.settingsChromeMessage == nil, "background failure initially hidden")
            let before = ConnectionProtocol.requestCount
            ConnectionProtocol.enqueue(401)
            manager.fetchUsageWithOrgId(org)
            wait(manager, "HTTP 401 disconnects") {
                ConnectionProtocol.requestCount == before + 1 && !manager.hasFetchedData && !manager.isLoading
            }
            settle(manager, session)
            check(manager.connectionSummary == nil, "actual authentication failure removes connection summary")
            keychainMessage(manager)
            check(manager.showsClaudeConnectionControls, "actual authentication failure exposes connect controls")
        }
    }
    static func main() throws {
        _ = NSApplication.shared
        try backgroundFailureWhileConnected()
        try interactiveFailureWithManualCookie()
        try failureBeforeFirstSuccess()
        try authFailureAfterHiddenSyncFailure()
        check(ConnectionProtocol.unexpectedCount == 0, "all HTTP used declared offline fixtures")
        print("ClaudeSettingsConnectionTests passed")
    }
}
