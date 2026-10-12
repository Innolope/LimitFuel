import Foundation
import Combine
import AppKit
import Darwin
import CoreFoundation
import CryptoKit

struct CodexWindow: Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?
}

struct CodexDisplayWindow: Identifiable {
    let id: String
    let window: CodexWindow
}

struct CodexBucket: Identifiable {
    let id: String
    let name: String
    let primary: CodexWindow?
    let secondary: CodexWindow?

    var displayWindows: [CodexDisplayWindow] {
        [primary.map { CodexDisplayWindow(id: "primary", window: $0) },
         secondary.map { CodexDisplayWindow(id: "secondary", window: $0) }].compactMap { $0 }
    }
}

struct CodexSnapshot {
    let accountLabel: String?
    let buckets: [CodexBucket]

    var menuBarPercent: Double? {
        MenuBarSelection.selectedOption(provider: .codex, options: menuBarOptions, selectionID: nil)?.percent
    }

    var menuBarOptions: [MenuBarWindowOption] {
        let nameCounts = Dictionary(grouping: buckets, by: \.name).mapValues { $0.count }
        // The usual single "codex" bucket needs no prefix: "Weekly · 7d".
        let showsBucket = buckets.count > 1 || buckets.contains { $0.name.lowercased() != "codex" }
        return buckets.flatMap { bucket in
            let name = (nameCounts[bucket.name] ?? 0) > 1 ? "\(bucket.name) (\(bucket.id))" : bucket.name
            return bucket.displayWindows.map { entry in
                let window = Self.windowLabel(minutes: entry.window.windowDurationMins,
                                              role: entry.id == "primary" ? "Primary" : "Secondary")
                // Digest the exact UTF-8 bytes so delimiters and Unicode cannot
                // alias roles, and unusually long graphemes cannot exceed the
                // preference ID limit. Labels/order/account names are excluded.
                let bucketID = SHA256.hash(data: Data(bucket.id.utf8)).map { String(format: "%02x", $0) }.joined()
                return MenuBarWindowOption(id: "codex:\(bucketID):\(entry.id)", provider: .codex,
                    label: showsBucket ? "\(name) · \(window)" : window, percent: entry.window.usedPercent,
                    durationMinutes: entry.window.windowDurationMins, isPreferredBucket: bucket.id == "codex",
                    resetsAt: entry.window.resetsAt)
            }
        }
    }

    // Matches the popup meter titles: "Session · 5h", "Weekly · 7d", "Primary · 2h".
    static func windowLabel(minutes: Int?, role: String) -> String {
        guard let minutes = minutes, minutes > 0 else { return role }
        if minutes == 300 { return "Session · 5h" }
        if minutes == 10080 { return "Weekly · 7d" }
        return "\(role) · \(durationLabel(minutes))"
    }

    static func durationLabel(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

enum CodexUsageError: LocalizedError {
    case unavailable, signIn, protocolFailure, timeout, invalidData
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex was not found. Install Codex CLI or choose its executable, then sign in with ChatGPT."
        case .signIn: return "Sign in to Codex with ChatGPT, then refresh. API key accounts do not expose ChatGPT plan limits."
        case .protocolFailure: return "Codex could not read usage limits. Check your connection and sign-in, or update Codex, then refresh."
        case .timeout: return "Codex usage check timed out. Check your connection, then refresh."
        case .invalidData: return "Codex returned unavailable or invalid usage limits. Update Codex and try again."
        }
    }
}

/// A short-lived, read-only RPC connection. Codex owns authentication and renewal.
struct CodexClient {
    let executable: URL
    let timeout: TimeInterval

    init(executable: URL, timeout: TimeInterval = 20) {
        self.executable = executable
        self.timeout = timeout
    }

