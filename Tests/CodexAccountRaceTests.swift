import Foundation

fileprivate func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

private final class RaceFetchFixture {
    private let lock = NSLock()
    private var results: [Result<CodexSnapshot, Error>]
    init(_ results: [Result<CodexSnapshot, Error>]) { self.results = results }
    func fetch() throws -> CodexSnapshot {
        lock.lock()
        guard !results.isEmpty else { lock.unlock(); fatalError("unexpected manager retry") }
        let result = results.removeFirst()
        lock.unlock()
        return try result.get()
    }
    var exhausted: Bool { lock.lock(); defer { lock.unlock() }; return results.isEmpty }
}

@main struct CodexAccountRaceTests {
    private static let initial = ["initialize", "initialized", "account/read", "account/rateLimits/read"]

    private static func fixture(root: URL, mode: String, update: String = #"{"params":{"authMode":"chatgpt"}}"#) throws -> (URL, URL) {
        let name = UUID().uuidString
        let executable = root.appendingPathComponent(name + ".py")
        let requests = root.appendingPathComponent(name + ".requests")
        let script = """
        #!/usr/bin/env python3
        import json, os, sys, time
        mode = '\(mode)'
        update = json.loads('\(update)')
        account_reads = 0
        limit_reads = 0
        def send(message):
            print(json.dumps(message), flush=True)
        def notice(extra):
            message = {'jsonrpc':'2.0', 'method':'account/updated'}
            message.update(extra)
            send(message)
        def account(email):
            return {'account':{'type':'chatgpt','email':email,'planType':'plus'}, 'requiresOpenaiAuth':False}
        def limits(percent):
            return {'rateLimits':{'limitId':'codex','primary':{'usedPercent':percent,'windowDurationMins':300,'resetsAt':4102444800},'secondary':None}}
        with open(os.path.splitext(__file__)[0] + '.requests', 'w', buffering=1) as log:
            for line in sys.stdin:
                request = json.loads(line)
                log.write(json.dumps(request) + '\\n')
                method = request.get('method')
                if method == 'initialized':
                    continue
                if method == 'initialize':
                    result = {'userAgent':'synthetic-race-fixture'}
                elif method == 'account/read':
                    account_reads += 1
                    if account_reads == 1:
                        if mode == 'early':
                            notice({'params':{'authMode':'apikey'}})
                            notice({'params':{'authMode':'chatgpt'}})
                            notice({'params':None})
                        result = account('first@example.invalid')
                    else:
                        if mode == 'hang':
                            time.sleep(5)
                        if mode == 'repeated':
                            notice({'params':{'authMode':'chatgpt'}})
                        if mode == 'no-account':
                            result = {'account':None}
                        elif mode == 'wrong-account':
                            result = {'account':{'type':'apiKey'}}
                        else:
                            result = account('second@example.invalid' if mode == 'changed' else 'first@example.invalid')
                elif method == 'account/rateLimits/read':
                    limit_reads += 1
                    if limit_reads == 1 and mode != 'early':
                        # Close stdin first: confirmation writes must not kill the test process.
                        if mode == 'exit':
                            os.close(0)
                        notice(update)
                    result = limits(19 if limit_reads == 1 else 73)
                else:
                    sys.exit(91)
                send({'jsonrpc':'2.0','id':request['id'],'result':result})
                if mode == 'exit' and method == 'account/rateLimits/read':
                    os._exit(0)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, requests)
    }

    private static func methods(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { line in
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard let method = value["method"] as? String else { fatalError("request missing method") }
            return method
        }
    }

    // Fixtures are Python scripts: a loaded machine can take over a second to start
    // one, so only the hang case relies on the deadline and it still ends well
    // before the fixture's 5 s sleep.
    private static func fails(_ executable: URL, timeout: TimeInterval = 10) -> CodexUsageError {
        do {
            _ = try CodexClient(executable: executable, timeout: timeout).fetch()
            fatalError("expected typed failure")
        } catch {
            guard let typed = error as? CodexUsageError else { fatalError("untyped failure: \(error)") }
            return typed
        }
    }

    private static func clientRaces(root: URL) throws {
        let early = try fixture(root: root, mode: "early")
        let earlySnapshot = try CodexClient(executable: early.0, timeout: 10).fetch()
        check(earlySnapshot.accountLabel?.contains("first@example.invalid") == true, "early updates preserve account")
        check(earlySnapshot.buckets.first?.primary?.usedPercent == 19, "early updates preserve limits")
        let earlyMethods = try methods(early.1)
        check(earlyMethods == initial, "updates before account response never cause extra reads")

        // Fixed update-input matrix, 11 cases; no random seed or network dependency.
        let updates = [
            #"{"params":{"authMode":"chatgpt"}}"#, #"{"params":{"authMode":null}}"#,
            #"{"params":{}}"#, #"{"params":{"authMode":true}}"#,
            #"{"params":{"authMode":42}}"#, #"{"params":{"authMode":[]}}"#,
            #"{"params":{"authMode":{}}}"#, #"{"params":null}"#,
            #"{"params":[]}"#, #"{"params":"bad"}"#, #"{}"#
        ]
        for update in updates {
            let same = try fixture(root: root, mode: "same", update: update)
            let snapshot = try CodexClient(executable: same.0, timeout: 10).fetch()
            check(snapshot.accountLabel?.contains("first@example.invalid") == true, "confirmation preserves same email: \(update)")
            check(snapshot.buckets.count == 1 && snapshot.buckets[0].primary?.usedPercent == 19,
                  "same email returns first limits: \(update)")
            let sameMethods = try methods(same.1)
            check(sameMethods == initial + ["account/read"], "exactly one extra account/read: \(update)")
        }
        let changed = try fixture(root: root, mode: "changed")
        let switched = try CodexClient(executable: changed.0, timeout: 10).fetch()
        check(switched.accountLabel?.contains("second@example.invalid") == true, "new email supplies account label")
        check(switched.accountLabel?.contains("first@example.invalid") != true, "old email is absent")
        check(switched.buckets.count == 1 && switched.buckets[0].primary?.usedPercent == 73, "new email uses only second limits")
        let changedMethods = try methods(changed.1)
        check(changedMethods == initial + ["account/read", "account/rateLimits/read"], "changed account reads limits exactly twice")

        for mode in ["no-account", "wrong-account", "apikey", "repeated"] {
            let update = mode == "apikey" ? #"{"params":{"authMode":"apikey"}}"# : updates[0]
            let sample = try fixture(root: root, mode: mode, update: update)
            let error = fails(sample.0)
            if mode == "repeated" {
                if case .protocolFailure = error {} else { fatalError("second update must be protocolFailure") }
            } else {
                if case .signIn = error {} else { fatalError("\(mode) must require sign-in") }
            }
            let sampleMethods = try methods(sample.1)
            check(sampleMethods == initial + (mode == "apikey" ? [] : ["account/read"]),
                  "failure has bounded read-only request sequence: \(mode)")
        }
        let hung = try fixture(root: root, mode: "hang")
        let started = Date()
        let timeout = fails(hung.0, timeout: 2)
        if case .timeout = timeout {} else { fatalError("confirmation hang must time out") }
        check(Date().timeIntervalSince(started) < 4, "confirmation shares bounded fetch deadline and cleanup")
        let hungMethods = try methods(hung.1)
        check(hungMethods == initial + ["account/read"], "hang does not retry confirmation")

        for _ in 0..<4 {
            let exited = try fixture(root: root, mode: "exit")
            let error = fails(exited.0)
            if case .signIn = error { fatalError("closed confirmation pipe is not a sign-out") }
            let exitedMethods = try methods(exited.1)
            check(exitedMethods == initial, "child exits immediately after first limits response")
        }
        check(true, "test process survived all closed-pipe confirmation writes")
    }

    private static func settle(_ manager: CodexUsageManager) {
        let deadline = Date().addingTimeInterval(3)
        while manager.isLoading && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(!manager.isLoading, "manager publication completes within three seconds")
    }

    private static func managerTransitions() {
        let suite = "LimitFuel.Acceptance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "usage_notifications_enabled")
        let snapshot = CodexSnapshot(accountLabel: "first@example.invalid", buckets: [
            CodexBucket(id: "codex", name: "codex", primary: CodexWindow(usedPercent: 19,
                        windowDurationMins: 300, resetsAt: nil), secondary: nil)
        ])
        let outcomes = RaceFetchFixture([.success(snapshot), .failure(CodexUsageError.protocolFailure),
                                         .failure(CodexUsageError.signIn)])
        var notifications = 0
        let manager = CodexUsageManager(fetcher: { try outcomes.fetch() }, notificationsEnabled: { false },
                                        notify: { _, _ in notifications += 1 })
        manager.fetchUsage(); settle(manager)
        let retained = manager.menuBarDisplayOptions
        check(!retained.isEmpty && retained == snapshot.menuBarOptions && !manager.menuBarIsStale,
              "validated success publishes fresh menu values")
        manager.fetchUsage(); settle(manager)
        check(manager.menuBarDisplayOptions == retained && manager.menuBarIsStale,
              "confirmation protocol failure retains validated menu options as stale")
        manager.fetchUsage(); settle(manager)
        check(manager.menuBarDisplayOptions.isEmpty, "real sign-out clears retained values")
        check(outcomes.exhausted && notifications == 0, "three explicit fetches; no implicit retries or alerts")
    }

    static func main() throws {
        let base = ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("LimitFuel.Acceptance.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try clientRaces(root: root)
        managerTransitions()
        print("CodexAccountRaceTests passed")
    }
}
