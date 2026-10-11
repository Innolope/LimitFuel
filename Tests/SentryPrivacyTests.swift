import Foundation
import Sentry
import zlib

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
private final class OfflineProtocol: URLProtocol {
    static let started = DispatchSemaphore(value: 0)
    static let stopped = DispatchSemaphore(value: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.signal() }
    override func stopLoading() { Self.stopped.signal() }
}

private final class EnvelopeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body: Data?
    static var captured: Data? { lock.lock(); defer { lock.unlock() }; return body }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable && data.count <= 1_048_576 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock(); Self.body = data; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct SentryPrivacyAcceptance {
    static func main() throws {
        let secret = "PRIVATE_SECRET_user@example.com_token"
        let event = Event(level: .fatal)
        event.message = SentryMessage(formatted: secret)
        event.user = User(userId: secret)
        event.extra = ["cookie": secret]
        event.context = ["account": ["organization": secret]]
        event.serverName = secret
        event.transaction = secret
        event.logger = secret
        event.modules = [secret: secret]
        event.tags = ["email": secret]
        event.fingerprint = [secret]
        let request = SentryRequest()
        request.url = secret
        request.headers = ["Authorization": secret]
        event.request = request
        let breadcrumb = Breadcrumb()
        breadcrumb.message = secret
        event.breadcrumbs = [breadcrumb]
        let frame = Frame()
        frame.function = "LimitFuel.refreshUsage()"
        frame.fileName = "/Users/\(secret)/main.swift"
        frame.package = secret
        frame.module = secret
        frame.contextLine = secret
        frame.preContext = [secret]
        frame.postContext = [secret]
        frame.vars = ["token": secret]
        frame.instructionAddress = "0x123ABC"
        frame.imageAddress = "0x100000"
        let stack = SentryStacktrace(frames: [frame], registers: ["rax": secret])
        let exception = Exception(value: secret, type: "EXC_BAD_ACCESS")
        exception.stacktrace = stack
        exception.module = secret
        event.exceptions = [exception]
        event.stacktrace = stack
        let thread = SentryThread(threadId: 1)
        thread.name = secret
        thread.stacktrace = stack
        event.threads = [thread]
        let image = DebugMeta()
        image.codeFile = secret
        event.debugMeta = [image]
        let clean = SentryDiagnostics.sanitize(event)!
        let payload = String(data: try JSONSerialization.data(withJSONObject: clean.serialize()), encoding: .utf8)!
        check(!payload.contains(secret), "synthetic secret leaked")
        check(payload.contains("LimitFuel.refreshUsage()"), "useful native symbol retained")
        check(payload.contains("0x123ABC"), "native address retained")
        check(clean.eventId == event.eventId, "safe event ID remains stable")
        check(clean.request == nil && clean.user == nil && clean.extra == nil && clean.context == nil, "private scopes stripped")
        check(clean.debugMeta == nil && clean.breadcrumbs == nil && clean.exceptions?.first?.value == nil, "crash and log data stripped")
        for bad in [secret, "0x123nothex", "0x", "0x" + String(repeating: "F", count: 17)] {
            frame.instructionAddress = bad
            frame.function = "/Users/\(secret)"
            let sanitized = SentryDiagnostics.sanitize(event)!
            check(sanitized.stacktrace?.frames.first?.instructionAddress == nil, "invalid address dropped")
            check(sanitized.stacktrace?.frames.first?.function == nil, "path-like symbol dropped")
        }
        for provider in DiagnosticProvider.allCases {
            for code in DiagnosticErrorCode.allCases {
                event.tags = ["provider": provider.rawValue, "code": code.rawValue, "secret": secret]
                let sanitized = SentryDiagnostics.sanitize(event)!
                check(sanitized.tags == ["provider": provider.rawValue, "code": code.rawValue], "only fixed tags retained")
                check(sanitized.exceptions == nil && sanitized.threads == nil, "connection error has no stack or memory")
            }
        }
        check(SentryDiagnostics.sanitize(Event()) == nil, "arbitrary messages cannot send")

        let root = URL(fileURLWithPath: "/private/tmp/limitfuel-sentry-privacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var starts: [Options] = []
        var closed = 0
        let backend = SentryDiagnostics(dsn: "https://public@o1.ingest.sentry.io/1", cacheURL: root,
            startSDK: { starts.append($0) }, closeSDK: { closed += 1 }, sessionFactory: { config in
                config.protocolClasses = [OfflineProtocol.self]
                return URLSession(configuration: config)
            })
        backend.setEnabled(true)
        check(starts.count == 1, "configured startup")
        let options = starts[0]
        backend.setEnabled(false, permitted: { false })
        check(closed == 0 && options.beforeSend?(event) != nil, "obsolete policy update cannot disable a newer generation")
        check(!options.sendDefaultPii && !options.enableMemoryIntrospection && !options.enableLogs, "private memory and logs off")
        check(!options.enableAutoSessionTracking && !options.sendClientReports && !options.enableMetrics, "non-error telemetry off")
        check(!options.enableNetworkTracking && !options.enableNetworkBreadcrumbs && !options.enableCaptureFailedRequests, "request telemetry off")
        check(!options.enableSwizzling && !options.enableAutoPerformanceTracing && options.configureProfiling == nil, "instrumentation off")
        check(!options.enableMetricKit && !options.enableAutoBreadcrumbTracking && options.maxBreadcrumbs == 0, "ambient telemetry off")
        check(options.shutdownTimeInterval == 0, "close never waits for flush")
        check(options.beforeSend?(event) != nil, "live generation accepts sanitized event")
        try FileManager.default.createDirectory(atPath: options.cacheDirectoryPath, withIntermediateDirectories: true)
        try Data(secret.utf8).write(to: URL(fileURLWithPath: options.cacheDirectoryPath).appendingPathComponent("queued"))
        let task = options.urlSession!.dataTask(with: URL(string: "https://offline.invalid/test")!)
        task.resume()
        check(OfflineProtocol.started.wait(timeout: .now() + 2) == .success, "offline upload started")
        backend.setEnabled(false)
        check(closed == 1 && OfflineProtocol.stopped.wait(timeout: .now() + 2) == .success, "opt-out cancels session and closes SDK")
        check(options.beforeSend?(event) == nil, "old callback drops after opt-out")
        check(!FileManager.default.fileExists(atPath: root.path), "dedicated cache removed")
        backend.setEnabled(true)
        check(starts.count == 2 && starts[1].cacheDirectoryPath != options.cacheDirectoryPath, "re-enable isolates late writes")
        check(options.beforeSend?(event) == nil, "old generation stays disabled after re-enable")
        backend.setEnabled(false)
        let unconfigured = SentryDiagnostics(dsn: "", cacheURL: root, startSDK: { _ in fatalError("missing DSN must not start") })
        unconfigured.setEnabled(true)
        check(unconfigured.statusText.contains("unavailable"), "missing DSN is visible")
        for invalid in ["http://public@o1.ingest.sentry.io/1", "https://public:secret@o1.ingest.sentry.io/1", "https://public@evil.example/1"] {
            check(!SentryDiagnostics.validDSN(invalid), "unsafe DSN rejected")
        }
        try queuedOptOut()
        try concurrentOptOut()
        try realSDKEnvelope()
        print("Sentry privacy and lifecycle acceptance passed (offline)")
    }
    static func queuedOptOut() throws {
        let suite = "LimitFuel.Privacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let wrong = DispatchSemaphore(value: 0)
        let policy = AppDiagnostics(defaults: defaults, transport: { event in
            if event.provider == .claude { first.signal(); _ = release.wait(timeout: .now() + 2) }
            else { wrong.signal() }
        })
        policy.recordFailure(provider: .claude, code: .timeout)
        check(first.wait(timeout: .now() + 2) == .success, "first upload stalled")
        policy.recordFailure(provider: .codex, code: .timeout)
        policy.setEnabled(false)
        policy.setEnabled(true)
        release.signal()
        check(wrong.wait(timeout: .now() + 0.1) == .timedOut, "queued pre-optout failure never sends")
    }
    // Regression from the independent verifier: worker opt-out blocked on main
    // must survive a newer main-thread enable that overtakes its teardown.
    static func concurrentOptOut() throws {
        let root = URL(fileURLWithPath: "/private/tmp/limitfuel-sentry-concurrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var starts: [Options] = []
        let backend = SentryDiagnostics(dsn: "https://public@o1.ingest.sentry.io/1", cacheURL: root,
                                       startSDK: { starts.append($0) }, closeSDK: {})
        backend.setEnabled(true)
        let event = Event(level: .error)
        event.tags = ["provider": "claude", "code": "timeout"]
        let first = starts[0]
        try FileManager.default.createDirectory(atPath: first.cacheDirectoryPath, withIntermediateDirectories: true)
        let cached = URL(fileURLWithPath: first.cacheDirectoryPath).appendingPathComponent("queued")
        try Data("synthetic-event".utf8).write(to: cached)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { backend.setEnabled(false); finished.signal() }
        let deadline = Date().addingTimeInterval(2)
        while first.beforeSend?(event) != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        check(first.beforeSend?(event) == nil, "worker revoked old callback")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("generation").path), "revocation persists before blocked teardown")
        backend.setEnabled(true)
        let end = Date().addingTimeInterval(2)
        var workerFinished = false
        while Date() < end {
            if finished.wait(timeout: .now()) == .success { workerFinished = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(workerFinished, "background opt-out completes")
        check(starts.last!.cacheDirectoryPath != first.cacheDirectoryPath, "overtaken opt-out still rotates epoch")
        check(!FileManager.default.fileExists(atPath: cached.path), "overtaken opt-out still purges old reports")
        backend.setEnabled(false)
    }
    static func realSDKEnvelope() throws {
        let root = URL(fileURLWithPath: "/private/tmp/limitfuel-sentry-envelope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SentryDiagnostics(dsn: "https://public@o1.ingest.sentry.io/1", cacheURL: root,
            startSDK: { SentrySDK.start(options: $0) }, closeSDK: { SentrySDK.close() },
            sessionFactory: { configuration in
                configuration.protocolClasses = [EnvelopeProtocol.self]
                return URLSession(configuration: configuration)
            })
        backend.setEnabled(true)
        check(SentrySDK.isEnabled, "real SDK starts on main")
        // Let SDK integrations install before exercising the complete send pipeline.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        SentrySDK.configureScope { scope in
            scope.setUser(User(userId: "SECRET_ACCOUNT@example.com"))
            scope.setExtra(value: "SECRET_COOKIE", key: "cookie")
            scope.setContext(value: ["organization": "SECRET_ORG"], key: "provider")
        }
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "SECRET_MESSAGE")
        let exception = Exception(value: "SECRET_REASON", type: "EXC_BAD_ACCESS")
        let frame = Frame()
        frame.function = "LimitFuel.refreshUsage()"
        frame.fileName = "/Users/SECRET_PATH/test.swift"
        frame.instructionAddress = "0x1234"
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: ["rax": "SECRET_REGISTER"])
        event.exceptions = [exception]
        SentrySDK.capture(event: event)
        let deadline = Date().addingTimeInterval(5)
        while EnvelopeProtocol.captured == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let compressed = EnvelopeProtocol.captured else { fatalError("real SDK never reached offline transport") }
        let envelope = root.appendingPathComponent("captured-envelope.gz")
        try compressed.write(to: envelope)
        guard let stream = gzopen(envelope.path, "rb") else { fatalError("cannot open test envelope") }
        defer { gzclose(stream) }
        var decoded = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = gzread(stream, &buffer, UInt32(buffer.count))
            check(count >= 0, "invalid compressed SDK envelope")
            if count == 0 { break }
            decoded.append(contentsOf: buffer.prefix(Int(count)))
            check(decoded.count <= 1_048_576, "bounded SDK envelope")
        }
        let text = String(data: decoded, encoding: .utf8)!
        check(!text.contains("SECRET"), "SDK post-sanitizer pipeline leaked synthetic secrets")
        for forbidden in ["\"debug_meta\"", "\"user\"", "\"extra\"", "\"request\"", "\"contexts\"", "\"breadcrumbs\""] {
            check(!text.contains(forbidden), "SDK post-sanitizer pipeline added \(forbidden)")
        }
        check(text.contains("LimitFuel.refreshUsage()"), "actual SDK envelope retains useful symbol")
        backend.setEnabled(false)
        check(!SentrySDK.isEnabled, "real SDK closes on opt-out")
        backend.setEnabled(true)
        check(SentrySDK.isEnabled, "real SDK restarts")
        backend.setEnabled(false)
        check(!SentrySDK.isEnabled, "real SDK closes after restart")
    }
}