    static func resolveExecutable(customPath: String? = nil) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = customPath.map { [$0] } ?? [
            "/Applications/Codex.app/Contents/Resources/codex",
            home + "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home + "/.local/bin/codex", home + "/.npm-global/bin/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter {
            $0.hasPrefix("/")
        }.map { String($0) + "/codex" }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func fetch() throws -> CodexSnapshot {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexUsageError.unavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A child that exits early must fail the fetch with EPIPE, not kill the app with SIGPIPE.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            throw CodexUsageError.protocolFailure
        }
        do { try process.run() } catch { throw CodexUsageError.unavailable }
        // Parent must close its copy of the child's writer so EOF is observable.
        output.fileHandleForWriting.closeFile()
        input.fileHandleForReading.closeFile()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        let pid = process.processIdentifier
        // Foundation normally creates a new process group. Never signal our own group.
        let ownsGroup = getpgid(pid) == pid
        func terminate() {
            if ownsGroup { kill(-pid, SIGTERM) }
            else if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if ownsGroup { kill(-pid, SIGKILL) }
                else if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        let stop = DispatchWorkItem { terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        defer {
            stop.cancel()
            input.fileHandleForWriting.closeFile()
            output.fileHandleForReading.closeFile()
            terminate()
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw CodexUsageError.protocolFailure }
        func send(_ message: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: message) + Data([10])
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { throw CodexUsageError.protocolFailure }
        }
        var buffer = Data()
        var total = 0
        var accountEstablished = false
        var accountUpdated = false
        func receive(id: Int) throws -> [String: Any] {
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw CodexUsageError.protocolFailure
                    }
                    // Ignore ordinary notifications. Unexpected server requests need an
                    // unsupported-client reply instead of hanging token renewal until timeout.
                    if message["method"] != nil {
                        if let requestID = message["id"] {
                            try send(["id": requestID, "error": ["code": -32601, "message": "Read-only usage client"]])
                            throw CodexUsageError.signIn
                        }
                        if message["method"] as? String == "account/updated", accountEstablished {
                            // Codex's own startup notice can arrive after account/read.
                            // Only a non-ChatGPT mode is a sign-out; otherwise confirm below.
                            let mode = (message["params"] as? [String: Any])?["authMode"]
                            if let mode = mode as? String, mode != "chatgpt" { throw CodexUsageError.signIn }
                            accountUpdated = true
                        }
                        continue
                    }
                    guard let responseID = message["id"] as? Int, responseID == id else { continue }
                    guard message["error"] == nil,
                          let result = message["result"] as? [String: Any] else { throw CodexUsageError.protocolFailure }
                    return result
                }
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptorState, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw CodexUsageError.protocolFailure
                }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw CodexUsageError.protocolFailure
                }
                if count == 0 {
                    throw DispatchTime.now().uptimeNanoseconds >= deadline ? CodexUsageError.timeout : CodexUsageError.protocolFailure
                }
                total += count
                guard total <= 1_048_576 else { throw CodexUsageError.invalidData }
                buffer.append(contentsOf: bytes.prefix(count))
            }
            throw CodexUsageError.timeout
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "limitfuel", "title": "LimitFuel",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        ]]])
        _ = try receive(id: 1)
        try send(["method": "initialized", "params": [:]])
        func readAccount(id: Int) throws -> String? {
            try send(["id": id, "method": "account/read", "params": ["refreshToken": false]])
            guard let account = try receive(id: id)["account"] as? [String: Any],
                  account["type"] as? String == "chatgpt" else { throw CodexUsageError.signIn }
            return (account["email"] as? String).map { String($0.prefix(200)) }
        }
        func readLimits(id: Int) throws -> [CodexBucket] {
            try send(["id": id, "method": "account/rateLimits/read"])
            return try Self.parseLimits(JSONSerialization.data(withJSONObject: receive(id: id)))
        }
        var label = try readAccount(id: 2)
        // Updates before this point are startup announcements. Later ones may be
        // the same announcement racing account/read, or a real account switch.
        accountEstablished = true
        var buckets = try readLimits(id: 3)
        if accountUpdated {
            accountUpdated = false
            let confirmed = try readAccount(id: 4)
            if confirmed != label {
                label = confirmed
                buckets = try readLimits(id: 5)
            }
            // Still changing: report a transient failure and keep the last values.
            guard !accountUpdated else { throw CodexUsageError.protocolFailure }
        }
        return CodexSnapshot(accountLabel: label, buckets: buckets)
    }

    static func parseLimits(_ data: Data) throws -> [CodexBucket] {
        guard data.count <= 1_048_576,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CodexUsageError.invalidData }
        func number(_ value: Any?) throws -> Double? {
            guard let value = value, !(value is NSNull) else { return nil }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw CodexUsageError.invalidData
            }
            return n.doubleValue
        }
        func window(_ raw: Any?) throws -> CodexWindow? {
            guard let raw = raw, !(raw is NSNull) else { return nil }
            guard let object = raw as? [String: Any] else { throw CodexUsageError.invalidData }
            guard let percent = try number(object["usedPercent"]) else { return nil }
            guard percent >= 0 else { throw CodexUsageError.invalidData }
            let duration = try number(object["windowDurationMins"])
            if let d = duration, d <= 0 || d.rounded() != d || d >= Double(Int.max) { throw CodexUsageError.invalidData }
            let reset = try number(object["resetsAt"])
            if let reset = reset, reset < 0 || reset > 253_402_300_799 { throw CodexUsageError.invalidData }
            return CodexWindow(usedPercent: percent, windowDurationMins: duration.map { Int($0) },
                               resetsAt: reset.map { Date(timeIntervalSince1970: $0) })
        }
        let entries: [String: Any]
        if let multi = result["rateLimitsByLimitId"] as? [String: Any], !multi.isEmpty {
            entries = multi
        } else if let legacy = result["rateLimits"] as? [String: Any] {
            entries = [(legacy["limitId"] as? String) ?? "codex": legacy]
        } else { throw CodexUsageError.invalidData }
        guard !entries.isEmpty, entries.count <= 64 else { throw CodexUsageError.invalidData }
        return try entries.keys.sorted().map { id in
            guard !id.isEmpty, id.count <= 200, let object = entries[id] as? [String: Any] else { throw CodexUsageError.invalidData }
            let name = (object["limitName"] as? String) ?? id
            guard name.count <= 200 else { throw CodexUsageError.invalidData }
            return CodexBucket(id: id, name: name, primary: try window(object["primary"]), secondary: try window(object["secondary"]))
        }
    }
}

