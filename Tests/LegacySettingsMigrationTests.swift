import Foundation

fileprivate func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("Acceptance failure: \(message)") }
}

@main
struct LegacySettingsMigrationTests {
    static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "LimitFuel.Acceptance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    static func copiesAbsentKeysWithoutOverwriting() {
        withDefaults { defaults in
            defaults.set("current-window", forKey: "menubar_codex_window")
            defaults.set(false, forKey: "diagnostics_enabled")
            let legacy: [String: Any] = [
                "menubar_codex_window": "legacy-window",
                "diagnostics_enabled": true,
                "menubar_claude_window": "claude:seven_day",
                "menubar_percentage_mode": "used",
                "session_cookie": "synthetic-cookie",
                "NSStatusItem Preferred Position LimitFuel": 123,
                "open_at_login": true,
                "fraction": 0.25,
                "timestamp": Date(timeIntervalSince1970: 1_700_000_000),
                "bytes": Data([0, 1, 255]),
                "array": ["a", "b"],
                "dictionary": ["nested": ["enabled": true, "count": 2]]
            ]
            let original = NSDictionary(dictionary: legacy)
            check(LegacySettings.migrate(into: defaults, legacy: legacy), "true legacy login setting requests registration")
            check(defaults.string(forKey: "menubar_codex_window") == "current-window", "existing window is never overwritten")
            check(defaults.object(forKey: "diagnostics_enabled") as? Bool == false, "existing false is never overwritten")
            for (key, value) in legacy where key != "menubar_codex_window" && key != "diagnostics_enabled" {
                guard let copied = defaults.object(forKey: key) else { fatalError("Missing migrated key: \(key)") }
                check(NSDictionary(dictionary: [key: copied]).isEqual(to: [key: value]), "plist value survives for \(key)")
            }
            check(defaults.bool(forKey: "legacy_settings_migrated"), "migration sets durable marker")
            check(NSDictionary(dictionary: legacy).isEqual(original), "migration does not mutate the supplied legacy dictionary")
        }
    }

    static func repeatedMigrationCopiesNothing() {
        withDefaults { defaults in
            let legacy: [String: Any] = ["open_at_login": true, "saved": "first"]
            check(LegacySettings.migrate(into: defaults, legacy: legacy), "initial true login migration")
            defaults.removeObject(forKey: "saved")
            let changed: [String: Any] = ["open_at_login": true, "saved": "changed", "new_key": Data([7])]
            check(!LegacySettings.migrate(into: defaults, legacy: changed), "second migration never registers again")
            check(defaults.object(forKey: "saved") == nil, "second migration does not restore a removed key")
            check(defaults.object(forKey: "new_key") == nil, "second migration does not add new legacy keys")
            check(defaults.bool(forKey: "legacy_settings_migrated"), "marker survives repeated migration")
        }
    }

    static func emptyOrUnreadableLegacyIsMarkedOnce() {
        for legacy in [nil, [:]] as [[String: Any]?] {
            withDefaults { defaults in
                check(!LegacySettings.migrate(into: defaults, legacy: legacy), "nil/empty legacy does not request login registration")
                check(defaults.bool(forKey: "legacy_settings_migrated"), "nil/empty legacy still sets marker")
                check(!LegacySettings.migrate(into: defaults, legacy: ["late": "value", "open_at_login": true]), "late legacy discovery does not repeat migration")
                check(defaults.object(forKey: "late") == nil, "empty first migration is durable")
            }
        }
    }

    static func loginRegistrationRequiresBooleanTrue() {
        let cases: [(String, [String: Any], Bool)] = [
            ("true", ["open_at_login": true], true),
            ("false", ["open_at_login": false], false),
            ("missing", ["other": "value"], false),
            ("string", ["open_at_login": "1"], false)
        ]
        for (label, legacy, expected) in cases {
            withDefaults { defaults in
                let original = NSDictionary(dictionary: legacy)
                check(LegacySettings.migrate(into: defaults, legacy: legacy) == expected, "login registration result: \(label)")
                check(defaults.bool(forKey: "legacy_settings_migrated"), "marker regardless of login flag: \(label)")
                check(NSDictionary(dictionary: legacy).isEqual(original), "input remains unchanged: \(label)")
            }
        }
    }

    static func main() throws {
        check(LegacySettings.domain == "com.claude.usagebar", "legacy domain contract")
        check(LegacySettings.markerKey == "legacy_settings_migrated", "marker key contract")
        copiesAbsentKeysWithoutOverwriting()
        repeatedMigrationCopiesNothing()
        emptyOrUnreadableLegacyIsMarkedOnce()
        loginRegistrationRequiresBooleanTrue()
        print("LegacySettingsMigrationTests passed")
    }
}
