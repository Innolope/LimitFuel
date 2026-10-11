import Foundation
import AppKit
import Combine

@main
struct PercentageModeTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fatalError("Acceptance failed: \(message)") }
    }
    static func option(_ percent: Double, provider: MenuBarProvider = .claude) -> MenuBarWindowOption {
        MenuBarWindowOption(id: "test-window", provider: provider, label: "Test", percent: percent, durationMinutes: 300, isPreferredBucket: true, resetsAt: nil)
    }
    static func main() {
        let name = "PercentageModeAcceptance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "menubar_percentage_mode"
        let preferences = MenuBarPreferences(defaults: defaults)
        check(preferences.percentageMode == .remaining, "missing preference defaults to remaining")
        var callbacks = 0
        preferences.onChange = {
            callbacks += 1
            check(defaults.string(forKey: key) == preferences.percentageMode.rawValue, "callback observes durable updated mode")
        }
        preferences.setPercentageMode(.remaining)
        check(callbacks == 0, "same default mode is idempotent")
        preferences.setPercentageMode(.used)
        check(callbacks == 1, "mode change notifies once")
        check(defaults.string(forKey: key) == "used", "used persists raw string")
        check(MenuBarPreferences(defaults: defaults).percentageMode == .used, "used survives reload")
        preferences.setPercentageMode(.used)
        check(callbacks == 1, "repeated used is idempotent")
        preferences.setPercentageMode(.remaining)
        check(callbacks == 2, "remaining change notifies once")
        check(defaults.string(forKey: key) == "remaining", "remaining persists")
        for malformed: Any in ["bogus", "USED", "", 7, true, ["used"]] {
            defaults.set(malformed, forKey: key)
            check(MenuBarPreferences(defaults: defaults).percentageMode == .remaining, "malformed preference defaults to remaining")
        }
        defaults.removeObject(forKey: key)
        let choices = MenuBarPreferences(defaults: defaults)
        choices.select("weekly", for: .claude)
        choices.select("codex-window", for: .codex)
        choices.setPercentageMode(.used)
        choices.setPercentageMode(.remaining)
        check(choices.selectionID(for: .claude) == "weekly", "claude selection preserved")
        check(choices.selectionID(for: .codex) == "codex-window", "codex selection preserved")

        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        let updated = Date(timeIntervalSince1970: 1_999_999_000)
        let timed = MenuBarWindowOption(id: "weekly", provider: .claude, label: "Opaque", percent: 34, durationMinutes: 10080, isPreferredBucket: false, resetsAt: reset)
        let preserved = MenuBarStatus.selectedEntries(claude: timed, codex: option(33, provider: .codex), claudeIsStale: true, codexIsStale: false, claudeUpdatedAt: updated, codexUpdatedAt: updated, percentageMode: .remaining)
        check(preserved.count == 2, "both providers retained")
        check(preserved[0].provider == .claude && preserved[0].percent == 66, "claude transforms independently")
        check(preserved[1].provider == .codex && preserved[1].percent == 67, "codex transforms independently")
        check(preserved[0].resetsAt == reset && preserved[0].isStale && preserved[0].updatedAt == updated, "reset stale and update metadata preserved")
        check(!preserved[1].isStale && preserved[1].updatedAt == updated, "codex metadata preserved")

        let cases: [(Double, Int, Int)] = [(0,0,100),(100,100,0),(12,12,88),(49.5,50,51),(50.5,51,50),(99.6,100,0),(0.4,0,100),(12.49,12,88),(12.51,13,87)]
        for (raw, used, remaining) in cases {
            verify(raw, mode: .used, expected: used)
            verify(raw, mode: .remaining, expected: remaining)
            verify(raw, mode: nil, expected: used)
        }
        for invalid in [-0.001, 100.001, Double.nan, Double.infinity, -Double.infinity] {
            for mode: MenuBarPercentageMode? in [nil, .used, .remaining] {
                check(MenuBarStatus.selectedEntries(claude: option(invalid), codex: nil, percentageMode: mode).isEmpty, "invalid raw percentage rejected before inversion/rounding")
            }
        }
        var state: UInt64 = 0x50455243454E54
        for _ in 0..<1000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let raw = Double(state % 1_000_001) / 10_000
            verify(raw, mode: .used, expected: Int(raw.rounded(.toNearestOrAwayFromZero)))
            verify(raw, mode: .remaining, expected: Int((100 - raw).rounded(.toNearestOrAwayFromZero)))
        }
        integration()
        print("Percentage mode acceptance passed: \(count) assertions; seeded workload 1000, seed 0x50455243454E54")
    }
    static func integration() {
        _ = NSApplication.shared
        let name = "PercentageModeIntegration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(false, forKey: "chrome_detection_enabled")
        defaults.set(false, forKey: "usage_notifications_enabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DenyNetwork.self]
        let session = URLSession(configuration: config)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer {
            NSStatusBar.system.removeStatusItem(item)
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let app = AppDelegate()
        app.statusItem = item
        app.menuBarPreferences = MenuBarPreferences(defaults: defaults)
        app.usageManager = UsageManager(statusItem: nil, defaults: defaults,
            chromeReader: ChromeCookieReader(root: root, passwordProvider: { _ in fatalError("Unexpected password lookup") }), apiSession: session)
        app.usageManager.parseUsageData(Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8))
        app.codexManager = CodexUsageManager(fetcher: { fatalError("Unexpected Codex fetch") }, notificationsEnabled: { false }, notify: { _, _ in fatalError("Unexpected notification") })
        app.codexManager.snapshot = CodexSnapshot(accountLabel: "offline", buckets: [CodexBucket(id: "codex", name: "Codex", primary: CodexWindow(usedPercent: 33, windowDurationMins: 300, resetsAt: nil), secondary: nil)])
        app.menuBarPreferences.onChange = { app.updateSelectedProviderIcon() }
        let updatedBeforeToggle = app.usageManager.menuBarUpdatedAt
        app.updateSelectedProviderIcon()
        var tooltip = item.button?.toolTip?.lowercased() ?? ""
        check(tooltip.contains("88%") && tooltip.contains("67%") && tooltip.contains("remaining"), "actual delegate defaults both provider icons/tooltips to remaining")
        app.menuBarPreferences.setPercentageMode(.used)
        tooltip = item.button?.toolTip?.lowercased() ?? ""
        check(tooltip.contains("12%") && tooltip.contains("33%") && tooltip.contains("used"), "actual delegate refreshes used mode immediately")
        let weekly = app.usageManager.menuBarOptions.first { $0.durationMinutes == 10080 }
        check(weekly != nil, "fixture exposes weekly selection")
        if let weekly {
            app.menuBarPreferences.select(weekly.id, for: .claude)
            app.menuBarPreferences.setPercentageMode(.remaining)
            tooltip = item.button?.toolTip?.lowercased() ?? ""
            check(tooltip.contains("66%") && tooltip.contains("67%") && tooltip.contains("remaining"), "weekly selection uses remaining and preserves Codex display")
            check(app.menuBarPreferences.selectionID(for: .claude) == weekly.id, "mode retains selected weekly window")
        }
        check(app.usageManager.menuBarUpdatedAt == updatedBeforeToggle, "display changes preserve usage timestamp")
        check(app.usageManager.sessionUtilization == 12, "display changes preserve raw utilization")
        check(DenyNetwork.requests == 0, "display mode changes do not fetch")
    }
    static func verify(_ raw: Double, mode: MenuBarPercentageMode?, expected: Int) {
        let entries = MenuBarStatus.selectedEntries(claude: option(raw), codex: nil, percentageMode: mode)
        check(entries.count == 1, "valid percentage creates entry")
        guard let entry = entries.first else { return }
        check(entry.percent == expected, "display rounds transformed raw value")
        check(entry.percentageMode == mode, "entry carries percentage mode")
        let label = MenuBarStatus.accessibilityLabel(for: entries)
        check(label.contains("\(expected)%"), "accessibility exposes displayed percentage")
        if let mode {
            check(label.lowercased().contains(mode.rawValue), "accessibility explicitly labels percentage meaning")
        }
    }
}

final class DenyNetwork: URLProtocol {
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