final class CodexUsageManager: ObservableObject {
    @Published var snapshot: CodexSnapshot?
    private var retainedMenuBarOptions: [MenuBarWindowOption] = []
    @Published private(set) var menuBarIsStale = false
    @Published private(set) var menuBarUpdatedAt: Date?
    var menuBarDisplayOptions: [MenuBarWindowOption] {
        snapshot?.menuBarOptions ?? retainedMenuBarOptions
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    private(set) var lastFetchStartedAt: Date?
    var onChange: (() -> Void)?
    private let fetcher: () throws -> CodexSnapshot
    private let notificationsEnabled: () -> Bool
    private let notify: (String, String) -> Void
    private var lastAccount: String?
    private var thresholds: [String: Int] = [:]
    private var thresholdOrder: [String] = []

    init(fetcher: @escaping () throws -> CodexSnapshot = {
        guard let executable = CodexClient.resolveExecutable(customPath: UserDefaults.standard.string(forKey: "codex_executable")) else {
            throw CodexUsageError.unavailable
        }
        return try CodexClient(executable: executable).fetch()
    }, notificationsEnabled: @escaping () -> Bool = {
        UserDefaults.standard.object(forKey: "usage_notifications_enabled") as? Bool ?? true
    }, notify: @escaping (String, String) -> Void = { title, body in
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }) {
        self.fetcher = fetcher
        self.notificationsEnabled = notificationsEnabled
        self.notify = notify
    }

    func fetchUsage() {
        guard !isLoading else { return }
        lastFetchStartedAt = Date()
        isLoading = true
        menuBarIsStale = !menuBarDisplayOptions.isEmpty
        errorMessage = nil
        onChange?()
        let fetcher = self.fetcher
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try fetcher() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                case .failure(let error):
                    self.snapshot = nil
                    if case .some(.signIn) = error as? CodexUsageError {
                        self.retainedMenuBarOptions = []
                        self.menuBarUpdatedAt = nil
                    }
                    self.menuBarIsStale = !self.retainedMenuBarOptions.isEmpty
                    self.errorMessage = (error as? CodexUsageError)?.localizedDescription ?? CodexUsageError.protocolFailure.localizedDescription
                    let code: DiagnosticErrorCode
                    switch error as? CodexUsageError {
                    case .unavailable: code = .unavailable
                    case .signIn: code = .signIn
                    case .timeout: code = .timeout
                    case .invalidData: code = .invalidData
                    default: code = .protocolFailure
                    }
                    AppDiagnostics.shared.recordFailure(provider: .codex, code: code)
                case .success(let value):
                    AppDiagnostics.shared.recordRecovery(provider: .codex)
                    if self.lastAccount != value.accountLabel {
                        self.thresholds.removeAll()
                        self.thresholdOrder.removeAll()
                    }
                    self.lastAccount = value.accountLabel
                    self.snapshot = value
                    self.retainedMenuBarOptions = value.menuBarOptions
                    self.menuBarIsStale = false
                    self.lastUpdated = Date()
                    self.menuBarUpdatedAt = self.lastUpdated
                    self.checkNotifications(value)
                }
                self.onChange?()
            }
        }
    }

    private func checkNotifications(_ value: CodexSnapshot) {
        for bucket in value.buckets {
            for (kind, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window = window else { continue }
                let key = "\(bucket.id):\(kind):\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
                let threshold = [25, 50, 75, 90].last(where: { window.usedPercent >= Double($0) }) ?? 0
                if notificationsEnabled(), threshold > (thresholds[key] ?? 0) {
                    notify("Codex Usage Alert", "\(bucket.name) \(kind) usage reached \(threshold)%.")
                }
                if thresholds[key] == nil { thresholdOrder.append(key) }
                thresholds[key] = max(thresholds[key] ?? 0, threshold)
            }
        }
        // Keep missing windows and downward corrections deduplicated; bound old resets.
        while thresholdOrder.count > 256 {
            thresholds.removeValue(forKey: thresholdOrder.removeFirst())
        }
    }
}
