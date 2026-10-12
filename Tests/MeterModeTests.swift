import Foundation

fileprivate func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("Meter mode acceptance failed: \(message)") }
}

@main
struct MeterModeTests {
    static func option(_ id: String, provider: MenuBarProvider, percent: Double = 21,
                       minutes: Int? = 300) -> MenuBarWindowOption {
        MenuBarWindowOption(id: id, provider: provider, label: id, percent: percent,
                            durationMinutes: minutes, isPreferredBucket: false)
    }

    static func displayTable() {
        // Fractions preserve clamped raw precision; only percentage text rounds.
        let rows: [(raw: Double, used: Int, remaining: Int, usedFraction: Double, remainingFraction: Double)] = [
            (0, 0, 100, 0, 1),
            (4.4, 4, 96, 0.044, 0.956),
            (4.5, 5, 96, 0.045, 0.955),
            (4.6, 5, 95, 0.046, 0.954),
            (21, 21, 79, 0.21, 0.79),
            (99.5, 100, 1, 0.995, 0.005),
            (100, 100, 0, 1, 0)
        ]
        for row in rows {
            let expectations: [(MenuBarPercentageMode, Int, Double, String)] = [
                (.used, row.used, row.usedFraction, "\(row.used) percent used"),
                (.remaining, row.remaining, row.remainingFraction, "\(row.remaining) percent remaining")
            ]
            for (mode, percent, fraction, accessibility) in expectations {
                check(mode.displayedPercent(used: row.raw) == percent, "\(mode) rounds \(row.raw)")
                check(abs(mode.displayedFraction(used: row.raw) - fraction) < 1e-12,
                      "\(mode) fraction retains precision for \(row.raw)")
                check(mode.accessibilityValue(used: row.raw) == accessibility,
                      "\(mode) accessibility agrees with displayed text for \(row.raw)")
            }
        }
    }

    static func finiteClampAndRejection() {
        let rows: [(Double, Int, Int)] = [(-100, 0, 100), (-0.1, 0, 100), (100.1, 100, 0), (200, 100, 0)]
        for (raw, used, remaining) in rows {
            for (mode, percent) in [(MenuBarPercentageMode.used, used), (.remaining, remaining)] {
                check(mode.displayedPercent(used: raw) == percent, "finite out-of-range meter clamps \(raw)")
                check(mode.displayedFraction(used: raw) == Double(percent) / 100,
                      "out-of-range fraction clamps at endpoint")
                check(mode.accessibilityValue(used: raw) == "\(percent) percent \(mode.rawValue)",
                      "clamped accessibility uses the endpoint")
                let entries = MenuBarStatus.selectedEntries(
                    claude: option("invalid-claude", provider: .claude, percent: raw),
                    codex: option("invalid-codex", provider: .codex, percent: raw), percentageMode: mode)
                check(entries.isEmpty, "menu bar rejects out-of-range raw data before mode transformation")
            }
        }
    }

    static func selectedEntryAgreement() {
        // Deterministic decimal workload: 1001 inputs x 2 modes x 2 providers.
        for step in 0...1000 {
            let raw = Double(step) / 10
            for mode in [MenuBarPercentageMode.used, .remaining] {
                let entries = MenuBarStatus.selectedEntries(
                    claude: option("claude", provider: .claude, percent: raw),
                    codex: option("codex", provider: .codex, percent: raw), percentageMode: mode)
                check(entries.count == 2, "valid endpoints and decimal values keep both providers")
                check(entries.allSatisfy { $0.percent == mode.displayedPercent(used: raw) },
                      "both menu entries agree with meter helper at \(raw) in \(mode)")
            }
        }
    }

    static func pickerFallbackPersistence(_ defaults: UserDefaults) {
        let preferences = MenuBarPreferences(defaults: defaults)
        for provider in [MenuBarProvider.claude, .codex] {
            let weekly = option("\(provider)-weekly", provider: provider, minutes: 10080)
            let session = option("\(provider)-session", provider: provider)
            let options = [weekly, session]
            let picker = MenuBarSelection.pickerOptions(provider: provider, options: options)
            check(picker.map { $0.id } == options.map { $0.id }, "picker lists real windows in order")
            check(!picker.contains { $0.id == MenuBarSelection.automaticID }, "picker has no Automatic row")
            check(MenuBarSelection.pickerSelectionID(provider: provider, options: options, selectionID: nil) == session.id,
                  "unset selection displays the session-first default")
            check(MenuBarSelection.pickerSelectionID(provider: provider, options: options,
                  selectionID: preferences.selectionID(for: provider)) == session.id,
                  "persisted default displays the actual session window")
            preferences.select(weekly.id, for: provider)
            check(MenuBarSelection.pickerSelectionID(provider: provider, options: options,
                  selectionID: preferences.selectionID(for: provider)) == weekly.id,
                  "picker displays the explicit saved window")
            check(MenuBarSelection.pickerSelectionID(provider: provider, options: [session],
                  selectionID: preferences.selectionID(for: provider)) == session.id,
                  "temporarily missing saved window falls back")
            check(preferences.selectionID(for: provider) == weekly.id, "fallback never overwrites the saved choice")
            check(MenuBarPreferences(defaults: defaults).selectionID(for: provider) == weekly.id,
                  "fallback preserves the durable saved choice")
            check(MenuBarSelection.pickerSelectionID(provider: provider, options: options,
                  selectionID: preferences.selectionID(for: provider)) == weekly.id,
                  "returning saved window recovers its selection")
            check(MenuBarSelection.pickerOptions(provider: provider, options: []).isEmpty, "no windows means no picker rows")
            check(MenuBarSelection.pickerSelectionID(provider: provider, options: [], selectionID: weekly.id) == nil,
                  "no windows means no picker value even with a saved ID")
            check(MenuBarSelection.pickerSelectionID(provider: provider, options: [], selectionID: nil) == nil,
                  "no windows and no saved ID has no picker value")
        }
    }

