import Foundation
import Combine
import AppKit
import Darwin

private var checks = 0
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    checks += 1
    do { if try !condition() { fputs("FAIL Codex: \(message)\n", stderr); exit(1) } }
    catch { fputs("FAIL Codex: \(message): \(error)\n", stderr); exit(1) }
}
private func reject(_ message: String, _ body: () throws -> Void) {
    do { try body(); check(false, message) } catch { checks += 1 }
}
private func spin(_ predicate: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    return predicate()
}
private enum FixtureError: Error { case offline }
private func parse(_ text: String) throws -> [CodexBucket] { try CodexClient.parseLimits(Data(text.utf8)) }
private let valid = #"{"rateLimitsByLimitId":{"fixture":{"limitName":"Fixture","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":1800600000}}}}"#
private func snapshot(_ used: Double, account: String = "fixture@example.test", reset: TimeInterval = 1800000000) -> CodexSnapshot {
    CodexSnapshot(accountLabel: account, buckets: [CodexBucket(id: "fixture", name: "Fixture", primary: CodexWindow(usedPercent: used, windowDurationMins: 300, resetsAt: Date(timeIntervalSince1970: reset)), secondary: nil)])
}
@main struct CodexTests {
    static func main() throws {
        let parsed = try parse(valid)
        check(parsed.count == 1 && parsed[0].id == "fixture" && parsed[0].name == "Fixture", "map bucket identity")
        check(parsed[0].primary?.usedPercent == 25 && parsed[0].primary?.windowDurationMins == 300, "primary percent and duration")
        check(parsed[0].secondary?.usedPercent == 50 && parsed[0].secondary?.resetsAt == Date(timeIntervalSince1970: 1800600000), "secondary reset")
        let preferred = try parse(#"{"rateLimitsByLimitId":{"new":{"primary":{"usedPercent":10}}},"rateLimits":{"primary":{"usedPercent":99}}}"#)
        check(preferred.count == 1 && preferred[0].id == "new" && preferred[0].name == "new" && preferred[0].primary?.usedPercent == 10, "nonempty map preferred and name fallback")
        for map in ["{}", "null"] {
            let legacy = try parse("{\"rateLimitsByLimitId\":\(map),\"rateLimits\":{\"primary\":{\"usedPercent\":30}}}")
            check(legacy.count == 1 && legacy[0].primary?.usedPercent == 30, "legacy fallback")
        }
        let missing = try parse(#"{"rateLimitsByLimitId":{"missing":{"primary":{"usedPercent":null},"secondary":null}}}"#)
        check(missing.count == 1 && missing[0].primary == nil && missing[0].secondary == nil, "null is unavailable")
        let noPercent = try parse(#"{"rateLimitsByLimitId":{"missing":{"primary":{"windowDurationMins":300}}}}"#)
        check(noPercent[0].primary == nil, "missing percentage is unavailable")
        for raw in ["true", "-1", "1e999", "\"25\""] {
            reject("invalid percentage \(raw)") { _ = try parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":\(raw)}}}") }
        }
        for raw in ["0", "-1", "1.5", "true", "\"300\""] {
            reject("invalid duration \(raw)") { _ = try parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"windowDurationMins\":\(raw)}}}") }
        }
        for raw in ["true", "1e999", "\"1800000000\""] {
            reject("invalid reset \(raw)") { _ = try parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"resetsAt\":\(raw)}}}") }
        }
        for raw in ["{}", "[]", "null", "not JSON", #"{"rateLimitsByLimitId":[]}"#, #"{"rateLimitsByLimitId":{"bad":false}}"#, #"{"rateLimits":{"primary":[]}}"#] {
            reject("malformed structure") { _ = try parse(raw) }
        }
        for number in [64, 65] {
            let buckets = (0..<number).map { "\"b\($0)\":{\"primary\":{\"usedPercent\":1}}" }.joined(separator: ",")
            if number == 64 { check(try parse("{\"rateLimitsByLimitId\":{\(buckets)}}").count == 64, "64 bucket boundary") }
            else { reject("65 buckets") { _ = try parse("{\"rateLimitsByLimitId\":{\(buckets)}}") } }
        }
        check(try parse("{\"rateLimitsByLimitId\":{\"x\":{\"limitName\":\"\(String(repeating: "a", count: 200))\"}}}").count == 1, "200-character name")
        reject("overlong name") { _ = try parse("{\"rateLimitsByLimitId\":{\"x\":{\"limitName\":\"\(String(repeating: "a", count: 201))\"}}}") }
        reject("over 1MiB parser input") { _ = try CodexClient.parseLimits(Data(repeating: 32, count: 1_048_577)) }
        // Deterministic negative percentage fuzz: seed 0xC0D3, budget 128.
        var seed: UInt64 = 0xC0D3
        for _ in 0..<128 {
            seed = seed &* 6364136223846793005 &+ 1
            let negative = -(Int(seed % 100000) + 1)
            reject("negative percentage fuzz") { _ = try parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":\(negative)}}}") }
        }

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        var alerts: [(String, String)] = []
        var offMain = false
        let manager = CodexUsageManager(fetcher: {
            lock.lock(); calls += 1; offMain = !Thread.isMainThread; lock.unlock()
            entered.signal(); _ = release.wait(timeout: .now() + 4)
            return snapshot(25)
        }, notificationsEnabled: { true }, notify: { alerts.append(($0, $1)) })
        var publicationMain = true
        var observed = false
        let subscription = manager.$snapshot.sink { value in if value != nil { observed = true; publicationMain = publicationMain && Thread.isMainThread } }
        manager.fetchUsage(); manager.fetchUsage(); manager.fetchUsage()
        check(entered.wait(timeout: .now() + 2) == .success, "fetch starts in background")
        lock.lock(); let callCount = calls; let background = offMain; lock.unlock()
        check(callCount == 1 && background && manager.isLoading, "overlap coalesces and fetch is off main")
        release.signal()
        check(spin { !manager.isLoading && observed }, "fetch publishes snapshot")
        check(publicationMain && manager.lastUpdated != nil && manager.errorMessage == nil, "main publication and update metadata")
        withExtendedLifetime(subscription) {}

