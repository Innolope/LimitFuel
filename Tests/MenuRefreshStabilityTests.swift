import Foundation
import AppKit
import Combine

// Frozen spec-only suite. HTTP uses URLProtocol; Codex uses an injected fetcher.
// No production source, existing tests, real Chrome profile or Keychain was read.
private enum StabilityFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case let .assertion(message): return message } }
}
private enum OtherFetchError: Error { case synthetic }

private final class FixtureProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var error: Error? = nil
        var held: Bool = false
    }
    private static let lock = NSLock()
    private static var queue: [Reply] = []
    private static var pending: [(FixtureProtocol, Reply)] = []
    private static var started = 0
    private static var unexpected = 0
    private static var allStarted = 0
    private static var allCompleted = 0
    private static var mainCompleted = 0
    private var isMainUsage = false
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    static var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
    static var completedRequestCount: Int { lock.lock(); defer { lock.unlock() }; return mainCompleted }
    static var isQuiescent: Bool {
        lock.lock(); defer { lock.unlock() }
        return mainCompleted == started && allCompleted == allStarted && allStarted == started * 4 && pending.isEmpty
    }
    static func enqueue(_ reply: Reply) { lock.lock(); queue.append(reply); lock.unlock() }
    static func releaseAll() {
        lock.lock(); let ready = pending; pending.removeAll(); lock.unlock()
        for (request, reply) in ready { request.deliver(reply) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.allStarted += 1; Self.lock.unlock()
        // The public HTTP packet was supplemented after freeze: main /usage
        // also triggers three optional reads. Route these independently so they
        // cannot consume or hold the next main-request acceptance outcome.
        guard let url = request.url else {
            rejectUnexpected(); return
        }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let mainUsage = url.path.hasSuffix("/usage") && queryItems.isEmpty
        let auxiliaryUsage = url.path.hasSuffix("/usage") && queryItems.count == 2 &&
            queryItems.contains { $0.name == "cedar_ember" && $0.value == "1" } &&
            queryItems.contains { $0.name == "skip_spend" && $0.value == "1" }
        let auxiliarySpend = url.path.hasSuffix("/overage_spend_limit") && queryItems.isEmpty
        let auxiliaryCredits = url.path.hasSuffix("/prepaid/credits") && queryItems.isEmpty
        guard mainUsage else {
            if auxiliaryUsage || auxiliarySpend || auxiliaryCredits {
                deliver(.init(body: Data("{}".utf8)))
            } else {
                rejectUnexpected()
            }
            return
        }
        isMainUsage = true
        Self.lock.lock(); Self.started += 1
        guard !Self.queue.isEmpty else {
            Self.unexpected += 1; Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); recordCompletion(); return
        }
        let reply = Self.queue.removeFirst()
        if reply.held { Self.pending.append((self, reply)) }
        Self.lock.unlock()
        if !reply.held { deliver(reply) }
    }
    private func rejectUnexpected() {
        Self.lock.lock(); Self.unexpected += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        recordCompletion()
    }
    // Deliberately allow delivery after cancellation to challenge generation guards.
    override func stopLoading() {}
    private func deliver(_ reply: Reply) {
        defer { recordCompletion() }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status,
                         httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func recordCompletion() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.allCompleted += 1
        if isMainUsage { Self.mainCompleted += 1 }
    }
}

private final class CodexFixture {
    struct Reply { let result: Result<CodexSnapshot, Error>; var gate: DispatchSemaphore? = nil }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var calls = 0
    private var unexpected = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
    func enqueue(_ reply: Reply) { lock.lock(); replies.append(reply); lock.unlock() }
    func fetch() throws -> CodexSnapshot {
        lock.lock(); calls += 1
        guard !replies.isEmpty else { unexpected += 1; lock.unlock(); throw OtherFetchError.synthetic }
        let reply = replies.removeFirst(); lock.unlock()
        if let gate = reply.gate, gate.wait(timeout: .now() + 5) == .timedOut { throw CodexUsageError.timeout }
        return try reply.result.get()
    }
}

