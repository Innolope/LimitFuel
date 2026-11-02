import AppKit
import SwiftUI

// Offline UI fixture. It never fetches network data or reads browser credentials.
@main struct RenderPreview {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LimitFuel.Preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "chrome_detection_enabled")
        defaults.set(false, forKey: "usage_notifications_enabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        // Two Claude accounts with resolved emails, so the preview shows per-account cards.
        defaults.set(["work", "personal"], forKey: "claude_account_ids")
        for (id, email, profile) in [("work", "jordan@studio.example", "Work"), ("personal", "jordan.lee@example.com", "Personal")] {
            defaults.set(true, forKey: "claude_account.\(id).chrome_sync")
            defaults.set(profile, forKey: "claude_account.\(id).chrome_profile_name")
            defaults.set(email, forKey: "claude_account.\(id).email")
        }
        let claude = ClaudeAccounts(defaults: defaults, credentials: InMemoryCredentialStore())
        for (usage, (session, weekly)) in zip(claude.accounts, [(92.0, 34.0), (18.0, 61.0)]) {
            usage.parseUsageData(Data(#"{"five_hour":{"utilization":\#(session)},"seven_day":{"utilization":\#(weekly)}}"#.utf8))
            usage.sessionResetsAt = Date().addingTimeInterval(1200)
            usage.weeklyResetsAt = Date().addingTimeInterval(86400)
            usage.lastChromeCheck = Date()
        }
        let codex = CodexUsageManager(fetcher: { throw CodexUsageError.unavailable },
                                     notificationsEnabled: { false }, notify: { _, _ in })
        codex.snapshot = CodexSnapshot(accountLabel: "preview@example.test", buckets: [
            CodexBucket(id: "codex", name: "Codex", primary: CodexWindow(usedPercent: 94,
                windowDurationMins: 300, resetsAt: Date().addingTimeInterval(1800)),
                secondary: CodexWindow(usedPercent: 47, windowDurationMins: 10080,
                                      resetsAt: Date().addingTimeInterval(86400)))
        ])
        codex.lastUpdated = Date()
        // A healthy Claude page and a synthetic Codex incident, so both status rows render.
        let claudeStatus = StatusManager(defaults: defaults, notify: { _, _ in })
        claudeStatus.apply(StatusSummary(indicator: "none", description: "All Systems Operational", incidents: [], components: []))
        let codexStatus = StatusManager(source: .codex, defaults: defaults, notify: { _, _ in })
        let posted = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        codexStatus.apply(StatusManager.decodeCodex(Data(#"""
            {"ongoing_incidents":[{"id":"preview","name":"Elevated errors in Codex CLI","status":"identified",
             "last_update_at":"\#(posted)","last_update_message":"A fix is rolling out.",
             "affected_components":[{"id":"cli","name":"CLI","group_name":"Codex","current_status":"degraded_performance"}]}]}
            """#.utf8))!)
        for (page, settings) in [("popup", false), ("settings", true)] {
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let view = UsageView(claude: claude, settings: AppSettings(defaults: defaults),
                                     statusManager: claudeStatus,
                                     updateManager: UpdateManager(), codexManager: codex,
                                     codexStatusManager: codexStatus,
                                     startsInSettings: settings)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                host.layoutSubtreeIfNeeded()
                window.setContentSize(host.fittingSize)
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw NSError(domain: "preview", code: 1)
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "preview", code: 2)
                }
                try png.write(to: directory.appendingPathComponent("\(page)-\(dark ? "dark" : "light").png"))
            }
        }
        print("Rendered offline popup and settings light/dark previews")
    }
}
