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
        let usage = UsageManager(statusItem: nil, defaults: defaults)
        usage.hasFetchedData = true
        usage.sessionUsage = 92
        usage.sessionUtilization = 92
        usage.weeklyUsage = 34
        usage.sessionResetsAt = Date().addingTimeInterval(1200)
        usage.weeklyResetsAt = Date().addingTimeInterval(86400)
        usage.chromeMessage = "Connected to Chrome: Personal. Rechecks hourly."
        usage.lastChromeCheck = Date()
        let codex = CodexUsageManager(fetcher: { throw CodexUsageError.unavailable },
                                     notificationsEnabled: { false }, notify: { _, _ in })
        codex.snapshot = CodexSnapshot(accountLabel: "preview@example.test", buckets: [
            CodexBucket(id: "codex", name: "Codex", primary: CodexWindow(usedPercent: 94,
                windowDurationMins: 300, resetsAt: Date().addingTimeInterval(1800)),
                secondary: CodexWindow(usedPercent: 47, windowDurationMins: 10080,
                                      resetsAt: Date().addingTimeInterval(86400)))
        ])
        codex.lastUpdated = Date()
        for provider in ["claude", "codex"] {
            // This executable has its own defaults domain, separate from the app bundle.
            UserDefaults.standard.set(provider, forKey: "usage_provider")
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let view = UsageView(usageManager: usage, statusManager: StatusManager(),
                                     updateManager: UpdateManager(), codexManager: codex)
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
                try png.write(to: directory.appendingPathComponent("\(provider)-\(dark ? "dark" : "light").png"))
            }
        }
        UserDefaults.standard.removeObject(forKey: "usage_provider")
        print("Rendered offline Claude/Codex light/dark previews")
    }
}
