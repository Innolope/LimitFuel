import Foundation
import Network

enum DiagnosticProvider: String, CaseIterable { case claude, codex }
enum DiagnosticErrorCode: String, CaseIterable {
    case unavailable, signIn, protocolFailure, timeout, invalidData

    /// Setup and account states are shown in the app and fixed by the user; they are not defects.
    var isReportable: Bool { self != .unavailable && self != .signIn }
    /// Sleep, wake and bad Wi-Fi cause these routinely; only an outage that outlasts them is a signal.
    var needsPersistence: Bool { self == .timeout || self == .protocolFailure }
}

/// Whether any network route exists. Failures without one say nothing about the providers.
final class NetworkPath {
    static let shared = NetworkPath()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.satisfied = path.status == .satisfied; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.innolope.limitfuel.network-path", qos: .utility))
    }
    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return satisfied }
}
struct DiagnosticEvent: Equatable {
    let provider: DiagnosticProvider
    let code: DiagnosticErrorCode
}

/// Only fixed enums cross this boundary; never pass Error, response data or account details.
final class AppDiagnostics {
    static let preferenceKey = "diagnosticsEnabled"
    /// A transient failure is sent only after this many online failures in a row over this long.
    static let persistentFailureCount = 10
    static let persistentFailureDuration: TimeInterval = 3600
    static let shared: AppDiagnostics = {
        #if ACCEPTANCE_TESTS
        return AppDiagnostics(transport: { _ in })
        #else
        let policy = AppDiagnostics(transport: { SentryDiagnostics.shared.capture($0) })
        policy.usesSDK = true
        return policy
        #endif
    }()
    private let defaults: UserDefaults
    private let transport: (DiagnosticEvent) throws -> Void
    private let clock: () -> Date
    private let isOnline: () -> Bool
    private let lock = NSLock()
    private let delivery = DispatchQueue(label: "com.innolope.limitfuel.diagnostics", qos: .utility)
    private var isEnabled: Bool
    private var generation: UInt64 = 0
    private var failures: [DiagnosticProvider: Set<DiagnosticErrorCode>] = [:]
    private var streaks: [DiagnosticProvider: (started: Date, count: Int)] = [:]
    private var attempts: [Date] = []
    private var usesSDK = false

    init(defaults: UserDefaults = .standard,
         transport: @escaping (DiagnosticEvent) throws -> Void,
         clock: @escaping () -> Date = Date.init,
         isOnline: @escaping () -> Bool = { NetworkPath.shared.isOnline }) {
        self.defaults = defaults
        self.transport = transport
        self.clock = clock
        self.isOnline = isOnline
        isEnabled = defaults.object(forKey: Self.preferenceKey) == nil
            || defaults.bool(forKey: Self.preferenceKey)
    }
    var enabled: Bool { lock.lock(); defer { lock.unlock() }; return isEnabled }
    var statusText: String {
        guard enabled else { return "Error reporting is off." }
        #if ACCEPTANCE_TESTS
        return "Error reporting uses an offline test transport."
        #else
        return SentryDiagnostics.shared.statusText
        #endif
    }
    func start() {
        #if !ACCEPTANCE_TESTS
        if usesSDK { SentryDiagnostics.shared.setEnabled(enabled) }
        #endif
    }
    func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        generation &+= 1
        let revision = generation
        failures.removeAll()
        streaks.removeAll()
        defaults.set(enabled, forKey: Self.preferenceKey)
        lock.unlock()
        #if !ACCEPTANCE_TESTS
        if usesSDK {
            SentryDiagnostics.shared.setEnabled(enabled, permitted: { [weak self] in
                guard let self else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.generation == revision
            })
        }
        #endif
    }
    func recordRecovery(provider: DiagnosticProvider) {
        lock.lock()
        failures.removeValue(forKey: provider)
        streaks.removeValue(forKey: provider)
        lock.unlock()
    }
    func recordFailure(provider: DiagnosticProvider, code: DiagnosticErrorCode) {
        guard code.isReportable else { return }
        // Offline failures neither count toward a streak nor break it.
        if code.needsPersistence, !isOnline() { return }
        lock.lock()
        guard isEnabled, !(failures[provider]?.contains(code) ?? false) else { lock.unlock(); return }
        let now = clock()
        if code.needsPersistence {
            let streak = streaks[provider].map { (started: $0.started, count: $0.count + 1) } ?? (started: now, count: 1)
            streaks[provider] = streak
            guard streak.count >= Self.persistentFailureCount,
                  now.timeIntervalSince(streak.started) >= Self.persistentFailureDuration else { lock.unlock(); return }
        }
        attempts.removeAll { now.timeIntervalSince($0) >= 3600 }
        guard attempts.count < 20 else { lock.unlock(); return }
        failures[provider, default: []].insert(code)
        attempts.append(now)
        let revision = generation
        lock.unlock()
        delivery.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let allowed = self.isEnabled && self.generation == revision
            self.lock.unlock()
            guard allowed else { return }
            let event = DiagnosticEvent(provider: provider, code: code)
            #if !ACCEPTANCE_TESTS
            if self.usesSDK {
                SentryDiagnostics.shared.capture(event, permitted: { [weak self] in
                    guard let self else { return false }
                    self.lock.lock(); defer { self.lock.unlock() }
                    return self.isEnabled && self.generation == revision
                })
                return
            }
            #endif
            // No retry: telemetry failure must never change provider recovery or policy.
            try? self.transport(event)
        }
    }
}
