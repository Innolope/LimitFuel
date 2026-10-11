import Foundation

enum DiagnosticProvider: String, CaseIterable { case claude, codex }
enum DiagnosticErrorCode: String, CaseIterable {
    case unavailable, signIn, protocolFailure, timeout, invalidData
}
struct DiagnosticEvent: Equatable {
    let provider: DiagnosticProvider
    let code: DiagnosticErrorCode
}

/// Only fixed enums cross this boundary; never pass Error, response data or account details.
final class AppDiagnostics {
    static let preferenceKey = "diagnosticsEnabled"
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
    private let lock = NSLock()
    private let delivery = DispatchQueue(label: "com.innolope.limitfuel.diagnostics", qos: .utility)
    private var isEnabled: Bool
    private var generation: UInt64 = 0
    private var failures: [DiagnosticProvider: Set<DiagnosticErrorCode>] = [:]
    private var attempts: [Date] = []
    private var usesSDK = false

    init(defaults: UserDefaults = .standard,
         transport: @escaping (DiagnosticEvent) throws -> Void,
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.transport = transport
        self.clock = clock
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
        lock.lock(); failures.removeValue(forKey: provider); lock.unlock()
    }
    func recordFailure(provider: DiagnosticProvider, code: DiagnosticErrorCode) {
        lock.lock()
        guard isEnabled, !(failures[provider]?.contains(code) ?? false) else { lock.unlock(); return }
        let now = clock()
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
