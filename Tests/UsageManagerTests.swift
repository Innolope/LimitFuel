import Foundation
import AppKit
import SQLite3
import CommonCrypto

// Spec-only lifecycle contract tests. No real network, browser or Keychain.
private var count = 0
private func require(_ value: @autoclosure () -> Bool, _ message: String) {
    count += 1
    if !value() { fputs("FAIL lifecycle: \(message)\n", stderr); exit(1) }
}
private func spin(_ predicate: () -> Bool, timeout: TimeInterval = 4) -> Bool {
    let until = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    return predicate()
}
private final class MockProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var pending: [MockProtocol] = []
    static var held = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let hold = Self.held
        if hold { Self.pending.append(self) }
        Self.lock.unlock()
        if !hold { respond() }
    }
    override func stopLoading() {} // Allow deliberately late deliveries after cancellation.
    func respond() {
        let payload = Data(#"{"five_hour":{"utilization":37,"resets_at":"2099-01-01T00:00:00.000Z"},"seven_day":{"utilization":19,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func reset(hold: Bool = false) {
        lock.lock(); requests = []; pending = []; held = hold; lock.unlock()
    }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func release() {
        lock.lock(); let batch = pending; pending = []; held = false; lock.unlock()
        batch.forEach { $0.respond() }
    }
}
private let org = "11111111-2222-4333-8444-555555555555"
private let header = "sessionKey=synthetic-old; lastActiveOrg=\(org); extra=a=b"
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private func db(_ root: URL, profile: String = "Default", value: String = "synthetic-import", encrypted: Data = Data(), withOrg: Bool = false, auxiliary: String? = nil) throws {
    let dir = root.appendingPathComponent(profile)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var handle: OpaquePointer?
    guard sqlite3_open(dir.appendingPathComponent("Cookies").path, &handle) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, "CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO meta VALUES('version','23'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,top_frame_site_key TEXT)", nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "fixture", code: 2) }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(handle, "INSERT INTO cookies VALUES('.claude.ai','sessionKey',?,?,'/',0,1,'')", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, value, -1, transient)
    _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "fixture", code: 3) }
    if withOrg {
        guard sqlite3_exec(handle, "INSERT INTO cookies VALUES('.claude.ai','lastActiveOrg','\(org)',NULL,'/',0,1,'')", nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "fixture", code: 5) }
    }
    if let auxiliary {
        var auxStatement: OpaquePointer?
        sqlite3_prepare_v2(handle, "INSERT INTO cookies VALUES('.claude.ai','aux',?,NULL,'/',0,1,'')", -1, &auxStatement, nil)
        defer { sqlite3_finalize(auxStatement) }
        sqlite3_bind_text(auxStatement, 1, auxiliary, -1, transient)
        guard sqlite3_step(auxStatement) == SQLITE_DONE else { throw NSError(domain: "fixture", code: 6) }
    }
}
private func encryptedSession() throws -> Data {
    let pass = Array("synthetic-password".utf8), salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: 16)
    _ = pass.withUnsafeBytes { CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), $0.baseAddress!.assumingMemoryBound(to: Int8.self), pass.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, 16) }
    let bytes = Array("synthetic-delayed".utf8), iv = [UInt8](repeating: 32, count: 16)
    var out = [UInt8](repeating: 0, count: bytes.count + 16), written = 0
    let capacity = out.count
    guard CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, 16, iv, bytes, bytes.count, &out, capacity, &written) == kCCSuccess else { throw NSError(domain: "fixture", code: 4) }
    return Data("v10".utf8) + Data(out.prefix(written))
}
@main struct LifecycleTests {
    static func main() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? "/private/tmp").appendingPathComponent("lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var index = 0
        var suites: [String] = []
        defer { suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
        func fixture(cookie: String? = nil, enabled: Bool? = nil, reader: ChromeCookieReader? = nil, threshold: Int? = nil, usageNotifications: Bool = false) -> (UsageManager, UserDefaults, URL) {
            index += 1
            let suite = "LimitFuel.Acceptance.\(UUID().uuidString)"
            suites.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(usageNotifications, forKey: "usage_notifications_enabled")
            defaults.set(false, forKey: "status_notifications_enabled")
            if let cookie { defaults.set(cookie, forKey: "claude_session_cookie") }
            if let enabled { defaults.set(enabled, forKey: "chrome_detection_enabled") }
            if let threshold { defaults.set(threshold, forKey: "last_notified_threshold") }
            let root = base.appendingPathComponent("case-\(index)")
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockProtocol.self]
            let session = URLSession(configuration: config)
            let chrome = reader ?? ChromeCookieReader(root: root, passwordProvider: { _ in Data("synthetic-password".utf8) })
            let manager = UsageManager(statusItem: nil, delegate: nil, defaults: defaults, chromeReader: chrome, apiSession: session)
            return (manager, defaults, root)
        }
        MockProtocol.reset(hold: true)
        let (coalesced, _, _) = fixture(cookie: header, enabled: true)
        coalesced.fetchUsage(); coalesced.fetchUsage(); coalesced.fetchUsage()
        require(spin { MockProtocol.snapshot().count == 4 }, "one main plus three auxiliary requests")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        require(MockProtocol.snapshot().count == 4, "overlapping fetches coalesce")
        require(MockProtocol.snapshot().allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == header }, "full stored header on every authenticated endpoint")
        MockProtocol.release()
        require(spin { !coalesced.isLoading && coalesced.hasFetchedData }, "successful fetch settles")
        coalesced.saveSessionCookie("sessionKey=")
        require(coalesced.chromeDetectionEnabled, "invalid manual save does not disable Chrome mode")
        MockProtocol.reset(hold: true)
        coalesced.saveSessionCookie("sessionKey=synthetic-manual; lastActiveOrg=\(org)")
        require(!coalesced.chromeDetectionEnabled, "manual save disables Chrome mode")
        require(!coalesced.hasFetchedData, "manual save resets previous fetched state")
        require(spin { MockProtocol.snapshot().count == 4 }, "manual save immediately fetches")
        coalesced.clearSessionCookie()
        require(!coalesced.isLoading && !coalesced.hasFetchedData && !coalesced.chromeDetectionEnabled, "clear resets request and mode state")
        MockProtocol.release()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        require(!coalesced.hasFetchedData, "delayed completion after clear cannot repopulate usage")

        MockProtocol.reset(hold: true)
        let (bootstrap, _, _) = fixture(cookie: "sessionKey=bootstrap; extra=a=b")
        bootstrap.fetchUsage()
        require(spin { !MockProtocol.snapshot().isEmpty }, "bootstrap starts")
        require(MockProtocol.snapshot().first?.value(forHTTPHeaderField: "Cookie") == "sessionKey=bootstrap; extra=a=b", "bootstrap preserves full cookie header")
        bootstrap.clearSessionCookie()
        MockProtocol.release()
        let (legacy, legacyDefaults, _) = fixture(cookie: header)
        require(!legacy.chromeDetectionEnabled, "legacy saved cookie defaults to manual mode")
        legacy.detectChromeSession()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        require(legacyDefaults.string(forKey: "claude_session_cookie") == header, "legacy identity preserved")
        legacy.clearSessionCookie()
        let (parser, _, _) = fixture()
        let validHigh = Data(#"{"five_hour":{"utilization":95,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        for invalidJSON in [#"{"five_hour":{"utilization":null}}"#, #"{"five_hour":{}}"#, #"{"five_hour":{"utilization":101}}"#, #"{"five_hour":{"utilization":-1}}"#, "[]", "not-json"] {
            parser.parseUsageData(validHigh)
            require(parser.hasFetchedData && parser.sessionUtilization == 95, "valid high parser fixture")
            require(RefreshSchedule.pollingInterval(usedPercent: parser.sessionUtilization, windowDurationMins: 300, resetsAt: parser.sessionResetsAt) == 12, "valid high parser state accelerates")
            parser.parseUsageData(Data(invalidJSON.utf8))
            require(!parser.hasFetchedData && parser.sessionUtilization == 0, "invalid/missing utilization clears stale high state")
            require(RefreshSchedule.pollingInterval(usedPercent: parser.sessionUtilization, windowDurationMins: 300, resetsAt: parser.sessionResetsAt) == 60, "invalid/missing utilization returns normal cadence")
        }
        parser.parseUsageData(Data(#"{"five_hour":{"utilization":95,"resets_at":"2000-01-01T00:00:00Z"}}"#.utf8))
        require(parser.hasFetchedData && parser.sessionResetsAt != nil, "nonfractional RFC3339 reset parses")
        require(RefreshSchedule.pollingInterval(usedPercent: parser.sessionUtilization, windowDurationMins: 300, resetsAt: parser.sessionResetsAt) == 60, "nonfractional past reset restores normal cadence")
        parser.clearSessionCookie()
        // Existing history prevents notification delivery; stop before any later high
        // response if the invalid-data regression incorrectly erases that history.
        for invalidJSON in ["not-json", #"{"seven_day":{"utilization":20}}"#] {
            let (history, historyDefaults, _) = fixture(threshold: 90, usageNotifications: true)
            history.parseUsageData(validHigh)
            history.updateStatusBar()
            require(historyDefaults.integer(forKey: "last_notified_threshold") == 90, "seeded high usage retains notification history without delivery")
            history.parseUsageData(Data(invalidJSON.utf8))
            history.updateStatusBar()
            require(historyDefaults.integer(forKey: "last_notified_threshold") == 90, "temporary invalid or absent five-hour data preserves notification history")
            // Do not clear here: that explicitly resets state and is a different action.
        }

        MockProtocol.reset()
        let (single, singleDefaults, singleRoot) = fixture()
        require(single.chromeDetectionEnabled, "Chrome mode defaults enabled")
        try db(singleRoot, withOrg: true)
        single.detectChromeSession()
        require(spin { !single.isDetectingChrome && singleDefaults.string(forKey: "chrome_profile_id") == "Default" }, "singleton imported and pinned")
        require(singleDefaults.string(forKey: "claude_session_cookie")?.contains("sessionKey=synthetic-import") == true, "singleton saves imported session")
        require(spin { single.hasFetchedData && !single.isLoading }, "import fetch completes")
        MockProtocol.reset()
        single.detectChromeSession()
        require(spin { !single.isDetectingChrome }, "unchanged detection settles")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        require(MockProtocol.snapshot().isEmpty, "unchanged detection skips fetch after successful usage")
        single.clearSessionCookie()

        MockProtocol.reset(hold: true)
        let (rotated, rotatedDefaults, rotatedRoot) = fixture(cookie: "sessionKey=synthetic-import; lastActiveOrg=\(org); aux=one", enabled: true, threshold: 75)
        try db(rotatedRoot, withOrg: true, auxiliary: "two")
        rotated.detectChromeSession()
        require(spin { !rotated.isDetectingChrome && MockProtocol.snapshot().count == 4 }, "auxiliary rotation imported and fetch started")
        require(rotatedDefaults.string(forKey: "claude_session_cookie")?.contains("aux=two") == true, "auxiliary rotated cookie stored")
        require(rotatedDefaults.integer(forKey: "last_notified_threshold") == 75, "same session and org auxiliary rotation preserves notification threshold")
        rotated.clearSessionCookie(); MockProtocol.release()

        MockProtocol.reset(hold: true)
        let (disabled, disabledDefaults, disabledRoot) = fixture(cookie: header, enabled: false)
        try db(disabledRoot)
        disabled.detectChromeSession()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        require(disabledDefaults.string(forKey: "claude_session_cookie") == header && !disabled.chromeDetectionEnabled, "disabled mode prevents background import")
        disabled.detectChromeSession(interactive: true)
        require(spin { !disabled.isDetectingChrome && disabled.chromeDetectionEnabled }, "successful explicit detection reenables mode")
        disabled.clearSessionCookie(); MockProtocol.release()
        let (failedInteractive, _, _) = fixture(cookie: header, enabled: false)
        failedInteractive.detectChromeSession(interactive: true)
        require(spin { !failedInteractive.isDetectingChrome }, "failed interactive discovery settles")
        require(!failedInteractive.chromeDetectionEnabled, "failed explicit discovery cannot reenable mode")
        failedInteractive.clearSessionCookie()

        MockProtocol.reset()
        let (multiple, multipleDefaults, multipleRoot) = fixture(cookie: header, enabled: true)
        try db(multipleRoot); try db(multipleRoot, profile: "Profile 1", value: "second")
        multiple.detectChromeSession()
        require(spin { !multiple.isDetectingChrome && multiple.chromeProfiles.count == 2 }, "multiple profiles publish choices")
        require(multipleDefaults.string(forKey: "claude_session_cookie") == header && multipleDefaults.string(forKey: "chrome_profile_id") == nil, "ambiguous discovery never selects or replaces")
        multipleDefaults.set("Profile 7", forKey: "chrome_profile_id")
        multiple.detectChromeSession()
        require(spin { !multiple.isDetectingChrome }, "missing pinned session settles")
        require(multipleDefaults.string(forKey: "claude_session_cookie") == header, "missing pinned session preserves credential")
        multiple.clearSessionCookie()

        for save in [false, true] {
            MockProtocol.reset(hold: true)
            let root = base.appendingPathComponent("blocked-\(save)")
            try db(root, value: "", encrypted: encryptedSession())
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let reader = ChromeCookieReader(root: root, passwordProvider: { _ in entered.signal(); _ = release.wait(timeout: .now() + 5); return Data("synthetic-password".utf8) })
            let (manager, defaults, _) = fixture(cookie: header, reader: reader)
            manager.detectChromeSession(interactive: true)
            require(entered.wait(timeout: .now() + 2) == .success, "import reaches blocking provider off main thread")
            if save { manager.saveSessionCookie("sessionKey=manual-wins; lastActiveOrg=\(org)") }
            else { manager.clearSessionCookie() }
            release.signal()
            require(spin { !manager.isDetectingChrome }, "stale import settles")
            require(defaults.string(forKey: "claude_session_cookie") == (save ? "sessionKey=manual-wins; lastActiveOrg=\(org)" : nil), "manual mutation wins over delayed import")
            require(!manager.chromeDetectionEnabled, "stale import cannot reenable automatic mode")
            manager.clearSessionCookie(); MockProtocol.release()
        }
        print("PASS lifecycle: \(count) checks; synthetic URLProtocol and blocking-provider faults")
    }
}