    static func window(_ minutes: Int?) -> CodexWindow {
        CodexWindow(usedPercent: 21, windowDurationMins: minutes, resetsAt: nil)
    }

    static func labels(_ buckets: [CodexBucket]) -> [MenuBarWindowOption] {
        CodexSnapshot(accountLabel: "offline fixture", buckets: buckets).menuBarOptions
    }

    static func codexLabelAndIDTable() {
        // SHA256("codex"), independently calculated with Python hashlib.
        let digest = "57de4cf40144bdf7d00010f2f5557a7d642c2b9705309bfade167dd313e2ca93"
        let rows: [(Int?, String)] = [
            (10080, "Weekly · 7d"), (300, "Session · 5h"), (120, "Primary · 2h"),
            (1440, "Primary · 1d"), (45, "Primary · 45m"), (nil, "Primary")
        ]
        for (minutes, expected) in rows {
            let options = labels([CodexBucket(id: "codex", name: "codex", primary: window(minutes), secondary: nil)])
            check(options.count == 1, "single Codex window supplies exactly one option")
            check(options.first?.label == expected, "single codex label is \(expected) without a bucket prefix")
            check(options.first?.id == "codex:\(digest):primary", "primary ID retains the bucket digest and role")
        }
        let secondary = labels([CodexBucket(id: "codex", name: "codex", primary: nil, secondary: window(1440))])
        check(secondary.first?.label == "Secondary · 1d", "secondary duration uses its role")
        check(secondary.first?.id == "codex:\(digest):secondary", "secondary ID retains its role")
        let unknown = labels([CodexBucket(id: "codex", name: "codex", primary: nil, secondary: window(nil))])
        check(unknown.first?.label == "Secondary", "unknown secondary duration omits separator and duration")
        let renamed = labels([CodexBucket(id: "codex", name: "Research", primary: window(300), secondary: nil)])
        check(renamed.first?.label == "Research · Session · 5h", "non-codex name keeps its bucket prefix")
        check(renamed.first?.id == "codex:\(digest):primary", "display rename leaves saved ID unchanged")
        let several = labels([
            CodexBucket(id: "codex", name: "codex", primary: window(10080), secondary: nil),
            CodexBucket(id: "other", name: "Other", primary: window(120), secondary: nil)
        ])
        check(several.map { $0.label } == ["codex · Weekly · 7d", "Other · Primary · 2h"],
              "multiple buckets preserve every bucket prefix")
        check(several.map { $0.id } == ["codex:\(digest):primary",
              "codex:d9298a10d1b0735837dc4bd85dac641b0f3cef27a47e5d53a54f2f3f5b2fcffa:primary"],
              "adding another bucket leaves established opaque IDs unchanged")
        let duplicates = labels([
            CodexBucket(id: "alpha", name: "Shared", primary: window(300), secondary: nil),
            CodexBucket(id: "beta", name: "Shared", primary: nil, secondary: window(1440))
        ])
        check(duplicates.map { $0.label } == ["Shared (alpha) · Session · 5h", "Shared (beta) · Secondary · 1d"],
              "duplicate names retain the identifying ID suffix")
        check(duplicates.map { $0.id } == [
            "codex:8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8:primary",
            "codex:f44e64e75f3948e9f73f8dfa94721c4ce8cbb4f265c4790c702b2d41cfbf2753:secondary"
        ], "duplicate display labels preserve independent stable bucket and role IDs")
    }

    static func main() throws {
        let suite = "LimitFuel.Acceptance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        displayTable()
        finiteClampAndRejection()
        selectedEntryAgreement()
        pickerFallbackPersistence(defaults)
        codexLabelAndIDTable()
        print("MeterModeTests passed")
    }
}
