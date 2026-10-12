import Foundation
import AppKit

private final class FakeUsageProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: Data
        let error: URLError?
    }
    static var next = Reply(status: 200, body: Data(), error: nil)
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let reply = Self.next
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
struct ClaudeAcceptance {
    static var assertions = 0
    static var failures = 0
    static var cases = 0
    static let reset = "2030-01-02T03:04:05Z"
    static let expectedReset = ISO8601DateFormatter().date(from: reset)!

    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        if !value() { failures += 1; print("FAIL: \(label)") }
    }
    static func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func base() -> [String: Any] {
        ["five_hour": ["utilization": 25, "resets_at": reset]]
    }
    static func present() -> [String: Any] {
        var object = base()
        object["seven_day"] = ["utilization": 42, "resets_at": reset]
        object["seven_day_sonnet"] = ["utilization": 43, "resets_at": reset]
        object["limits"] = [["percent": 44, "resets_at": reset, "scope": ["model": ["display_name": "Fable"]]]]
        return object
    }
    static func manager() -> (UsageManager, URLSession, UserDefaults, String, URL) {
        let suite = "LimitFuel.ClaudeAcceptance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "chrome_detection_enabled")
        defaults.set(false, forKey: "usage_notifications_enabled")
        let temp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeUsageProtocol.self]
        let session = URLSession(configuration: config)
        let reader = ChromeCookieReader(root: temp, passwordProvider: { _ in fatalError("Unexpected Keychain access") })
        return (UsageManager(statusItem: nil, defaults: defaults, chromeReader: reader, apiSession: session), session, defaults, suite, temp)
    }
    static func withManager(_ work: (UsageManager) -> Void) {
        let (manager, session, defaults, suite, temp) = manager()
        work(manager)
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temp)
    }
    static func hasOption(_ manager: UsageManager, _ id: String) -> Bool {
        manager.menuBarOptions.contains { $0.id == id }
    }
    static func checkOptional(_ manager: UsageManager, weekly: Bool, sonnet: Bool, fable: Bool, label: String) {
        check(manager.hasWeeklyUsage == weekly, "\(label): weekly availability")
        check(manager.hasWeeklySonnet == sonnet, "\(label): Sonnet availability")
        check(manager.hasWeeklyFable == fable, "\(label): Fable availability")
        check(hasOption(manager, "claude:seven_day") == weekly, "\(label): weekly menu availability")
        check(hasOption(manager, "claude:seven_day_sonnet") == sonnet, "\(label): Sonnet menu availability")
        if !weekly { check(manager.weeklyResetsAt == nil, "\(label): no stale weekly reset") }
        if !sonnet { check(manager.weeklySonnetResetsAt == nil, "\(label): no stale Sonnet reset") }
        if !fable { check(manager.weeklyFableResetsAt == nil, "\(label): no stale Fable reset") }
    }
    static func request(_ manager: UsageManager, status: Int, body: [String: Any], error: URLError? = nil) {
        FakeUsageProtocol.next = .init(status: status, body: data(body), error: error)
        let before = FakeUsageProtocol.requests
        manager.fetchUsageWithOrgId("acceptance-org")
        let deadline = Date().addingTimeInterval(2)
        while FakeUsageProtocol.requests == before && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        check(FakeUsageProtocol.requests == before + 1, "exactly one injected usage request")
        // URLProtocol completion is delivered on main; bounded drain includes delivery.
        RunLoop.main.run(until: Date().addingTimeInterval(0.10))
    }
    static func connectionPermutations() {
        withManager { manager in
            for fetched in [false, true] {
                for detecting in [false, true] {
                    for attention in [false, true] {
                        for message in [nil, "Chrome access denied"] as [String?] {
                            cases += 1
                            manager.hasFetchedData = fetched
                            manager.isDetectingChrome = detecting
                            manager.chromeNeedsAttention = attention
                            manager.chromeMessage = message
                            check(manager.showsClaudeConnectionControls == !fetched,
                                  "C1/C2 fetched=\(fetched) detecting=\(detecting) attention=\(attention) message=\(message != nil)")
                        }
                    }
                }
            }
        }
    }
    static func optionalSequences() {
        withManager { manager in
            cases += 1
            manager.parseUsageData(data(present()))
            checkOptional(manager, weekly: true, sonnet: true, fable: true, label: "present")
            check(manager.weeklyUsage == 42 && manager.weeklySonnetUsage == 43 && manager.weeklyFableUsage == 44, "present numeric values")
            check(manager.weeklyResetsAt == expectedReset && manager.weeklySonnetResetsAt == expectedReset && manager.weeklyFableResetsAt == expectedReset, "present resets")
            manager.parseUsageData(data(base()))
            checkOptional(manager, weekly: false, sonnet: false, fable: false, label: "present to missing")
            var zero = base()
            zero["seven_day"] = ["utilization": 0]
            zero["seven_day_sonnet"] = ["utilization": 0]
            zero["limits"] = [["percent": 0, "scope": ["model": ["display_name": "Fable"]]]]
            manager.parseUsageData(data(zero))
            checkOptional(manager, weekly: true, sonnet: true, fable: true, label: "missing to zero")
            check(manager.weeklyUsage == 0 && manager.weeklySonnetUsage == 0 && manager.weeklyFableUsage == 0, "zero replaces old values")
            check(manager.weeklyResetsAt == nil && manager.weeklySonnetResetsAt == nil && manager.weeklyFableResetsAt == nil, "zero without resets removes old dates")
            manager.clearSessionCookie()
            checkOptional(manager, weekly: false, sonnet: false, fable: false, label: "clear cookie")
            check(manager.showsClaudeConnectionControls, "clear cookie exposes controls")
        }
    }
    static func optionalBreadth() {
        // xorshift64 fixed seed. 256 cases, three independently selected shapes.
        var seed: UInt64 = 0xCA11_AB1E_2026_1011
        func next() -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % 12)
        }
        func fixture(_ variant: Int, key: String) -> (Any?, Bool, Int?) {
            switch variant {
            case 0: return (nil, false, nil)
            case 1: return (NSNull(), false, nil)
            case 2: return ([String: Any](), false, nil)
            case 3: return ([key: NSNull(), "resets_at": reset], false, nil)
            case 4: return ([key: "25", "resets_at": reset], false, nil)
            case 5: return ([key: true, "resets_at": reset], false, nil)
            case 6: return ([key: false, "resets_at": reset], false, nil)
            case 7: return ([key: -1, "resets_at": reset], false, nil)
            case 8: return ([key: 101, "resets_at": reset], false, nil)
            case 9: return ([key: 0], true, 0)
            case 10: return ([key: 100, "resets_at": reset], true, 100)
            default: return ([key: 37, "resets_at": reset], true, 37)
            }
        }
        withManager { manager in
            for index in 0..<256 {
                cases += 1
                manager.parseUsageData(data(present()))
                let w = fixture(next(), key: "utilization")
                let s = fixture(next(), key: "utilization")
                let f = fixture(next(), key: "percent")
                var object = base()
                if let value = w.0 { object["seven_day"] = value }
                if let value = s.0 { object["seven_day_sonnet"] = value }
                if var value = f.0 as? [String: Any] {
                    value["scope"] = ["model": ["display_name": "Fable"]]
                    object["limits"] = [value]
                } else if let value = f.0 { object["limits"] = value }
                manager.parseUsageData(data(object))
                checkOptional(manager, weekly: w.1, sonnet: s.1, fable: f.1, label: "seeded \(index)")
                if let value = w.2 { check(manager.weeklyUsage == value, "seeded \(index): weekly numeric value") }
                if let value = s.2 { check(manager.weeklySonnetUsage == value, "seeded \(index): Sonnet numeric value") }
                if let value = f.2 { check(manager.weeklyFableUsage == value, "seeded \(index): Fable numeric value") }
            }
        }
    }
    static func httpRecovery() {
        for status in [401, 403, 500, -1] {
            withManager { manager in
                cases += 1
                request(manager, status: 200, body: present())
                check(manager.hasFetchedData, "HTTP initial success marks fetched")
                check(!manager.showsClaudeConnectionControls, "HTTP initial success hides controls")
                request(manager, status: status == -1 ? 200 : status, body: ["error": "fixture"], error: status == -1 ? URLError(.timedOut) : nil)
                if status == 401 || status == 403 {
                    check(manager.showsClaudeConnectionControls, "HTTP \(status) exposes recovery after success")
                } else {
                    check(!manager.showsClaudeConnectionControls, "HTTP \(status) preserves connection through non-auth failure")
                }
                request(manager, status: 200, body: present())
                check(manager.hasFetchedData, "HTTP \(status) recovery marks fetched")
                check(!manager.showsClaudeConnectionControls, "HTTP \(status) recovery hides controls")
                check(manager.errorMessage == nil, "HTTP \(status) recovery clears usage error")
            }
        }
    }
    static func main() {
        connectionPermutations()
        optionalSequences()
        optionalBreadth()
        httpRecovery()
        print("Claude acceptance: \(cases) cases; \(assertions) assertions; \(failures) failures; seed=0xCA11AB1E20261011; optional breadth=256")
        if failures > 0 { exit(1) }
    }
}
