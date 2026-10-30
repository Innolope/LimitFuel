import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
private final class Events {
    private let lock = NSLock()
    private var storage: [DiagnosticEvent] = []
    func add(_ event: DiagnosticEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
}
private func awaitCount(_ events: Events, _ count: Int) {
    let deadline = Date().addingTimeInterval(2)
    while events.count < count && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    check(events.count == count, "expected \(count) delivered events, got \(events.count)")
}
@main struct DiagnosticsAcceptance {
    static func main() {
        let suite = "LimitFuel.Spec.Diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let events = Events()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let diagnostics = AppDiagnostics(defaults: defaults, transport: { events.add($0) }, clock: { now }, isOnline: { true })
        check(diagnostics.enabled, "diagnostics defaults on")
        diagnostics.recordFailure(provider: .claude, code: .invalidData)
        diagnostics.recordFailure(provider: .claude, code: .invalidData)
        awaitCount(events, 1)
        diagnostics.recordFailure(provider: .codex, code: .invalidData)
        awaitCount(events, 2)
        diagnostics.recordRecovery(provider: .codex)
        diagnostics.recordFailure(provider: .claude, code: .invalidData)
        Thread.sleep(forTimeInterval: 0.03)
        check(events.count == 2, "other provider recovery does not clear Claude dedupe")
        diagnostics.recordRecovery(provider: .claude)
        diagnostics.recordFailure(provider: .claude, code: .invalidData)
        awaitCount(events, 3)
        diagnostics.setEnabled(false)
        check(!diagnostics.enabled, "opt-out immediate")
        let restored = AppDiagnostics(defaults: defaults, transport: { events.add($0) }, clock: { now }, isOnline: { true })
        check(!restored.enabled, "opt-out persisted")
        diagnostics.recordFailure(provider: .codex, code: .invalidData)
        diagnostics.setEnabled(true)
        Thread.sleep(forTimeInterval: 0.03)
        check(events.count == 3, "re-enable never sends cached failures")
        diagnostics.recordFailure(provider: .codex, code: .invalidData)
        awaitCount(events, 4)
        for _ in 0..<30 {
            diagnostics.recordRecovery(provider: .claude)
            diagnostics.recordFailure(provider: .claude, code: .invalidData)
        }
        awaitCount(events, 20)
        Thread.sleep(forTimeInterval: 0.03)
        check(events.count == 20, "global hourly cap survives recovery")
        now = now.addingTimeInterval(3599)
        diagnostics.recordRecovery(provider: .claude)
        diagnostics.recordFailure(provider: .claude, code: .invalidData)
        Thread.sleep(forTimeInterval: 0.03)
        check(events.count == 20, "rolling hour does not expire early")
        now = now.addingTimeInterval(2)
        diagnostics.recordRecovery(provider: .claude)
        diagnostics.recordFailure(provider: .claude, code: .invalidData)
        awaitCount(events, 21)
        let stall = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let stalled = AppDiagnostics(defaults: defaults, transport: { _ in started.signal(); _ = stall.wait(timeout: .now() + 2) }, clock: { now })
        let before = Date()
        stalled.recordFailure(provider: .codex, code: .invalidData)
        check(Date().timeIntervalSince(before) < 0.25, "transport stalls cannot block recordFailure")
        check(started.wait(timeout: .now() + 1) == .success, "fake stalled transport began")
        stalled.setEnabled(false)
        stalled.recordRecovery(provider: .codex)
        check(!stalled.enabled, "policy remains responsive during transport stall")
        stall.signal()
        enum FakeTransportError: Error { case synthetic }
        let attempted = DispatchSemaphore(value: 0)
        let throwing = AppDiagnostics(defaults: defaults, transport: { _ in attempted.signal(); throw FakeTransportError.synthetic }, clock: { now })
        throwing.setEnabled(true)
        throwing.recordFailure(provider: .claude, code: .invalidData)
        check(attempted.wait(timeout: .now() + 1) == .success, "throwing fake transport attempted")
        throwing.recordRecovery(provider: .claude)
        throwing.setEnabled(false)
        check(!throwing.enabled, "transport exception cannot break recovery or opt-out")
        check(ChromeCookieError.diagnosticCode(for: ChromeCookieError.keychain, interactive: false) == nil,
              "hourly background Keychain denial is not a Claude connection error")
        check(ChromeCookieError.diagnosticCode(for: ChromeCookieError.keychain, interactive: true) == .signIn,
              "explicit detection classifies Keychain denial as sign-in, which the policy never sends")
        check(ChromeCookieError.diagnosticCode(for: ChromeCookieError.encryption, interactive: false) == .invalidData,
              "background detection keeps reporting other Chrome failures")
        noiseIsNeverSent()
        transientFailuresNeedAnOnlineOutage()
        print("Diagnostics acceptance passed")
    }