        var next = snapshot(25)
        var fail = false
        var notifications: [(String,String)] = []
        let state = CodexUsageManager(fetcher: { if fail { throw FixtureError.offline }; return next }, notificationsEnabled: { true }, notify: { notifications.append(($0,$1)) })
        func fetch() { state.fetchUsage(); check(spin { !state.isLoading }, "state fetch settles") }
        fetch(); let firstCount = notifications.count
        check(firstCount > 0, "threshold 25 alerts")
        fetch(); check(notifications.count == firstCount, "unchanged usage deduplicated")
        for threshold in [50.0,75,90] {
            let before = notifications.count; next = snapshot(threshold); fetch()
            check(notifications.count > before, "new threshold \(threshold) alerts")
            let after = notifications.count; fetch(); check(notifications.count == after, "threshold dedup")
        }
        let beforeReset = notifications.count; next = snapshot(25, reset: 1800000300); fetch()
        check(notifications.count > beforeReset, "new window reset reenables alerts")
        let beforeAccount = notifications.count; next = snapshot(25, account: "other@example.test", reset: 1800000300); fetch()
        check(notifications.count > beforeAccount, "new account reenables alerts")
        let beforeBucket = notifications.count
        next = CodexSnapshot(accountLabel: "other@example.test", buckets: [CodexBucket(id: "second", name: "Second", primary: CodexWindow(usedPercent: 25, windowDurationMins: 300, resetsAt: Date(timeIntervalSince1970: 1800000300)), secondary: nil)])
        fetch(); check(notifications.count > beforeBucket, "independent bucket alerts")
        let beforeWindow = notifications.count
        next = CodexSnapshot(accountLabel: "other@example.test", buckets: [CodexBucket(id: "second", name: "Second", primary: nil, secondary: CodexWindow(usedPercent: 25, windowDurationMins: 300, resetsAt: Date(timeIntervalSince1970: 1800000300)))])
        fetch(); check(notifications.count > beforeWindow, "independent secondary window alerts")
        fail = true; fetch()
        check(state.snapshot == nil && state.errorMessage != nil, "error clears stale usage")
        var disabledAlerts = 0
        let disabled = CodexUsageManager(fetcher: { snapshot(95) }, notificationsEnabled: { false }, notify: { _,_ in disabledAlerts += 1 })
        disabled.fetchUsage(); check(spin { !disabled.isLoading }, "disabled alerts fetch settles")
        check(disabledAlerts == 0, "notification preference respected")
        for missingWindow in [false, true] {
            var regressionSnapshot = snapshot(25)
            var regressionAlerts = 0
            let regression = CodexUsageManager(fetcher: { regressionSnapshot }, notificationsEnabled: { true }, notify: { _,_ in regressionAlerts += 1 })
            regression.fetchUsage(); check(spin { !regression.isLoading }, "regression first fetch settles")
            check(regressionAlerts == 1, "regression first threshold alerts exactly once")
            if missingWindow {
                regressionSnapshot = CodexSnapshot(accountLabel: "fixture@example.test", buckets: [CodexBucket(id: "fixture", name: "Fixture", primary: nil, secondary: nil)])
            } else { regressionSnapshot = snapshot(24) }
            regression.fetchUsage(); check(spin { !regression.isLoading }, "regression intermediate fetch settles")
            regressionSnapshot = snapshot(25)
            regression.fetchUsage(); check(spin { !regression.isLoading }, "regression return fetch settles")
            check(regressionAlerts == 1, "same account bucket reset never rearms on lower or missing percentage")
        }

        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? "/private/tmp").appendingPathComponent("codex-fakes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func executable(_ mode: String) throws -> URL {
            let url = root.appendingPathComponent("fake-\(mode)")
            // Shell fixture validates exact method ordering without evaluating input.
            let script = """
            #!/bin/sh
            IFS= read -r line || exit 31
            case "$line" in *'"initialize"'*) ;; *) exit 32;; esac
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
            IFS= read -r line || exit 33
            case "$line" in *'"initialized"'*) ;; *) exit 34;; esac
            IFS= read -r line || exit 35
            case "$line" in *'"account/read"'*|*'"account\\/read"'*) ;; *) exit 36;; esac
            if [ '\(mode)' = 'eof' ]; then exit 0; fi
            if [ '\(mode)' = 'hang' ]; then exec /bin/sleep 5; fi
            if [ '\(mode)' = 'rpc-error' ]; then
              printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"fixture failure"}}'
              exit 0
            fi
            if [ '\(mode)' = 'api-key' ]; then
              printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"apiKey"}}}'
              exit 0
            fi
            if [ '\(mode)' = 'no-login' ]; then
              printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"account":null}}'
              exit 0
            fi
            printf '%s\\n' '{"jsonrpc":"2.0","method":"fixture/notification","params":{}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"}}}'
            IFS= read -r line || exit 37
            case "$line" in *'"account/rateLimits/read"'*|*'"account\\/rateLimits\\/read"'*) ;; *) exit 38;; esac
            printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":\(valid)}'
            # The parent must close stdin or terminate; no additional method is permitted.
            if IFS= read -r line; then exit 39; fi
            """
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        check(CodexClient(executable: root).timeout == CodexClient.defaultTimeout
              && CodexClient.defaultTimeout >= 40 && CodexClient.defaultTimeout < RefreshSchedule.usageInterval,
              "default budget covers a slow app-server cold start and ends before the next poll")
        let success = try CodexClient(executable: executable("success"), timeout: 20).fetch()
        check(success.accountLabel?.contains("fixture@example.test") == true && success.buckets.count == 1, "RPC order/auth/notification and result")
        for mode in ["eof", "rpc-error", "api-key", "no-login", "hang"] {
            let url = try executable(mode)
            let start = Date()
            reject("fake \(mode) rejected") { _ = try CodexClient(executable: url, timeout: 0.25).fetch() }
            check(Date().timeIntervalSince(start) < 2, "bounded failure/timeout cleanup \(mode)")
        }
        reject("missing executable") { _ = try CodexClient(executable: root.appendingPathComponent("missing"), timeout: 0.25).fetch() }
        guard let fixturePath = ProcessInfo.processInfo.environment["CLAUDE_CODEX_DESCENDANT_FIXTURE"] else {
            check(false, "native descendant fixture supplied by runner")
            return
        }
        let nativeFixture = URL(fileURLWithPath: fixturePath)
        let parentMarker = URL(fileURLWithPath: fixturePath + ".parent.pid")
        let childMarker = URL(fileURLWithPath: fixturePath + ".child.pid")
        let readyMarker = URL(fileURLWithPath: fixturePath + ".ready.time")
        func readReadyTime() -> Double? {
            guard let text = try? String(contentsOf: readyMarker, encoding: .utf8) else { return nil }
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? FileManager.default.removeItem(at: parentMarker)
        try? FileManager.default.removeItem(at: childMarker)
        try? FileManager.default.removeItem(at: readyMarker)
        func cleanupOwnedFixture() {
            for marker in [childMarker, parentMarker] {
                if let value = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { _ = Darwin.kill(pid, SIGKILL) }
            }
        }
        defer { cleanupOwnedFixture() }
        let descendantDone = DispatchSemaphore(value: 0)
        let descendantLock = NSLock()
        var descendantFailed = false
        var descendantError: String?
        var workerStartedAt: Date?
        let workerEntered = DispatchSemaphore(value: 0)
        let worker = Thread {
            descendantLock.lock(); workerStartedAt = Date(); descendantLock.unlock()
            workerEntered.signal()
            do { _ = try CodexClient(executable: nativeFixture, timeout: 8).fetch() }
            catch { descendantLock.lock(); descendantFailed = true; descendantError = String(describing: error); descendantLock.unlock() }
            descendantDone.signal()
        }
        worker.qualityOfService = .userInitiated
        worker.start()
        let enteredWorker = workerEntered.wait(timeout: .now() + 20) == .success
        if !enteredWorker { cleanupOwnedFixture() }
        check(enteredWorker, "dedicated timeout-fixture worker entered before measurement")
        descendantLock.lock(); let descendantStart = workerStartedAt!; descendantLock.unlock()
        let descendantReady = spin({ FileManager.default.fileExists(atPath: parentMarker.path) && FileManager.default.fileExists(atPath: childMarker.path) && readReadyTime() != nil }, timeout: 6)
        if !descendantReady {
            descendantLock.lock(); let diagnostic = descendantError ?? "fetch still pending"; descendantLock.unlock()
            fputs("Native descendant fixture readiness failed after \(Date().timeIntervalSince(descendantStart))s: \(diagnostic)\n", stderr)
            cleanupOwnedFixture()
        }
        check(descendantReady, "TERM-resistant native descendant readiness confirmed before8s deadline")
        let readyTimestamp = readReadyTime()
        if readyTimestamp == nil || readyTimestamp! >= descendantStart.timeIntervalSince1970 + 8 { cleanupOwnedFixture() }
        check(readyTimestamp != nil && readyTimestamp! >= descendantStart.timeIntervalSince1970 && readyTimestamp! < descendantStart.timeIntervalSince1970 + 8, "native child timestamp proves readiness within client deadline despite watcher scheduling")
        let remainingBudget = max(0, 12 - Date().timeIntervalSince(descendantStart))
        let finished = descendantDone.wait(timeout: .now() + remainingBudget)
        cleanupOwnedFixture()
        check(finished == .success && Date().timeIntervalSince(descendantStart) < 12.5, "timeout bounded with TERM-resistant stdout descendant sleeping30s")
        descendantLock.lock(); let failedAsExpected = descendantFailed; descendantLock.unlock()
        check(failedAsExpected, "descendant-holding-pipe timeout reports error")
        print("PASS Codex: \(checks) checks; fuzz seed=0xC0D3 budget=128; synthetic subprocess and injected manager faults")
    }
}
