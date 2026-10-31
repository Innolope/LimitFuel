import Foundation
import AppKit
import Combine

// Frozen spec-only suite. Fixtures use only the frozen MenuRefreshStabilityTests APIs.
private enum AgeFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case let .assertion(message): return message } }
}

private final class AgeProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var body = Data()
        var held = false
        var delay: TimeInterval = 0.2
    }
    private static let lock = NSLock()
    private static var queue: [Reply] = []
    private static var pending: [(AgeProtocol, Reply)] = []
    private static var calls = 0
    private static var unexpected = 0
    private static var allStarted = 0
    private static var allCompleted = 0
    private static var mainCompleted = 0
    private var isMainUsage = false
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    static var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
    static var completedRequestCount: Int { lock.lock(); defer { lock.unlock() }; return mainCompleted }
    // A request cancelled before URLSession starts it never reaches startLoading,
    // so a test that cancels a poll must first let all four of its requests start.
    static var allRequestsStarted: Bool { lock.lock(); defer { lock.unlock() }; return allStarted == calls * 4 }
    static var isQuiescent: Bool {
        lock.lock(); defer { lock.unlock() }
        return mainCompleted == calls && allCompleted == allStarted && allStarted == calls * 4 && pending.isEmpty
    }
    static func enqueue(_ reply: Reply) { lock.lock(); queue.append(reply); lock.unlock() }
    static func releaseAll() {
        lock.lock(); let ready = pending; pending.removeAll(); lock.unlock()
        for (request, reply) in ready { request.schedule(reply) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.allStarted += 1; Self.lock.unlock()
        guard let url = request.url else { reject(); return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let main = url.path.hasSuffix("/usage") && query.isEmpty
        let auxiliaryUsage = url.path.hasSuffix("/usage") && query.count == 2 &&
            query.contains { $0.name == "cedar_ember" && $0.value == "1" } &&
            query.contains { $0.name == "skip_spend" && $0.value == "1" }
        let auxiliarySpend = url.path.hasSuffix("/overage_spend_limit") && query.isEmpty
        let auxiliaryCredits = url.path.hasSuffix("/prepaid/credits") && query.isEmpty
        guard main else {
            if auxiliaryUsage || auxiliarySpend || auxiliaryCredits {
                deliver(.init(body: Data("{}".utf8), delay: 0))
            } else { reject() }
            return
        }
        isMainUsage = true
        Self.lock.lock(); Self.calls += 1
        guard !Self.queue.isEmpty else {
            Self.unexpected += 1; Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); recordCompletion(); return
        }
        let reply = Self.queue.removeFirst()
        if reply.held { Self.pending.append((self, reply)) }
        Self.lock.unlock()
        if !reply.held { schedule(reply) }
    }
    private func reject() {
        Self.lock.lock(); Self.unexpected += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        recordCompletion()
    }
    // Allow held delivery after cancellation to challenge generation guards.
    override func stopLoading() {}
    private func schedule(_ reply: Reply) {
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { self.deliver(reply) }
    }
    private func deliver(_ reply: Reply) {
        defer { recordCompletion() }
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

private final class AgeCodexFixture {
    struct Reply {
        let result: Result<CodexSnapshot, Error>
        var gate: DispatchSemaphore? = nil
    }
    private let lock = NSLock()
    private var queue: [Reply] = []
    private var unexpected = 0
    var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
    func enqueue(_ reply: Reply) { lock.lock(); queue.append(reply); lock.unlock() }
    func fetch() throws -> CodexSnapshot {
        lock.lock()
        guard !queue.isEmpty else {
            unexpected += 1; lock.unlock(); throw CodexUsageError.invalidData
        }
        let reply = queue.removeFirst(); lock.unlock()
        if let gate = reply.gate, gate.wait(timeout: .now() + 4) == .timedOut {
            throw CodexUsageError.timeout
        }
        return try reply.result.get()
    }
}

@main
struct ProviderUpdateAgeTests {
    private static var checks = 0
    private static var fixtureSession: URLSession!
    private static let cookie = "sessionKey=synthetic; lastActiveOrg=11111111-2222-4333-8444-555555555555"
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw AgeFailure.assertion(message) }
    }
    private static func wait(_ message: String, seconds: TimeInterval = 4,
                             until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        try expect(predicate(), "bounded wait: \(message)")
    }
    private static func drain(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    private static func quiesce(_ manager: UsageManager, _ message: String) throws {
        var checkingTasks = false
        var tasksDrained = false
        try wait("\(message): complete request and fixture quiescence") {
            guard !manager.isLoading && AgeProtocol.isQuiescent else { return false }
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
    private static func usage(_ percent: Double) -> Data {
        let window: [String: Any] = ["utilization": percent, "resets_at": "2027-01-02T12:00:00Z"]
        return try! JSONSerialization.data(withJSONObject: ["five_hour": window], options: [.sortedKeys])
    }
    private static func snapshot(_ percent: Double) -> CodexSnapshot {
        CodexSnapshot(accountLabel: "synthetic-A", buckets: [
            CodexBucket(id: "synthetic", name: "Synthetic",
                        primary: CodexWindow(usedPercent: percent, windowDurationMins: 300,
                            resetsAt: Date(timeIntervalSince1970: 1_800_010_000)), secondary: nil)
        ])
    }
    private static func establish(_ manager: UsageManager, percent: Double) throws {
        let before = AgeProtocol.requestCount
        AgeProtocol.enqueue(.init(body: usage(percent)))
        manager.saveSessionCookie(cookie)
        drain(0.03)
        if AgeProtocol.requestCount == before { manager.fetchUsage() }
        try wait("Claude successful usage") {
            manager.menuBarUpdatedAt != nil && !manager.menuBarIsStale &&
            manager.menuBarDisplayOptions.contains { $0.percent == percent }
        }
        try quiesce(manager, "Claude successful usage")
    }
    private static func codexSuccess(_ manager: CodexUsageManager,
                                     fixture: AgeCodexFixture, percent: Double) throws {
        let gate = DispatchSemaphore(value: 0)
        fixture.enqueue(.init(result: .success(snapshot(percent)), gate: gate))
        manager.fetchUsage()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gate.signal() }
        try wait("Codex successful usage") {
            !manager.isLoading && manager.menuBarUpdatedAt != nil &&
            manager.menuBarDisplayOptions.contains { $0.percent == percent }
        }
    }
    private static func transitions(_ claude: UsageManager, _ codex: CodexUsageManager,
                                    fixture: AgeCodexFixture) throws {
        try expect(claude.menuBarUpdatedAt == nil && codex.menuBarUpdatedAt == nil,
                   "both managers start without a successful-usage timestamp")
        try establish(claude, percent: 31)
        guard let c1 = claude.menuBarUpdatedAt else { throw AgeFailure.assertion("Claude initial timestamp") }
        try expect(codex.menuBarUpdatedAt == nil, "Claude success leaves uninitialized Codex age alone")
        try codexSuccess(codex, fixture: fixture, percent: 29)
        guard let x1 = codex.menuBarUpdatedAt else { throw AgeFailure.assertion("Codex initial timestamp") }
        try expect(claude.menuBarUpdatedAt == c1, "Codex success leaves Claude timestamp exact")

        let cKnown = claude.menuBarDisplayOptions
        let mainBefore = AgeProtocol.requestCount
        AgeProtocol.enqueue(.init(status: 500))
        claude.fetchUsage()
        try wait("Claude HTTP500 request starts") { AgeProtocol.requestCount > mainBefore }
        try expect(claude.menuBarUpdatedAt == c1, "poll start cannot advance Claude success timestamp")
        try wait("Claude HTTP500 marks stale") { claude.menuBarIsStale }
        try wait("Claude HTTP500 main completes") { AgeProtocol.completedRequestCount > mainBefore && !claude.isLoading }
        try quiesce(claude, "Claude HTTP500")
        try expect(claude.menuBarUpdatedAt == c1 && claude.menuBarDisplayOptions == cKnown,
                   "HTTP500 preserves exact Claude timestamp and last-known display")
        try expect(codex.menuBarUpdatedAt == x1, "Claude HTTP500 leaves Codex timestamp exact")

        let xKnown = codex.menuBarDisplayOptions
        fixture.enqueue(.init(result: .failure(CodexUsageError.timeout)))
        codex.fetchUsage()
        try wait("Codex timeout publication") { !codex.isLoading && codex.errorMessage != nil }
        try expect(codex.menuBarUpdatedAt == x1 && codex.menuBarDisplayOptions == xKnown,
                   "Codex timeout preserves exact successful timestamp and display")
        try expect(claude.menuBarUpdatedAt == c1, "Codex timeout leaves Claude timestamp exact")

        AgeProtocol.enqueue(.init(body: usage(45)))
        claude.fetchUsage()
        try wait("Claude successful recovery") {
            !claude.menuBarIsStale && claude.menuBarDisplayOptions.contains { $0.percent == 45 }
        }
        try quiesce(claude, "Claude successful recovery")
        guard let c2 = claude.menuBarUpdatedAt else { throw AgeFailure.assertion("Claude recovery timestamp") }
        try expect(c2 > c1, "successful Claude recovery advances timestamp")
        try expect(codex.menuBarUpdatedAt == x1, "Claude recovery preserves Codex timestamp")
        try codexSuccess(codex, fixture: fixture, percent: 47)
        guard let x2 = codex.menuBarUpdatedAt else { throw AgeFailure.assertion("Codex recovery timestamp") }
        try expect(x2 > x1, "successful Codex recovery advances timestamp")
        try expect(claude.menuBarUpdatedAt == c2, "Codex recovery preserves Claude timestamp")

        let rotationBefore = AgeProtocol.requestCount
        AgeProtocol.enqueue(.init(body: usage(53), held: true))
        claude.saveSessionCookie(cookie + "; auxiliary=rotated")
        try expect(claude.menuBarUpdatedAt == c2, "same-key same-org auxiliary cookie save retains age")
        drain(0.03)
        if AgeProtocol.requestCount == rotationBefore { claude.fetchUsage() }
        try wait("same-account cookie refresh starts") { AgeProtocol.requestCount > rotationBefore }
        try expect(claude.menuBarUpdatedAt == c2, "held cookie refresh cannot renew usage age")
        AgeProtocol.releaseAll()
        try wait("same-account cookie refresh succeeds") {
            !claude.menuBarIsStale && claude.menuBarDisplayOptions.contains { $0.percent == 53 }
        }
        try quiesce(claude, "Claude same-account rotation")
        guard let c3 = claude.menuBarUpdatedAt else { throw AgeFailure.assertion("cookie recovery timestamp") }
        try expect(c3 > c2, "valid response after cookie rotation advances timestamp")
        try expect(codex.menuBarUpdatedAt == x2, "Claude cookie refresh leaves Codex age exact")

        claude.parseUsageData(Data("{}".utf8))
        try wait("Claude invalid usage marks stale") { claude.menuBarIsStale }
        try expect(claude.menuBarUpdatedAt == c3, "invalid parsed usage cannot renew timestamp")

        AgeProtocol.enqueue(.init(status: 401))
        claude.fetchUsage()
        try wait("Claude authentication failure clears") { claude.menuBarDisplayOptions.isEmpty }
        try quiesce(claude, "Claude authentication failure")
        try expect(claude.menuBarUpdatedAt == nil, "Claude auth failure clears successful timestamp")
        try expect(codex.menuBarUpdatedAt == x2, "Claude auth failure leaves Codex age exact")
        try establish(claude, percent: 61)
        guard let c4 = claude.menuBarUpdatedAt else { throw AgeFailure.assertion("Claude reauthentication timestamp") }

        let clearBefore = AgeProtocol.requestCount
        AgeProtocol.enqueue(.init(body: usage(71), held: true))
        claude.fetchUsage()
        try wait("Claude pre-clear request starts") {
            AgeProtocol.requestCount > clearBefore && AgeProtocol.allRequestsStarted
        }
        try expect(claude.menuBarUpdatedAt == c4, "pre-clear pending request retains timestamp")
        claude.clearSessionCookie()
        try expect(claude.menuBarUpdatedAt == nil, "explicit Claude clear resets timestamp immediately")
        AgeProtocol.releaseAll()
        drain(0.25)
        try quiesce(claude, "Claude cleared late response")
        try expect(claude.menuBarUpdatedAt == nil && claude.menuBarDisplayOptions.isEmpty,
                   "late successful response after clear cannot revive old timestamp or values")
        try expect(codex.menuBarUpdatedAt == x2, "Claude clear leaves Codex age exact")

        fixture.enqueue(.init(result: .failure(CodexUsageError.signIn)))
        codex.fetchUsage()
        try wait("Codex auth failure publishes") { !codex.isLoading && codex.errorMessage != nil }
        try expect(codex.menuBarUpdatedAt == nil && codex.menuBarDisplayOptions.isEmpty,
                   "Codex authentication failure clears timestamp and old values")
        try expect(claude.menuBarUpdatedAt == nil, "Codex auth failure leaves cleared Claude age alone")
        try expect(AgeProtocol.unexpectedCount == 0 && fixture.unexpectedCount == 0,
                   "all provider requests consumed declared synthetic outcomes")
    }
    static func main() {
        let suite = "LimitFuel.ProviderUpdateAge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        for key in ["chrome_detection_enabled", "usage_notifications_enabled", "status_notifications_enabled"] {
            defaults.set(false, forKey: key)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgeProtocol.self]
        let session = URLSession(configuration: config)
        fixtureSession = session
        defer {
            AgeProtocol.releaseAll(); session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            _ = NSApplication.shared
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let reader = ChromeCookieReader(root: root, passwordProvider: { _ in fatalError("fixture forbids Keychain") })
            let claude = UsageManager(statusItem: nil, defaults: defaults, chromeReader: reader, apiSession: session)
            let fixture = AgeCodexFixture()
            let codex = CodexUsageManager(fetcher: { try fixture.fetch() },
                                         notificationsEnabled: { false }, notify: { _, _ in })
            try transitions(claude, codex, fixture: fixture)
            print("PASS ProviderUpdateAgeTests: \(checks) checks; synthetic response delay=200ms; runloop slices<=5ms; bounded waits<=4s")
        } catch {
            fputs("FAIL ProviderUpdateAgeTests: \(error)\n", stderr); exit(1)
        }
    }
}