    private static func withPolicy(online: @escaping () -> Bool = { true },
                           _ body: (AppDiagnostics, Events, (TimeInterval) -> Void) -> Void) {
        let suite = "LimitFuel.Spec.Diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let events = Events()
        var now = Date(timeIntervalSince1970: 2_000_000)
        let policy = AppDiagnostics(defaults: defaults, transport: { events.add($0) }, clock: { now }, isOnline: online)
        body(policy, events, { now = now.addingTimeInterval($0) })
    }

    // Sign-in and setup states are user actions shown in the app, never Sentry events.
    static func noiseIsNeverSent() {
        withPolicy { policy, events, advance in
            for _ in 0..<40 {
                for provider in DiagnosticProvider.allCases {
                    policy.recordFailure(provider: provider, code: .signIn)
                    policy.recordFailure(provider: provider, code: .unavailable)
                }
                advance(600)
            }
            policy.recordRecovery(provider: .claude)
            policy.recordFailure(provider: .claude, code: .signIn)
            Thread.sleep(forTimeInterval: 0.05)
            check(events.count == 0, "signIn and unavailable never send, even for hours or after recovery")
        }
    }

    static func transientFailuresNeedAnOnlineOutage() {
        // The LIMITFUEL-3 pattern: a timeout, then a successful poll minutes later.
        withPolicy { policy, events, advance in
            for _ in 0..<48 {
                policy.recordFailure(provider: .codex, code: .timeout)
                advance(60)
                policy.recordRecovery(provider: .codex)
                advance(1200)
            }
            Thread.sleep(forTimeInterval: 0.05)
            check(events.count == 0, "failures that recover on the next poll never send")
        }
        withPolicy { policy, events, advance in
            for _ in 0..<(AppDiagnostics.persistentFailureCount * 3) {
                policy.recordFailure(provider: .claude, code: .protocolFailure)
                advance(60)
            }
            Thread.sleep(forTimeInterval: 0.05)
            check(events.count == 0, "many failures within the first hour do not send")
            advance(AppDiagnostics.persistentFailureDuration)
            policy.recordFailure(provider: .claude, code: .protocolFailure)
            awaitCount(events, 1)
            policy.recordFailure(provider: .claude, code: .protocolFailure)
            policy.recordFailure(provider: .codex, code: .protocolFailure)
            Thread.sleep(forTimeInterval: 0.05)
            check(events.count == 1, "one sustained outage sends once; another provider needs its own streak")
            policy.recordRecovery(provider: .claude)
            policy.recordFailure(provider: .claude, code: .protocolFailure)
            Thread.sleep(forTimeInterval: 0.05)
            check(events.count == 1, "recovery restarts the streak")
        }
        withPolicy { policy, events, advance in
            // A sleep between failures still needs a run of failed polls after waking.
            for _ in 0..<3 { policy.recordFailure(provider: .codex, code: .timeout) }
            advance(8 * 3600)
            for _ in 0..<(AppDiagnostics.persistentFailureCount - 4) { policy.recordFailure(provider: .codex, code: .timeout) }
            Thread.sleep(forTimeInterval: 0.05)
            check(events.count == 0, "a long gap alone does not make an outage")
            policy.recordFailure(provider: .codex, code: .timeout)
            awaitCount(events, 1)
        }
        var online = false
        withPolicy(online: { online }) { policy, events, advance in
            for _ in 0..<(AppDiagnostics.persistentFailureCount * 2) {
                policy.recordFailure(provider: .codex, code: .timeout)
                advance(600)
            }
            Thread.sleep(forTimeInterval: 0.05)
            check(events.count == 0, "failures without a network route never count")
            policy.recordFailure(provider: .codex, code: .invalidData)
            awaitCount(events, 1)
            online = true
            for _ in 0..<(AppDiagnostics.persistentFailureCount - 1) {
                policy.recordFailure(provider: .codex, code: .timeout)
                advance(600)
            }
            Thread.sleep(forTimeInterval: 0.05)
            check(events.count == 1, "offline failures did not pre-fill the online streak")
            policy.recordFailure(provider: .codex, code: .timeout)
            awaitCount(events, 2)
        }
    }
}