@main
struct MenuRefreshStabilityTests {
    private static var checks = 0
    private static var fixtureSession: URLSession!
    private static let cookie = "sessionKey=synthetic; lastActiveOrg=11111111-2222-4333-8444-555555555555"
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw StabilityFailure.assertion(message) }
    }
    private static func wait(_ message: String, seconds: TimeInterval = 4, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try expect(predicate(), "bounded wait: \(message)")
    }
    private static func drain(_ seconds: TimeInterval = 0.12) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    private static func quiesce(_ manager: UsageManager, _ message: String) throws {
        // A stale flag is set at poll start. Await transport completion and the
        // main publication, then all three optional reads before another poll.
        var checkingTasks = false
        var tasksDrained = false
        try wait("\(message): complete request and fixture quiescence") {
            guard !manager.isLoading && FixtureProtocol.isQuiescent else { return false }
            if !checkingTasks && !tasksDrained {
                checkingTasks = true
                fixtureSession.getAllTasks { tasks in
                    DispatchQueue.main.async {
                        tasksDrained = tasks.isEmpty
                        checkingTasks = false
                    }
                }
            }
            return tasksDrained
        }
    }
    private static func usage(_ percent: Double, weekly: Double? = 62) -> Data {
        var object: [String: Any] = ["five_hour": ["utilization": percent, "resets_at": "2027-01-02T12:00:00Z"]]
        if let weekly { object["seven_day"] = ["utilization": weekly, "resets_at": "2027-01-08T12:00:00Z"] }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private static func snapshot(_ percent: Double?, account: String = "synthetic-A") -> CodexSnapshot {
        CodexSnapshot(accountLabel: account, buckets: percent.map {
            [CodexBucket(id: "synthetic", name: "Synthetic", primary: CodexWindow(usedPercent: $0,
                         windowDurationMins: 300, resetsAt: Date(timeIntervalSince1970: 1_800_010_000)), secondary: nil)]
        } ?? [])
    }
    private static func claudeParseAndRetention(_ manager: UsageManager) throws {
        manager.parseUsageData(usage(0))
        try wait("Claude initial parsed zero") { manager.menuBarOptions.contains { $0.percent == 0 } }
        try expect(manager.menuBarDisplayOptions == manager.menuBarOptions && !manager.menuBarIsStale,
                   "successful parse copies raw current to fresh display")
        let expectedSessionReset = ISO8601DateFormatter().date(from: "2027-01-02T12:00:00Z")!
        try expect(manager.menuBarOptions.first { $0.percent == 0 }?.resetsAt == expectedSessionReset,
                   "Claude parser carries the session reset with its percentage")
        let known = manager.menuBarDisplayOptions
        for malformed in ["{", "{}", "{\"five_hour\":null}",
                          "{\"five_hour\":{\"utilization\":-1}}",
                          "{\"five_hour\":{\"utilization\":101}}",
                          "{\"five_hour\":{\"utilization\":\"bad\"}}"] {
            manager.parseUsageData(Data(malformed.utf8))
            try wait("malformed current clears") { manager.menuBarOptions.isEmpty && manager.menuBarIsStale }
            try expect(manager.menuBarDisplayOptions == known, "parse failure retains validated display separately from raw current")
        }
        let invalid = Data("{\"five_hour\":{\"utilization\":23,\"resets_at\":\"bad-date\"},\"seven_day\":{\"utilization\":101},\"seven_day_sonnet\":null}".utf8)
        manager.parseUsageData(invalid)
        try wait("optional invalid omitted") { !manager.menuBarIsStale && manager.menuBarOptions.count == 1 }
        try expect(manager.menuBarOptions[0].percent == 23 && manager.menuBarOptions[0].resetsAt == nil,
                   "invalid reset omits reset only; invalid optional windows are absent")
        try expect(manager.menuBarDisplayOptions == manager.menuBarOptions, "success replaces display and removes old weekly")
        let allWindows = Data("{\"five_hour\":{\"utilization\":23,\"resets_at\":\"2027-01-02T12:00:00Z\"},\"seven_day\":{\"utilization\":61,\"resets_at\":\"2027-01-08T12:00:00Z\"},\"seven_day_sonnet\":{\"utilization\":79,\"resets_at\":\"2027-01-09T12:00:00Z\"},\"limits\":[{\"percent\":42,\"resets_at\":\"2027-01-03T12:00:00Z\",\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}]}".utf8)
        manager.parseUsageData(allWindows)
        try wait("all Claude windows parse") { manager.menuBarOptions.count == 4 && !manager.menuBarIsStale }
        for (percent, text) in [(23.0, "2027-01-02T12:00:00Z"), (61.0, "2027-01-08T12:00:00Z"),
                                (79.0, "2027-01-09T12:00:00Z"), (42.0, "2027-01-03T12:00:00Z")] {
            try expect(manager.menuBarOptions.first { $0.percent == percent }?.resetsAt == ISO8601DateFormatter().date(from: text),
                       "Claude percentage \(percent) carries its own reset")
        }
        var seed: UInt64 = 0x51AB1E
        for index in 0..<32 {
            seed = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let percent = Double(seed % 101)
            manager.parseUsageData(usage(percent, weekly: nil))
            try wait("seed 0x51AB1E index \(index)") { manager.menuBarOptions.count == 1 && manager.menuBarOptions[0].percent == percent }
            try expect(manager.menuBarDisplayOptions == manager.menuBarOptions && !manager.menuBarIsStale, "seeded valid response replaces display")
        }
    }
    private static func establish(_ manager: UsageManager, percent: Double = 31, using value: String = cookie) throws {
        let before = FixtureProtocol.requestCount
        FixtureProtocol.enqueue(.init(body: usage(percent)))
        manager.saveSessionCookie(value)
        // Both save-initiated and caller-initiated refresh obey the public contract.
        drain(0.03)
        if FixtureProtocol.requestCount == before { manager.fetchUsage() }
        try wait("Claude connected success") { !manager.menuBarIsStale && manager.menuBarDisplayOptions.contains { $0.percent == percent } }
        try quiesce(manager, "Claude connected success")
    }
    private static func claudeNetwork(_ manager: UsageManager) throws {
        try establish(manager)
        for reply in [FixtureProtocol.Reply(status: 429), .init(status: 500), .init(status: 502),
                      .init(error: URLError(.timedOut)), .init(error: URLError(.notConnectedToInternet))] {
            let display = manager.menuBarDisplayOptions
            let before = FixtureProtocol.requestCount
            FixtureProtocol.enqueue(reply); manager.fetchUsage()
            try wait("Claude transient request") { FixtureProtocol.requestCount > before }
            try wait("Claude transient stale") { manager.menuBarIsStale }
            try wait("Claude transient main completes") { FixtureProtocol.completedRequestCount > before && !manager.isLoading }
            try quiesce(manager, "Claude transient failure")
            try expect(manager.menuBarDisplayOptions == display, "transient fetch failure preserves connected display")
            FixtureProtocol.enqueue(.init(body: usage(45))); manager.fetchUsage()
            try wait("Claude transient recovery") { !manager.menuBarIsStale && manager.menuBarDisplayOptions.contains { $0.percent == 45 } }
            try quiesce(manager, "Claude transient recovery")
            try expect(manager.menuBarDisplayOptions == manager.menuBarOptions, "Claude recovery replaces raw and display")
        }
        for status in [401, 403] {
            FixtureProtocol.enqueue(.init(status: status)); manager.fetchUsage()
            try wait("Claude auth \(status) clears") { manager.menuBarDisplayOptions.isEmpty }
            try quiesce(manager, "Claude auth \(status)")
            try establish(manager)
        }
        let heldBefore = FixtureProtocol.requestCount
        let oldDisplay = manager.menuBarDisplayOptions
        FixtureProtocol.enqueue(.init(body: usage(73), held: true)); manager.fetchUsage()
        try wait("Claude held request starts") { FixtureProtocol.requestCount > heldBefore }
        for _ in 0..<12 { manager.fetchUsage() }
        drain()
        try expect(FixtureProtocol.requestCount == heldBefore + 1, "Claude duplicate fetches coalesce")
        try expect(manager.menuBarDisplayOptions == oldDisplay, "Claude loading retains display")
        manager.clearSessionCookie()
        try wait("Claude sign-out clears") { manager.menuBarDisplayOptions.isEmpty }
        FixtureProtocol.releaseAll(); drain()
        try quiesce(manager, "Claude cleared late response")
        try expect(manager.menuBarDisplayOptions.isEmpty && manager.menuBarOptions.isEmpty, "late response after clear cannot repopulate current or display")

        try establish(manager)
        let stable = manager.menuBarDisplayOptions
        let rotationBefore = FixtureProtocol.requestCount
        FixtureProtocol.enqueue(.init(body: usage(46), held: true))
        manager.saveSessionCookie(cookie + "; auxiliary=rotated")
        drain(0.03)
        if FixtureProtocol.requestCount == rotationBefore { manager.fetchUsage() }
        try wait("same-session auxiliary rotation starts") { FixtureProtocol.requestCount > rotationBefore }
        try expect(manager.menuBarDisplayOptions == stable, "auxiliary cookie rotation preserves display during fetch")
        FixtureProtocol.releaseAll()
        try wait("rotation success") { manager.menuBarDisplayOptions.contains { $0.percent == 46 } }
        try quiesce(manager, "Claude auxiliary rotation")
        for replacement in ["sessionKey=changed; lastActiveOrg=11111111-2222-4333-8444-555555555555",
                            "sessionKey=changed; lastActiveOrg=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"] {
            let before = FixtureProtocol.requestCount
            FixtureProtocol.enqueue(.init(body: usage(58), held: true)); manager.saveSessionCookie(replacement)
            try expect(manager.menuBarDisplayOptions.isEmpty, "changed sessionKey or organization clears display before fetch")
            drain(0.03)
            if FixtureProtocol.requestCount == before { manager.fetchUsage() }
            try wait("identity replacement starts") { FixtureProtocol.requestCount > before }
            FixtureProtocol.releaseAll()
            try wait("identity replacement publishes") { !manager.menuBarIsStale && manager.menuBarDisplayOptions.contains { $0.percent == 58 } }
            try quiesce(manager, "Claude identity replacement")
        }
        manager.clearSessionCookie()
        try expect(manager.menuBarDisplayOptions.isEmpty, "explicit clear removes retained identity values")
    }
    private static func codexTransitions() throws {
        let fixture = CodexFixture()
        var notifications = 0
        let manager = CodexUsageManager(fetcher: { try fixture.fetch() }, notificationsEnabled: { true }, notify: { _, _ in notifications += 1 })
        fixture.enqueue(.init(result: .success(snapshot(0)))); manager.fetchUsage()
        try wait("Codex initial success") { !manager.isLoading && manager.snapshot != nil }
        try expect(manager.menuBarDisplayOptions == manager.snapshot!.menuBarOptions && !manager.menuBarIsStale, "Codex fresh display mirrors raw snapshot")
        try expect(manager.menuBarDisplayOptions.contains { $0.percent == 0 }, "Codex zero remains available")
        let errors: [Error] = [CodexUsageError.timeout, CodexUsageError.protocolFailure, CodexUsageError.invalidData, CodexUsageError.unavailable, OtherFetchError.synthetic]
        for error in errors {
            let display = manager.menuBarDisplayOptions
            let notificationsBefore = notifications
            fixture.enqueue(.init(result: .failure(error))); manager.fetchUsage()
            try wait("Codex error publication") { !manager.isLoading && manager.errorMessage != nil }
            try expect(manager.snapshot == nil, "Codex raw snapshot stays nil on failure")
            try expect(manager.menuBarDisplayOptions == display && manager.menuBarIsStale, "Codex transient failure retains stale display")
            try expect(notifications == notificationsBefore, "failed refresh adds no alerts with notifications enabled")
            fixture.enqueue(.init(result: .success(snapshot(29)))); manager.fetchUsage()
            try wait("Codex recovery") { !manager.isLoading && manager.snapshot != nil && manager.errorMessage == nil }
            try expect(manager.menuBarDisplayOptions == manager.snapshot!.menuBarOptions && !manager.menuBarIsStale, "Codex recovery replaces raw and display")
        }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        fixture.enqueue(.init(result: .success(snapshot(64)), gate: gate))
        let before = fixture.callCount
        let known = manager.menuBarDisplayOptions
        manager.fetchUsage()
        try wait("Codex held fetch starts") { manager.isLoading && fixture.callCount > before }
        for _ in 0..<12 { manager.fetchUsage() }
        drain()
        try expect(fixture.callCount == before + 1, "Codex duplicate fetches coalesce")
        try expect(manager.menuBarDisplayOptions == known, "Codex loading retains display")
        gate.signal()
        try wait("Codex held fetch completes") { !manager.isLoading && manager.menuBarDisplayOptions.contains { $0.percent == 64 } }
        fixture.enqueue(.init(result: .failure(CodexUsageError.signIn))); manager.fetchUsage()
        try wait("Codex auth failure publishes") { !manager.isLoading && manager.errorMessage != nil }
        try expect(manager.snapshot == nil && manager.menuBarDisplayOptions.isEmpty, "Codex auth failure clears old values")
        fixture.enqueue(.init(result: .success(snapshot(87, account: "synthetic-B")))); manager.fetchUsage()
        try wait("Codex account recovery") { !manager.isLoading && manager.snapshot?.accountLabel == "synthetic-B" }
        try expect(manager.menuBarDisplayOptions.count == 1 && manager.menuBarDisplayOptions[0].percent == 87 && !manager.menuBarIsStale, "new account replaces all prior display")
        fixture.enqueue(.init(result: .success(snapshot(nil, account: "synthetic-B")))); manager.fetchUsage()
        try wait("Codex valid empty") { !manager.isLoading && manager.snapshot != nil && manager.snapshot!.buckets.isEmpty }
        try expect(manager.menuBarDisplayOptions.isEmpty && !manager.menuBarIsStale, "valid empty clears previous display and remains fresh")
        try expect(fixture.unexpectedCount == 0, "every Codex fetch used a declared local outcome")
    }
    static func main() {
        let suite = "LimitFuel.MenuRefreshStability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        for key in ["chrome_detection_enabled", "usage_notifications_enabled", "status_notifications_enabled"] {
            defaults.set(false, forKey: key)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        fixtureSession = session
        defer {
            FixtureProtocol.releaseAll(); session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            _ = NSApplication.shared
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let reader = ChromeCookieReader(root: root, passwordProvider: { _ in fatalError("fixture forbids Keychain") })
            let manager = UsageManager(statusItem: nil, defaults: defaults, chromeReader: reader, apiSession: session)
            try claudeParseAndRetention(manager)
            try claudeNetwork(manager)
            try codexTransitions()
            try expect(FixtureProtocol.unexpectedCount == 0, "every Claude request used a declared synthetic outcome")
            print("PASS MenuRefreshStabilityTests: \(checks) checks; seed=0x51AB1E; parse workload=32; bursts=12; waits<=4s; gates<=5s")
        } catch {
            fputs("FAIL MenuRefreshStabilityTests: \(error)\n", stderr); exit(1)
        }
    }
}
