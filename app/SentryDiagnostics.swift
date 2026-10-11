import Foundation
import Sentry

/// Owns the only SDK network session, cancelled before SDK close flushes.
final class SentryDiagnostics {
    static let shared = SentryDiagnostics()
    private let lock = NSLock()
    // SDK start/close require main. Never synchronously wait on a worker that hops back to main.
    private let lifecycle = DispatchQueue.main
    private let dsn: String
    private let cacheURL: URL
    private let startSDK: (Options) -> Void
    private let closeSDK: () -> Void
    private let sessionFactory: (URLSessionConfiguration) -> URLSession
    private var allowed = false
    private var revision: UInt64 = 0
    private var session: URLSession?
    private var running = false
    private var cacheGeneration: String
    private var purgeRequested = false

    init(dsn: String? = nil, cacheURL: URL? = nil,
         startSDK: ((Options) -> Void)? = nil, closeSDK: (() -> Void)? = nil,
         sessionFactory: ((URLSessionConfiguration) -> URLSession)? = nil) {
        self.dsn = dsn ?? Self.bundledDSN()
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.innolope.limitfuel.diagnostics", isDirectory: true)
        let saved = try? String(contentsOf: self.cacheURL.appendingPathComponent("generation"), encoding: .utf8)
        self.cacheGeneration = saved.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        self.sessionFactory = sessionFactory ?? {
            URLSession(configuration: $0, delegate: DiagnosticsRedirectBlocker(), delegateQueue: nil)
        }
        #if ACCEPTANCE_TESTS
        self.startSDK = startSDK ?? { _ in }
        self.closeSDK = closeSDK ?? {}
        #else
        self.startSDK = startSDK ?? { SentrySDK.start(options: $0) }
        self.closeSDK = closeSDK ?? { SentrySDK.close() }
        #endif
    }
    var statusText: String {
        guard Self.validDSN(dsn) else { return "Error reporting is unavailable: the Sentry project is not configured." }
        lock.lock(); defer { lock.unlock() }
        return allowed ? "Crash and connection error reporting is on." : "Error reporting is off."
    }
    private static func bundledDSN() -> String {
        guard let url = Bundle.main.url(forResource: "Diagnostics", withExtension: "plist"),
              let values = NSDictionary(contentsOf: url) else { return "" }
        return values["SentryDSN"] as? String ?? ""
    }
    static func validDSN(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              let host = parts.host, host.hasSuffix(".ingest.sentry.io") || host.hasSuffix(".ingest.us.sentry.io") || host.hasSuffix(".ingest.de.sentry.io"),
              let key = parts.user, !key.isEmpty, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port == nil else { return false }
        return parts.path.range(of: "^/[0-9]+$", options: .regularExpression) != nil
    }
    func setEnabled(_ enabled: Bool, permitted: () -> Bool = { true }) {
        lock.lock()
        guard permitted() else { lock.unlock(); return }
        allowed = enabled && Self.validDSN(dsn)
        revision &+= 1
        let current = revision
        if !enabled {
            // Revoke before the main-thread hop. A newer enable must still purge,
            // and a crash between off/on and teardown must not restore the old epoch.
            cacheGeneration = UUID().uuidString
            purgeRequested = true
            try? FileManager.default.removeItem(at: cacheURL.appendingPathComponent("generation"))
        }
        let previous = session
        session = nil
        lock.unlock()
        previous?.invalidateAndCancel()
        let update = {
            self.lock.lock(); let latest = self.revision == current; self.lock.unlock()
            guard latest else { return }
            self.updateLifecycle(enabled: enabled, current: current)
        }
        if Thread.isMainThread { update() } else { lifecycle.sync(execute: update) }
    }
    private func updateLifecycle(enabled: Bool, current: UInt64) {
            lock.lock()
            let purge = purgeRequested
            purgeRequested = false
            let generationName = cacheGeneration
            lock.unlock()
            if running { closeSDK(); running = false }
            if purge {
                try? FileManager.default.removeItem(at: cacheURL)
            }
            lock.lock()
            let shouldStart = allowed && revision == current
            lock.unlock()
            guard shouldStart else { return }
            lock.lock()
            guard allowed && revision == current else { lock.unlock(); return }
            do {
                try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try generationName.write(to: cacheURL.appendingPathComponent("generation"), atomically: true, encoding: .utf8)
            } catch {
                allowed = false
                lock.unlock()
                return
            }
            lock.unlock()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let newSession = sessionFactory(configuration)
            lock.lock()
            guard allowed && revision == current else { lock.unlock(); newSession.invalidateAndCancel(); return }
            session = newSession
            lock.unlock()
            let options = Self.options(dsn: dsn, cacheURL: cacheURL.appendingPathComponent(generationName), session: newSession)
            options.beforeSend = { [weak self] event in
                guard let self else { return nil }
                self.lock.lock()
                let canSend = self.allowed && self.revision == current
                self.lock.unlock()
                return canSend ? Self.sanitize(event) : nil
            }
            startSDK(options)
            running = true
    }
    func capture(_ diagnostic: DiagnosticEvent, permitted: @escaping () -> Bool = { true }) {
        lock.lock(); let current = revision; lock.unlock()
        lifecycle.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let canSend = self.allowed && self.revision == current; self.lock.unlock()
            guard canSend && self.running && permitted() else { return }
            let event = Event(level: .error)
            event.tags = ["provider": diagnostic.provider.rawValue, "code": diagnostic.code.rawValue]
            #if !ACCEPTANCE_TESTS
            SentrySDK.capture(event: event)
            #endif
        }
    }
    static func options(dsn: String, cacheURL: URL, session: URLSession) -> Options {
        let options = Options()
        options.dsn = dsn
        options.urlSession = session
        options.cacheDirectoryPath = cacheURL.path
        options.shutdownTimeInterval = 0
        options.debug = false
        options.sendDefaultPii = false
        options.enableMemoryIntrospection = false
        options.enableCrashHandler = true
        options.enableUncaughtNSExceptionReporting = true
        options.enableLogs = false
        options.beforeSendLog = { _ in nil }
        options.enableMetrics = false
        options.enableAutoSessionTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableAppHangTracking = false
        options.enableMetricKit = false
        options.enableMetricKitRawPayload = false
        options.enableSwizzling = false
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.maxBreadcrumbs = 0
        options.beforeBreadcrumb = { _ in nil }
        options.enableAutoPerformanceTracing = false
        options.enablePersistingTracesWhenCrashing = false
        options.tracesSampleRate = 0
        options.enableNetworkTracking = false
        options.enableCaptureFailedRequests = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.enableGraphQLOperationTracking = false
        options.enableTimeToFullDisplayTracing = false
        options.enablePropagateTraceparent = false
        options.tracePropagationTargets = []
        options.configureProfiling = nil
        options.sendClientReports = false
        options.enableSpotlight = false
        options.maxAttachmentSize = 0
        options.attachStacktrace = false
        options.attachAllThreads = false
        options.maxCacheItems = 20
        options.releaseName = releaseName
        return options
    }
    private static var releaseName: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return "limitfuel@" + (value.range(of: "^[0-9A-Za-z.-]{1,32}$", options: .regularExpression) == nil ? "development" : value)
    }
    /// Construct an allowlisted event: future SDK fields cannot silently widen our payload.
    static func sanitize(_ source: Event) -> Event? {
        let clean = Event(level: source.level == .fatal ? .fatal : .error)
        clean.eventId = source.eventId
        clean.timestamp = source.timestamp
        clean.releaseName = releaseName
        clean.platform = "cocoa"
        if let provider = source.tags?["provider"], DiagnosticProvider(rawValue: provider) != nil,
           let code = source.tags?["code"], DiagnosticErrorCode(rawValue: code) != nil {
            clean.tags = ["provider": provider, "code": code]
            clean.message = SentryMessage(formatted: "Connection error")
            clean.fingerprint = ["connection", provider, code]
            return clean
        }
        guard !(source.exceptions ?? []).isEmpty else { return nil }
        clean.exceptions = (source.exceptions ?? []).prefix(8).map { original in
            let knownTypes: Set<String> = ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_BREAKPOINT", "EXC_CRASH", "SIGABRT", "SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException"]
            let exception = Exception(value: nil, type: knownTypes.contains(original.type ?? "") ? original.type : "NativeCrash")
            exception.stacktrace = sanitizeStack(original.stacktrace)
            exception.threadId = original.threadId
            return exception
        }
        clean.stacktrace = sanitizeStack(source.stacktrace)
        clean.threads = source.threads?.prefix(32).map { original in
            let thread = SentryThread(threadId: original.threadId)
            thread.crashed = original.crashed
            thread.current = original.current
            thread.isMain = original.isMain
            thread.stacktrace = sanitizeStack(original.stacktrace)
            return thread
        }
        return clean
    }
    private static func sanitizeStack(_ source: SentryStacktrace?) -> SentryStacktrace? {
        guard let source else { return nil }
        let frames = source.frames.prefix(256).map { original in
            let frame = Frame()
            if let function = original.function,
               function.range(of: "^[A-Za-z_$][A-Za-z0-9_$.:<>(), +*?&\\[\\]~-]{0,255}$", options: .regularExpression) != nil {
                frame.function = function
            }
            frame.instructionAddress = address(original.instructionAddress)
            frame.imageAddress = address(original.imageAddress)
            frame.symbolAddress = address(original.symbolAddress)
            frame.inApp = original.inApp
            return frame
        }
        return SentryStacktrace(frames: frames, registers: [:])
    }
    private static func address(_ value: String?) -> String? {
        guard let value, value.range(of: "^0x[0-9a-fA-F]{1,16}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

private final class DiagnosticsRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
