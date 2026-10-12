import Foundation

fileprivate func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("Acceptance failure: \(message)") }
}

@main
struct StatusExpiryTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static let sixHours: TimeInterval = 6 * 60 * 60

    static func timestamp(_ age: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
    }

    // claude.ai supplies the tracked fixture; unrelated service is the negative control.
    static func component(_ name: String = "claude.ai", age: TimeInterval? = nil,
                          status: String = "partial_outage", malformedTime: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["id": "component-\(name)", "name": name, "status": status]
        if let age { result["updated_at"] = timestamp(age) }
        if malformedTime { result["updated_at"] = "unknown timestamp" }
        return result
    }

    static func incident(_ components: [[String: Any]], updates: [TimeInterval] = [],
                         createdAge: TimeInterval = 60, malformedTime: Bool = false) -> [String: Any] {
        var postedUpdates: [[String: Any]] = updates.enumerated().map { index, age in
            ["id": "update-\(index)", "status": "monitoring", "body": "Synthetic update",
             "created_at": timestamp(age)]
        }
        if malformedTime { postedUpdates = [["id": "unknown", "status": "monitoring", "created_at": "unknown timestamp"]] }
        return ["id": "incident-1", "name": "Synthetic tracked outage", "status": "monitoring",
                "created_at": timestamp(createdAge), "updated_at": timestamp(0),
                "incident_updates": postedUpdates, "components": components]
    }

    static func summary(_ components: [[String: Any]], incidents: [[String: Any]] = [],
                        indicator: String = "minor") throws -> StatusSummary {
        // Statuspage summary.json shape; all timestamps and services are synthetic.
        let object: [String: Any] = [
            "page": ["id": "fixture-page", "name": "Claude Status", "url": "https://status.claude.com",
                     "time_zone": "Etc/UTC", "updated_at": timestamp(0)],
            "status": ["indicator": indicator, "description": indicator == "none" ? "All Systems Operational" : "Partial System Outage"],
            "components": components, "incidents": incidents, "scheduled_maintenances": []
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let decoded = StatusManager.decode(data) else { fatalError("Synthetic summary.json must decode") }
        check(decoded.indicator == indicator, "decoder preserves raw status indicator")
        check(decoded.components.count == components.count, "decoder preserves component list")
        check(decoded.incidents.count == incidents.count, "decoder preserves incident list")
        return decoded
    }

    static func withManager(notifications: Bool = false, _ body: (StatusManager, () -> Int) throws -> Void) rethrows {
        let suite = "LimitFuel.Acceptance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(notifications, forKey: "status_notifications_enabled")
        // Explicit tracking: a first fetch otherwise tracks every non-Government component.
        defaults.set(["component-claude.ai"], forKey: "tracked_component_ids")
        defer { defaults.removePersistentDomain(forName: suite) }
        var notificationsSent = 0
        let manager = StatusManager(defaults: defaults, notify: { _, _ in notificationsSent += 1 })
        try body(manager, { notificationsSent })
    }

    static func freshnessBoundaries() {
        check(StatusFreshness.maximumAge == sixHours, "expiry contract is six hours")
        check(!StatusFreshness.isExpired(nil, now: now), "unknown date is not expired")
        check(!StatusFreshness.isExpired(now.addingTimeInterval(-sixHours), now: now), "exactly six hours remains visible")
        check(StatusFreshness.isExpired(now.addingTimeInterval(-sixHours - 1), now: now), "six hours plus one second expires")
    }

    static func latestPostedUpdateControlsIncidentExpiry() throws {
        let affected = component(age: 7 * 3600)
        // The array order and incident's recent created_at/updated_at must not override posted updates.
        let cases: [(String, [TimeInterval], Int, Int)] = [
            ("fresh incident keeps an old component", [7 * 3600, 60], 1, 1),
            ("latest update independent of array order", [60, 7 * 3600], 1, 1),
            ("exact six-hour latest update", [sixHours], 1, 1),
            ("six hours plus one second", [sixHours + 1], 0, 0),
            ("recently created monitoring incident with seven-hour-old update", [7 * 3600], 0, 0),
            ("missing updates remain visible", [], 1, 1)
        ]
        for (label, ages, incidents, components) in cases {
            try withManager { manager, _ in
                manager.apply(try summary([affected], incidents: [incident([affected], updates: ages)]), now: now)
                check(manager.visibleIncidents(now: now).count == incidents, label)
                check(manager.visibleAffectedComponents(now: now).count == components, "\(label): component visibility")
                check((manager.effectiveIndicator(now: now) == "none") == (components == 0), "\(label): effective indicator follows visible data")
            }
        }
        try withManager { manager, _ in
            manager.apply(try summary([affected], incidents: [incident([affected], malformedTime: true)]), now: now)
            check(manager.visibleIncidents(now: now).count == 1, "malformed latest update stays visible as unknown")
            check(manager.visibleAffectedComponents(now: now).count == 1, "unknown incident keeps referenced component")
            check(manager.effectiveIndicator(now: now) != "none", "unknown incident remains degraded")
        }
    }

    static func componentFreshnessAndTracking() throws {
        let cases: [(String, [String: Any], Bool, Int)] = [
            ("unreferenced fresh component", component(age: 60), false, 1),
            ("unreferenced exactly six hours", component(age: sixHours), false, 1),
            ("unreferenced older than six hours", component(age: sixHours + 1), false, 0),
            ("unreferenced unknown time", component(), false, 1),
            ("unreferenced malformed time", component(malformedTime: true), false, 1),
            ("unknown time referenced only by expired incident", component(), true, 0),
            ("fresh component survives expired reference", component(age: 60), true, 1),
            ("untracked component", component("Unrelated service", age: 60), false, 0),
            ("operational component", component(age: 60, status: "operational"), false, 0)
        ]
        for (label, affected, expiredReference, expected) in cases {
            try withManager { manager, _ in
                let incidents = expiredReference ? [incident([affected], updates: [7 * 3600])] : []
                manager.apply(try summary([affected], incidents: incidents), now: now)
                check(manager.visibleIncidents(now: now).isEmpty, "\(label): no visible incident")
                check(manager.visibleAffectedComponents(now: now).count == expected, label)
                check((manager.effectiveIndicator(now: now) == "none") == (expected == 0), "\(label): effective indicator")
            }
        }
        try withManager { manager, _ in
            let untracked = component("Unrelated service", age: 60)
            manager.apply(try summary([untracked], incidents: [incident([untracked], updates: [60])]), now: now)
            check(manager.visibleIncidents(now: now).isEmpty, "incident with only untracked components is ignored")
            check(manager.visibleAffectedComponents(now: now).isEmpty, "untracked referenced component is ignored")
            check(manager.effectiveIndicator(now: now) == "none", "untracked outage does not degrade tracked status")
        }
    }

    static func notificationTransitions() throws {
        let affected = component(age: 0)
        let outage = try summary([affected], incidents: [incident([affected], updates: [0])])
        let healthy = try summary([component(age: 0, status: "operational")], indicator: "none")
        try withManager(notifications: true) { manager, sent in
            manager.apply(outage, now: now)
            check(sent() == 0, "first apply with an outage never notifies")
        }
        try withManager(notifications: true) { manager, sent in
            manager.apply(healthy, now: now)
            check(sent() == 0, "first healthy apply never notifies")
            manager.apply(outage, now: now)
            check(sent() == 1, "fresh outage after none notifies once")
            let expiredNow = now.addingTimeInterval(sixHours + 1)
            check(outage.indicator != "none", "raw indicator remains degraded in expiry fixture")
            check(manager.visibleIncidents(now: expiredNow).isEmpty, "visibility ages without a new fetch")
            check(manager.visibleAffectedComponents(now: expiredNow).isEmpty, "component also ages without a new fetch")
            check(manager.effectiveIndicator(now: expiredNow) == "none", "effective status ages to none")
            manager.apply(outage, now: expiredNow)
            check(sent() == 1, "expiry to none is silent despite degraded raw indicator")
            manager.apply(outage, now: expiredNow.addingTimeInterval(60))
            check(sent() == 1, "repeated expired fetch is stable and silent")
            manager.apply(healthy, now: expiredNow.addingTimeInterval(120))
            check(sent() == 1, "later resolution after silent expiry does not notify again")
        }
        try withManager { manager, sent in
            manager.apply(healthy, now: now)
            manager.apply(outage, now: now)
            manager.apply(healthy, now: now.addingTimeInterval(60))
            check(sent() == 0, "disabled status notifications suppress outage and resolution")
        }
    }

    static func main() throws {
        freshnessBoundaries()
        try latestPostedUpdateControlsIncidentExpiry()
        try componentFreshnessAndTracking()
        try notificationTransitions()
        print("StatusExpiryTests passed")
    }
}
