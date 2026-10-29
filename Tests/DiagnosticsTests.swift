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
        let diagnostics = AppDiagnostics(defaults: defaults, transport: { events.add($0) }, clock: { now })
        check(diagnostics.enabled, "diagnostics defaults on")
        diagnostics.recordFailure(provider: .claude, code: .timeout)
        diagnostics.recordFailure(provider: .claude, code: .timeout)
        awaitCount(events, 1)
        diagnostics.recordFailure(provider: .codex, code: .timeout)
        awaitCount(events, 2)
        diagnostics.recordRecovery(provider: .codex)
        diagnostics.recordFailure(provider: .claude, code: .timeout)
        Thread.sleep(forTimeInterval: 0.03)
        check(events.count == 2, "other provider recovery does not clear Claude dedupe")
        diagnostics.recordRecovery(provider: .claude)
        diagnostics.recordFailure(provider: .claude, code: .timeout)
        awaitCount(events, 3)
        diagnostics.setEnabled(false)
        check(!diagnostics.enabled, "opt-out immediate")
        let restored = AppDiagnostics(defaults: defaults, transport: { events.add($0) }, clock: { now })
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
        diagnostics.recordFailure(provider: .claude, code: .timeout)
        Thread.sleep(forTimeInterval: 0.03)
        check(events.count == 20, "rolling hour does not expire early")
        now = now.addingTimeInterval(2)
        diagnostics.recordRecovery(provider: .claude)
        diagnostics.recordFailure(provider: .claude, code: .timeout)
        awaitCount(events, 21)
        let stall = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let stalled = AppDiagnostics(defaults: defaults, transport: { _ in started.signal(); _ = stall.wait(timeout: .now() + 2) }, clock: { now })
        let before = Date()
        stalled.recordFailure(provider: .codex, code: .timeout)
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
        throwing.recordFailure(provider: .claude, code: .unavailable)
        check(attempted.wait(timeout: .now() + 1) == .success, "throwing fake transport attempted")
        throwing.recordRecovery(provider: .claude)
        throwing.setEnabled(false)
        check(!throwing.enabled, "transport exception cannot break recovery or opt-out")
        check(ChromeCookieError.diagnosticCode(for: ChromeCookieError.keychain, interactive: false) == nil,
              "hourly background Keychain denial is not a Claude connection error")
        check(ChromeCookieError.diagnosticCode(for: ChromeCookieError.keychain, interactive: true) == .signIn,
              "explicit detection still reports Keychain denial")
        check(ChromeCookieError.diagnosticCode(for: ChromeCookieError.encryption, interactive: false) == .invalidData,
              "background detection keeps reporting other Chrome failures")
        print("Diagnostics acceptance passed")
    }
}
