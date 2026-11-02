import Foundation

// Spec-only acceptance for the Codex status contract and failure rows 1-9 in
// docs/plans/2026-11-02-codex-status-and-add-menu.md. All fixtures are synthetic.
fileprivate func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("Acceptance failure: \(message)") }
}

@main
struct CodexStatusTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static let sixHours: TimeInterval = 6 * 60 * 60

    static func timestamp(_ age: TimeInterval, fractional: Bool = false) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(-age))
    }

    static func component(_ id: String = "codex", name: String = "CLI", group: String? = "Codex", status: String = "partial_outage") -> [String: Any] {
        var result: [String: Any] = ["id": id, "name": name, "current_status": status]
        if let group { result["group_name"] = group }
        return result
    }

    static func entry(_ id: String = "incident", components: [[String: Any]], age: TimeInterval = 0, fractional: Bool = false) -> [String: Any] {
        ["id": id, "name": "Synthetic \(id)", "status": "investigating", "url": "https://status.openai.com/incidents/synthetic", "last_update_at": timestamp(age, fractional: fractional), "last_update_message": "Synthetic update", "affected_components": components]
    }

    static func data(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    static func decode(_ incidents: [[String: Any]], maintenances: [[String: Any]]? = nil) -> StatusSummary {
        var root: [String: Any] = ["ongoing_incidents": incidents]
        if let maintenances { root["in_progress_maintenances"] = maintenances }
        guard let summary = StatusManager.decodeCodex(data(root)) else { fatalError("Synthetic incident.io fixture must decode") }
        return summary
    }

    static func sourceAndInvalidInput() {
        let source = StatusSource.codex
        check(source.name == "Codex", "source name")
        check(source.endpoint.absoluteString == "https://status.openai.com/api/v1/summary", "source endpoint")
        check(source.pageURL.host == "status.openai.com", "source page host")
        check(source.keyPrefix == "codex_" && source.tracksAllComponents, "source persistence and tracking")
        for invalid in [data([]), data(NSNull()), data(7), data(["other": []]), data(["ongoing_incidents": "bad"]), Data("<html>error</html>".utf8)] {
            check(StatusManager.decodeCodex(invalid) == nil, "invalid root rejected")
            check(source.decode(invalid) == nil, "source decoder rejects invalid root")
        }
        check(source.decode(data(["ongoing_incidents": []])) != nil, "missing maintenance is empty")
        check(StatusSource.claude.name == "Claude" && StatusSource.claude.keyPrefix == "" && !StatusSource.claude.tracksAllComponents, "Claude source remains legacy")
    }

    static func filteringAndEntries() {
        let grouped = component("group", group: "cOdEx")
        let desktop = component("desktop", name: "Codex in ChatGPT Desktop", group: "ChatGPT")
        let other = component("other", name: "ChatGPT", group: "ChatGPT")
        let lowercase = component("lower", name: "codex cli", group: nil)
        let uppercase = component("upper", name: "CODEX API", group: "Other")
        let middle = component("middle", name: "Desktop extension for coDEX", group: nil)
        let adjacent = component("adjacent", name: "Unrelated", group: "Codex adjacent")
        let onlyOther = decode([entry("other-only", components: [other])], maintenances: [entry("other-maintenance", components: [other])])
        check(onlyOther.incidents.isEmpty && onlyOther.components.isEmpty && onlyOther.indicator == "none" && onlyOther.description == "All systems operational", "other products alone remain operational")
        let names = decode([entry("names", components: [lowercase, uppercase, middle, adjacent])])
        check(Set(names.components.map(\.id)) == Set(["lower", "upper", "middle"]), "name matching is case insensitive with absent or different group")
        var missingID = entry("bad-id", components: [component("bad-id-component")]); missingID.removeValue(forKey: "id")
        var missingName = entry("bad-name", components: [component("bad-name-component")]); missingName.removeValue(forKey: "name")
        var missingStatus = entry("bad-status", components: [component("bad-status-component")]); missingStatus.removeValue(forKey: "status")
        let result = decode([entry("mixed", components: [grouped, desktop, other]), entry("other", components: [other]), missingID, missingName, missingStatus], maintenances: [entry("maintenance", components: [desktop])])
        check(Set(result.incidents.map(\.id)) == Set(["mixed", "maintenance"]), "filter other products and malformed entries")
        let mixed = result.incidents.first { $0.id == "mixed" }!
        check(mixed.name == "Synthetic mixed" && mixed.status == "investigating" && mixed.latestUpdate == "Synthetic update", "incident fields preserved")
        check(result.components.first { $0.id == "group" }?.name == "CLI", "component name preserved")
        check(Set(mixed.componentIds) == Set(["group", "desktop"]), "mixed incident only exposes Codex IDs")
        check(Set(result.components.map(\.id)) == Set(["group", "desktop"]), "other product component excluded")
        check(result.incidents.first { $0.id == "maintenance" }?.status == "maintenance", "maintenance status normalized")
        var missingMaintenanceID = entry("maintenance-bad", components: [grouped]); missingMaintenanceID.removeValue(forKey: "id")
        var missingMaintenanceName = entry("maintenance-bad", components: [grouped]); missingMaintenanceName.removeValue(forKey: "name")
        check(decode([], maintenances: [missingMaintenanceID, missingMaintenanceName]).incidents.isEmpty, "invalid maintenance entries skipped")
        let maintenance = decode([], maintenances: [entry("planned", components: [component(status: "under_maintenance")])])
        check(maintenance.indicator == "minor" && maintenance.description == "Under maintenance", "maintenance-only severity")
        check(maintenance.incidents.first?.id == "planned" && maintenance.incidents.first?.name == "Synthetic planned" && maintenance.incidents.first?.latestUpdate == "Synthetic update" && maintenance.incidents.first?.status == "maintenance", "maintenance fields preserved")
        var noMessage = entry("dates", components: [grouped], age: 60.25, fractional: true); noMessage.removeValue(forKey: "last_update_message")
        let dates = decode([noMessage, entry("plain", components: [desktop], age: 120)])
        check(dates.incidents.first { $0.id == "dates" }?.latestUpdate == "", "missing message defaults empty")
        check(dates.incidents.first { $0.id == "dates" }?.updatedAt == now.addingTimeInterval(-60.25), "fractional timestamp")
        check(dates.components.first { $0.id == "group" }?.updatedAt == now.addingTimeInterval(-60.25), "fractional component timestamp")
        check(dates.incidents.first { $0.id == "plain" }?.updatedAt == now.addingTimeInterval(-120), "ordinary timestamp")
    }

    static func severityAndDeduplication() {
        let cases = [("operational", "operational", "none", "All systems operational"), ("degraded_performance", "degraded_performance", "minor", "Degraded performance"), ("under_maintenance", "under_maintenance", "minor", "Under maintenance"), ("partial_outage", "partial_outage", "major", "Partial outage"), ("full_outage", "major_outage", "critical", "Major outage")]
        for (input, status, indicator, description) in cases {
            let result = decode([entry(components: [component(status: input)])])
            check(result.components.first?.status == status, "mapped status \(input)")
            check(result.indicator == indicator && result.description == description, "indicator and description \(input)")
        }
        let unknown = entry("unknown", components: [component(status: "future_status")])
        let unknownOnly = decode([unknown])
        check(unknownOnly.indicator == "none" && unknownOnly.description == "All systems operational", "unknown severity is operational")
        let known = entry("known", components: [component(status: "partial_outage")])
        for entries in [[unknown, known], [known, unknown]] {
            let result = decode(entries)
            check(result.indicator == "major" && result.components.first?.status == "partial_outage", "unknown severity cannot outrank known outage")
        }
        let oldWorst = entry("old", components: [component(status: "full_outage")], age: 600)
        let newMilder = entry("new", components: [component(status: "degraded_performance")], age: 60)
        for entries in [[oldWorst, newMilder], [newMilder, oldWorst]] {
            let result = decode(entries)
            check(result.components.count == 1, "component deduplicated")
            check(result.components[0].status == "major_outage", "worst status independent of order")
            check(result.components[0].updatedAt == now.addingTimeInterval(-60), "latest timestamp independent of severity and order")
        }
    }

    static func severityAcrossComponents() {
        // Exhaustive deterministic pair matrix; no random seed is required.
        let cases: [(String, Int, String)] = [
            ("operational", 0, "All systems operational"),
            ("future_status", 0, "All systems operational"),
            ("degraded_performance", 1, "Degraded performance"),
            ("under_maintenance", 1, "Under maintenance"),
            ("partial_outage", 2, "Partial outage"),
            ("full_outage", 3, "Major outage")
        ]
        let indicators = ["none", "minor", "major", "critical"]
        for left in cases {
            for right in cases {
                let first = entry("first", components: [component("first-component", status: left.0)])
                let second = entry("second", components: [component("second-component", status: right.0)])
                for entries in [[first, second], [second, first]] {
                    let result = decode(entries)
                    let worst = max(left.1, right.1)
                    check(result.components.count == 2 && result.indicator == indicators[worst], "global worst severity for \(left.0), \(right.0)")
                    // Equal degraded/maintenance severity has no specified description winner.
                    let ambiguousTie = left.1 == 1 && right.1 == 1 && left.0 != right.0
                    if !ambiguousTie {
                        let expected = left.1 >= right.1 ? left.2 : right.2
                        check(result.description == expected, "global worst description for \(left.0), \(right.0)")
                    }
                }
            }
        }
    }

    static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "LimitFuel.Acceptance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    static func trackingAndExpiry() {
        let fresh = decode([entry(components: [component()], age: 0)])
        let healthy = decode([])
        withDefaults { defaults in
            defaults.set(["claude-only"], forKey: "tracked_component_ids")
            defaults.set(true, forKey: "status_notifications_enabled")
            var sent = 0
            let manager = StatusManager(source: .codex, defaults: defaults, notify: { _, _ in sent += 1 })
            manager.apply(healthy, now: now)
            manager.apply(fresh, now: now)
            check(sent == 1, "fresh outage notifies")
            check(manager.isTracked(fresh.components[0].id), "Codex tracks every component")
            manager.toggleComponent(fresh.components[0].id)
            check(manager.isTracked(fresh.components[0].id), "Codex toggle is no-op")
            check(defaults.stringArray(forKey: "tracked_component_ids") == ["claude-only"], "Claude tracking remains intact")
            check(manager.visibleIncidents(now: now).count == 1 && manager.visibleAffectedComponents(now: now).count == 1, "Codex ignores Claude tracked IDs")
            check(manager.visibleIncidents(now: now.addingTimeInterval(sixHours)).count == 1, "six-hour boundary visible")
            check(manager.effectiveIndicator(now: now.addingTimeInterval(sixHours)) != "none", "boundary remains degraded")
            let expired = now.addingTimeInterval(sixHours + 1)
            check(manager.visibleIncidents(now: expired).isEmpty && manager.visibleAffectedComponents(now: expired).isEmpty, "incident and component expire")
            check(manager.effectiveIndicator(now: expired) == "none", "expired effective indicator clears")
            manager.apply(fresh, now: expired)
            manager.apply(fresh, now: expired.addingTimeInterval(1))
            manager.apply(healthy, now: expired.addingTimeInterval(2))
            check(sent == 1, "expiry, repeated stale response and later recovery are silent")
        }
        withDefaults { defaults in
            let manager = StatusManager(source: .codex, defaults: defaults, notify: { _, _ in })
            let unseen = decode([entry(components: [component("unseen")])]).components[0]
            func legacyKeysAbsent() -> Bool {
                defaults.object(forKey: "tracked_component_ids") == nil && defaults.object(forKey: "last_effective_indicator") == nil
            }
            check(legacyKeysAbsent() && manager.isTracked(unseen.id), "initialization leaves legacy keys absent and tracks unseen component")
            manager.apply(fresh, now: now)
            check(legacyKeysAbsent() && manager.isTracked(unseen.id), "apply leaves legacy keys absent")
            manager.toggleComponent(unseen.id)
            check(legacyKeysAbsent() && manager.isTracked(unseen.id), "toggle leaves legacy keys absent and tracks unseen component")
            check(manager.allComponents.count == 1 && !manager.visibleAffectedComponents(now: now).isEmpty, "fresh component present before resolution")
            manager.apply(healthy, now: now)
            check(legacyKeysAbsent(), "empty apply leaves legacy keys absent")
            check(manager.allComponents.isEmpty && manager.visibleAffectedComponents(now: now).isEmpty && manager.visibleIncidents(now: now).isEmpty, "empty response immediately replaces all visibility")
        }
    }

    static func notificationsAndIsolation() {
        let outage = decode([entry(components: [component(status: "partial_outage")])])
        let healthy = decode([])
        withDefaults { defaults in
            defaults.set(true, forKey: "status_notifications_enabled")
            defaults.set("critical", forKey: "last_effective_indicator")
            var messages: [(String, String)] = []
            let manager = StatusManager(source: .codex, defaults: defaults, notify: { messages.append(($0, $1)) })
            manager.apply(healthy, now: now)
            check(messages.isEmpty, "legacy indicator ignored on first Codex fetch")
            check(defaults.string(forKey: "codex_last_effective_indicator") == "none", "Codex indicator stored separately")
            manager.apply(outage, now: now)
            manager.apply(outage, now: now)
            check(messages.count == 1 && messages[0].0 == "Codex status: Partial outage" && messages[0].1 == "Visit status.openai.com for details", "Codex outage notification")
            check(defaults.string(forKey: "codex_last_effective_indicator") == "major", "Codex outage indicator persisted")
            manager.apply(healthy, now: now)
            check(messages.count == 2 && messages[1].0 == "Codex is back online" && messages[1].1 == "All systems operational", "Codex recovery notification")
            check(defaults.string(forKey: "last_effective_indicator") == "critical", "Codex never writes Claude indicator")
        }
        withDefaults { defaults in
            defaults.set(false, forKey: "status_notifications_enabled")
            var count = 0
            let manager = StatusManager(source: .codex, defaults: defaults, notify: { _, _ in count += 1 })
            manager.apply(healthy, now: now); manager.apply(outage, now: now); manager.apply(healthy, now: now)
            check(count == 0, "shared notification switch suppresses transitions")
        }
        withDefaults { defaults in
            defaults.set(true, forKey: "status_notifications_enabled")
            defaults.set(["codex"], forKey: "tracked_component_ids")
            var messages: [(String, String)] = []
            let manager = StatusManager(defaults: defaults, notify: { messages.append(($0, $1)) })
            // Claude retains its component list on an empty response. Supply a real
            // operational component for this control so it tests notification wording.
            let claudeHealthy = StatusSummary(indicator: "none", description: "All systems operational",
                incidents: [], components: [StatusComponent(id: "codex", name: "CLI",
                    status: "operational", updatedAt: now)])
            manager.apply(claudeHealthy, now: now)
            manager.apply(outage, now: now)
            manager.apply(claudeHealthy, now: now)
            check(messages.count == 2 && messages[0].0 == "Claude status: Partial outage" && messages[0].1 == "Visit status.claude.com for details", "Claude outage wording preserved")
            check(messages[1].0 == "Claude is back online" && messages[1].1 == "All systems operational", "Claude recovery wording preserved")
            check(defaults.string(forKey: "last_effective_indicator") == "none" && defaults.object(forKey: "codex_last_effective_indicator") == nil, "Claude retains legacy indicator key")
        }
    }

    static func main() {
        sourceAndInvalidInput()
        filteringAndEntries()
        severityAndDeduplication()
        severityAcrossComponents()
        trackingAndExpiry()
        notificationsAndIsolation()
        print("CodexStatusTests passed")
    }
}
