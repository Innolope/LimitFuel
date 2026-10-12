import Foundation

private final class WeeklyDenyAllProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { fatalError("Unexpected network access in local weekly rule acceptance tests") }
    override func stopLoading() {}
}

@main
@MainActor
struct WeeklyRuleTests {
    static var assertions = 0

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError("Weekly rule acceptance failure: \(message)") }
    }

    static func fixture(session: String, weekly: String?) -> Data {
        let optional = weekly.map { ",\"seven_day\":\($0)" } ?? ""
        return Data("{\"five_hour\":{\"utilization\":\(session)}\(optional)}".utf8)
    }

    static func main() throws {
        let base = ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? NSTemporaryDirectory()
        let scratch = URL(fileURLWithPath: base).appendingPathComponent("weekly-spec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "LimitFuel.WeeklySpec.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "chrome_detection_enabled")
        defaults.set(false, forKey: "usage_notifications_enabled")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WeeklyDenyAllProtocol.self]
        let apiSession = URLSession(configuration: config)
        defer { apiSession.invalidateAndCancel() }
        let reader = ChromeCookieReader(root: scratch, passwordProvider: { _ in fatalError("Unexpected Keychain access") })
        let manager = UsageManager(statusItem: nil, defaults: defaults, chromeReader: reader, apiSession: apiSession)

        func verify(session: String, weekly: String?, available: Bool, shown: Bool, percent: Double?, label: String) {
            manager.parseUsageData(fixture(session: session, weekly: weekly))
            check(manager.hasFetchedData, "\(label): valid session marks data fetched")
            check(manager.hasWeeklyUsage == available, "\(label): raw weekly availability")
            check(manager.showsClaudeWeeklyUsage == shown, "\(label): dashboard visibility")
            let option = manager.menuBarOptions.first { $0.id == "claude:seven_day" }
            check((option != nil) == available, "\(label): weekly remains selectable exactly when available")
            if let percent {
                check(abs((option?.percent ?? -999) - percent) < 0.00000001, "\(label): menu retains unrounded weekly utilization")
            }
        }

        // Frozen spec matrix: no random input or dependency on implementation rounding.
        let sessions = ["0", "0.000001", "0.01", "0.49", "0.5", "1", "12", "99.99", "100"]
        let weeklies = ["0", "0.000001", "0.01", "0.49", "0.5", "1", "12", "99.99", "100"]
        for session in sessions {
            for weekly in weeklies {
                let value = Double(weekly)!
                verify(session: session, weekly: "{\"utilization\":\(weekly)}", available: true,
                       shown: value > 0 || Double(session)! == 0, percent: value,
                       label: "matrix session=\(session) weekly=\(weekly)")
            }
        }

        let invalidWeeklies: [(String, String?)] = [
            ("missing window", nil), ("null window", "null"),
            ("empty window", "{}"), ("null utilization", "{\"utilization\":null}"),
            ("boolean true", "{\"utilization\":true}"), ("boolean false", "{\"utilization\":false}"),
            ("numeric string", "{\"utilization\":\"0\"}"), ("positive string", "{\"utilization\":\"12\"}"),
            ("array utilization", "{\"utilization\":[]}"), ("object utilization", "{\"utilization\":{}}"),
            ("negative", "{\"utilization\":-0.000001}"), ("over limit", "{\"utilization\":100.000001}")
        ]
        for session in ["0", "12"] {
            for (name, weekly) in invalidWeeklies {
                // Prime shown state before every invalid input to detect stale visibility/availability.
                verify(session: "0", weekly: "{\"utilization\":12}", available: true, shown: true, percent: 12, label: "prime \(name)")
                verify(session: session, weekly: weekly, available: false, shown: false, percent: nil, label: "invalid \(name), session=\(session)")
            }
        }

        for iteration in 0..<3 {
            verify(session: "0", weekly: "{\"utilization\":0}", available: true, shown: true, percent: 0, label: "transition \(iteration) zero/zero")
            verify(session: "12", weekly: "{\"utilization\":0}", available: true, shown: false, percent: 0, label: "transition \(iteration) positive/zero")
            verify(session: "12", weekly: "{\"utilization\":0}", available: true, shown: false, percent: 0, label: "transition \(iteration) replay")
            verify(session: "12", weekly: "{\"utilization\":0.01}", available: true, shown: true, percent: 0.01, label: "transition \(iteration) positive decimal")
            verify(session: "0", weekly: nil, available: false, shown: false, percent: nil, label: "transition \(iteration) missing")
        }
        verify(session: "0", weekly: "{\"utilization\":12,\"resets_at\":\"2030-01-02T03:04:05Z\"}", available: true, shown: true, percent: 12, label: "pre-reset")
        manager.clearSessionCookie()
        check(!manager.showsClaudeWeeklyUsage, "reset clears weekly dashboard visibility")
        verify(session: "12", weekly: "{\"utilization\":0}", available: true, shown: false, percent: 0, label: "post-reset positive/zero")
        verify(session: "0", weekly: "{\"utilization\":0}", available: true, shown: true, percent: 0, label: "post-reset zero/zero")
        print("WeeklyRuleTests passed: \(assertions) assertions; 81 valid matrix cases, 24 invalid cases, 3 transition cycles; deterministic exhaustive matrix, no random seed")
    }
}
