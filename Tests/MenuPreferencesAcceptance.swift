import Foundation
import Combine

@main
struct MenuPreferencesAcceptance {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { fatalError("Acceptance failure: \(message)") }
    }
    static func option(_ id: String, _ provider: MenuBarProvider = .codex, _ percent: Double = 23, _ duration: Int? = 300, _ preferred: Bool = false) -> MenuBarWindowOption {
        MenuBarWindowOption(id: id, provider: provider, label: "Label \(id)", percent: percent, durationMinutes: duration, isPreferredBucket: preferred)
    }
    static func chosen(_ options: [MenuBarWindowOption], _ id: String? = nil, _ provider: MenuBarProvider = .codex) -> String? {
        MenuBarSelection.selectedOption(provider: provider, options: options, selectionID: id)?.id
    }
    static func main() {
        let session = option("session", .codex, 42)
        let weekly = option("weekly", .codex, 0, 10080, true)
        check(chosen([weekly, session]) == "session", "automatic session overrides preferred weekly")
        check(chosen([session, weekly], "weekly") == "weekly", "explicit weekly zero wins")
        check(chosen([session, weekly], "missing") == "session", "missing selection falls back")
        check(chosen([session, weekly], MenuBarSelection.automaticID) == "session", "automatic ID")
        check(chosen([]) == nil, "empty has no percentage")
        check(chosen([option("other", .claude)], "other") == nil, "provider cannot borrow value")
        let bad = [Double.nan, Double.infinity, -Double.infinity, -0.01, 100.01]
        for value in bad { check(chosen([option("bad", .codex, value)], "bad") == nil, "invalid percentage \(value)") }
        for value in [0.0, 100.0] { check(chosen([option("edge", .codex, value)]) == "edge", "valid boundary \(value)") }
        check(chosen([option("unknown", .codex, 1, nil, true), session]) == "session", "unknown duration is not session")
        check(chosen([option("day", .codex, 1, 1440, true), session]) == "session", "day threshold exclusive")
        check(chosen([option("zero-duration", .codex, 1, 0, true), session]) == "session", "nonpositive duration is not session")
        check(chosen([session, option("preferred", .codex, 1, 60, true)]) == "preferred", "preferred session")
        check(chosen([option("first"), option("second")]) == "first", "stable order ties")
        check(chosen([option("long", .codex, 1, 10080), option("unknown", .codex, 2, nil, true)]) == "unknown", "no sessions uses preferred bucket")
        check(chosen([weekly], "session") == "weekly", "missing saved session fallback")
        check(chosen([weekly, session], "session") == "session", "saved selection recovers")
        check(chosen([option("old", .codex, 90)]) == "old", "account A")
        check(chosen([]) == nil, "account reset clears selected percentage")
        check(chosen([option("new", .codex, 2)]) == "new", "account B independent")

        let suite = "LimitFuel.MenuPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = MenuBarPreferences(defaults: defaults)
        check(prefs.selectionID(for: .claude) == MenuBarSelection.automaticID, "Claude default")
        check(prefs.selectionID(for: .codex) == MenuBarSelection.automaticID, "Codex default")
        var changes = 0
        let observer = prefs.objectWillChange.sink { _ in changes += 1 }
        prefs.select("weekly", for: .codex)
        check(changes > 0, "selection emits observable change")
        prefs.select("session", for: .claude)
        check(prefs.selectionID(for: .codex) == "weekly", "provider isolation")
        let reloaded = MenuBarPreferences(defaults: defaults)
        check(reloaded.selectionID(for: .codex) == "weekly", "Codex persistence")
        check(reloaded.selectionID(for: .claude) == "session", "Claude persistence")
        check(defaults.string(forKey: "menubar_codex_window") == "weekly", "documented Codex key")
        check(defaults.string(forKey: "menubar_claude_window") == "session", "documented Claude key")
        prefs.select("temporarily-missing", for: .codex)
        check(chosen([session], prefs.selectionID(for: .codex)) == "session", "fallback display")
        check(prefs.selectionID(for: .codex) == "temporarily-missing", "fallback preserves choice")
        check(chosen([session, option("temporarily-missing")], prefs.selectionID(for: .codex)) == "temporarily-missing", "choice recovery")
        for id in ["", String(repeating: "a", count: 4097), "bad\nvalue", "bad\u{0000}value", "bad\u{007f}value"] {
            prefs.select(id, for: .codex)
            check(prefs.selectionID(for: .codex) == MenuBarSelection.automaticID, "invalid input normalizes")
            defaults.set(id, forKey: "menubar_codex_window")
            check(MenuBarPreferences(defaults: defaults).selectionID(for: .codex) == MenuBarSelection.automaticID, "invalid persisted string")
        }
        for value in [17, true, 3.14, ["session"], ["id": "session"], Data([1, 2])] as [Any] {
            defaults.set(value, forKey: "menubar_codex_window")
            check(MenuBarPreferences(defaults: defaults).selectionID(for: .codex) == MenuBarSelection.automaticID, "invalid stored type")
        }
        for id in ["unknown", "窗口/primary:secondary", String(repeating: "é", count: 2048)] {
            prefs.select(id, for: .codex)
            check(MenuBarPreferences(defaults: defaults).selectionID(for: .codex) == id, "opaque valid ID persists")
        }
        prefs.select(String(repeating: "é", count: 2049), for: .codex)
        check(prefs.selectionID(for: .codex) == MenuBarSelection.automaticID, "UTF8 byte length enforced")
        withExtendedLifetime(observer) {}

        // Deterministic transitions: seed 0x5eed; 2,000 independent option sets.
        var state: UInt64 = 0x5eed
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        for iteration in 0..<2000 {
            var options: [MenuBarWindowOption] = []
            for index in 0..<Int(next() % 12) {
                let provider: MenuBarProvider = next() % 2 == 0 ? .codex : .claude
                let percentages = [0.0, 100, 37, -1, 101, Double.nan]
                let durations: [Int?] = [nil, -1, 0, 1, 300, 1439, 1440, 10080]
                options.append(option("\(iteration):\(index)", provider, percentages[Int(next() % 6)], durations[Int(next() % 8)], next() % 2 == 0))
            }
            let saved = options.isEmpty || next() % 3 == 0 ? "missing" : options[Int(next() % UInt64(options.count))].id
            let valid = options.filter { $0.provider == .codex && $0.percent.isFinite && (0...100).contains($0.percent) }
            let sessions = valid.filter { ($0.durationMinutes ?? 0) > 0 && ($0.durationMinutes ?? 1440) < 1440 }
            let pool = sessions.isEmpty ? valid : sessions
            let expected = valid.first { $0.id == saved } ?? pool.first { $0.isPreferredBucket } ?? pool.first
            check(chosen(options, saved) == expected?.id, "seeded oracle iteration \(iteration)")
            check(chosen([], saved) == nil, "seeded disappearance \(iteration)")
            check(chosen(options, saved) == expected?.id, "seeded recovery \(iteration)")
        }
        func window(_ percent: Double, _ minutes: Int?) -> CodexWindow {
            CodexWindow(usedPercent: percent, windowDurationMins: minutes, resetsAt: nil)
        }
        let buckets = [
            CodexBucket(id: "a:b", name: "Duplicate", primary: window(0, 300), secondary: window(81, 10080)),
            CodexBucket(id: "a", name: "Duplicate", primary: window(19, 60), secondary: window(25, nil)),
            CodexBucket(id: "你好", name: "Duplicate", primary: nil, secondary: window(32, 1440)),
            CodexBucket(id: "codex", name: "Preferred", primary: window(44, 300), secondary: nil)
        ]
        let snapshot = CodexSnapshot(accountLabel: "Account A", buckets: buckets)
        let produced = snapshot.menuBarOptions
        check(produced.count == 6, "Codex absent windows omitted")
        check(produced.map { $0.percent } == [0, 81, 19, 25, 32, 44], "Codex original bucket and primary-secondary order, raw percentages and zero")
        check(produced.map { $0.durationMinutes } == [300, 10080, 60, nil, 1440, 300], "Codex duration metadata")
        check(produced.allSatisfy { $0.provider == .codex }, "Codex provider metadata")
        check(produced.map { $0.isPreferredBucket } == [false, false, false, false, false, true], "Codex preferred bucket identity")
        check(Set(produced.map { $0.id }).count == produced.count, "Codex delimiter Unicode duplicate-label role IDs unique")
        check(snapshot.menuBarPercent == MenuBarSelection.selectedOption(provider: .codex, options: produced, selectionID: nil)?.percent, "Codex legacy percent matches automatic")
        let changed = buckets.reversed().map { bucket in
            CodexBucket(id: bucket.id, name: "Renamed \(bucket.id)", primary: bucket.primary.map { window($0.usedPercent + 1, $0.windowDurationMins) }, secondary: bucket.secondary.map { window($0.usedPercent + 1, $0.windowDurationMins) })
        }
        let changedOptions = CodexSnapshot(accountLabel: "Account B", buckets: changed).menuBarOptions
        // Reverse bucket order preserves primary-secondary order inside each bucket.
        let reorderedOriginalIndices = [5, 4, 2, 3, 0, 1]
        check(changedOptions.map { $0.id } == reorderedOriginalIndices.map { produced[$0].id }, "Codex IDs survive reorder rename percentage and account label changes")
        check(CodexSnapshot(accountLabel: nil, buckets: []).menuBarOptions.isEmpty, "Codex empty snapshot options")
        print("Menu preferences acceptance passed: \(assertions) assertions; seed=0x5eed; cases=2000")
    }
}
