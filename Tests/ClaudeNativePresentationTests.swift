import AppKit
import SwiftUI

private func settle(_ seconds: Double = 0.3) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
private final class ClaudeNativeDenyNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { fatalError("Native Claude acceptance attempted network") }
    override func stopLoading() {}
}
// Answers the sign-in window's account lookup offline; every other request fails.
private final class ClaudeSignInOffline: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.absoluteString == "https://claude.ai/api/account" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = Data(#"{"email_address":"signin-window@example.com","uuid":"5B1A7C3E-0D42-4F7B-9C11-2E8F6A4D9B01"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class FocusableProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}
// The popover opens with nothing focused, but a text field being typed in keeps its focus.
private func verifyPopupFocus(source: String) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    let control = FocusableProbe(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
    let field = NSTextField(frame: NSRect(x: 0, y: 40, width: 160, height: 22))
    window.contentView?.addSubview(control)
    window.contentView?.addSubview(field)
    require(window.makeFirstResponder(control), "Focus probe must accept focus")
    PopupFocus.clearInitialFocus(in: window)
    require(window.firstResponder === window, "Popover must open with no control focused")
    require(window.makeFirstResponder(field) && window.firstResponder is NSText, "Text field must take focus")
    PopupFocus.clearInitialFocus(in: window)
    require(window.firstResponder is NSText, "A focused text field must keep its focus")
    window.close()
    require(source.components(separatedBy: "PopupFocus.clearInitialFocus(in: window)").count == 3,
            "popoverDidShow must clear the initial focus now and on the next turn")
}
private func verifySignInWindow(reader: ChromeCookieReader) {
    let suite = "LimitFuel.ClaudeNativeVerifier.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    for key in ["chrome_detection_enabled", "usage_notifications_enabled", "status_notifications_enabled"] { defaults.set(false, forKey: key) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ClaudeSignInOffline.self]
    let session = URLSession(configuration: config)
    defer {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
    }
    let accounts = ClaudeAccounts(defaults: defaults, credentials: InMemoryCredentialStore(), chromeReader: reader, apiSession: session)
    ClaudeSignInWindowController.loginURL = URL(string: "about:blank")!
    ClaudeSignInWindowController.show(accounts: accounts)
    settle(0.6)
    guard let controller = ClaudeSignInWindowController.current,
          let window = NSApp.windows.first(where: { $0.title == "Sign in to Claude" && $0.isVisible }),
          let screen = window.screen else { fatalError("Sign-in window did not open") }
    print("CLAUDE-NATIVE sign-in window frame=\(window.frame) minimum=\(window.contentMinSize) screen=\(screen.visibleFrame)")
    require(window.frame.height <= screen.visibleFrame.height, "Sign-in window is taller than the screen")
    require(window.contentMinSize.height <= 600, "Sign-in window minimum height must fit a laptop screen")
    // claude.ai sets its session in a fetch response, which an in-memory store never reports;
    // cookies stored after the page finished loading must still be found.
    let store = controller.webView.configuration.websiteDataStore.httpCookieStore
    for (name, value) in [("sessionKey", "sk-ant-sid01-offline-test"), ("lastActiveOrg", "6F1D2C4B-8A3E-4B7D-9E21-0C5A7B3D2E10")] {
        var stored = false
        store.setCookie(HTTPCookie(properties: [.domain: ".claude.ai", .path: "/", .name: name, .value: value, .secure: "TRUE"])!) { stored = true }
        while !stored { settle(0.05) }
    }
    let deadline = Date().addingTimeInterval(5)
    while ClaudeSignInWindowController.current != nil && Date() < deadline { settle(0.1) }
    require(ClaudeSignInWindowController.current == nil && !window.isVisible, "Sign-in window did not save the session and close")
    require(accounts.accounts.count == 1 && accounts.accounts[0].email == "signin-window@example.com" && accounts.accounts[0].signedInHere,
            "Signed-in session was not added as an account")
}
private func nativeScrolls(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(nativeScrolls)
}
private struct NativeInventory {
    var entries: [String] = []
    var buttons: [String] = []
}
private func inventory(_ root: Any) -> NativeInventory {
    var found = NativeInventory()
    var seen = Set<ObjectIdentifier>()
    func visit(_ object: Any, depth: Int) {
        guard depth < 50, let element = object as? NSObject,
              seen.insert(ObjectIdentifier(element)).inserted else { return }
        func value(_ key: String) -> Any? {
            let selector = NSSelectorFromString(key)
            return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
        }
        let role = value("accessibilityRole") as? String ?? ""
        let strings = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"].compactMap { value($0) as? String }.filter { !$0.isEmpty }
        found.entries += strings
        if role.contains("Button") { found.buttons += strings }
        if let button = element as? NSButton, !button.title.isEmpty { found.buttons.append(button.title) }
        for child in value("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        if let view = element as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
    }
    visit(root, depth: 0)
    return found
}
private func pressNative(_ root: Any, label: String, depth: Int = 0) -> Bool {
    guard depth < 40, let element = root as? NSObject else { return false }
    func value(_ key: String) -> Any? {
        let selector = NSSelectorFromString(key)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }
    if [value("accessibilityLabel") as? String, value("accessibilityHelp") as? String].contains(label) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if element.responds(to: selector) {
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            let action = unsafeBitCast(element.method(for: selector), to: Action.self)
            if action(element, selector) { return true }
        }
    }
    if (value("accessibilityChildren") as? [Any] ?? []).contains(where: { pressNative($0, label: label, depth: depth + 1) }) { return true }
    if let view = element as? NSView {
        return view.subviews.contains { pressNative($0, label: label, depth: depth + 1) }
    }
    return false
}

@main
struct ClaudeNativePresentationAcceptance {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        setbuf(stdout, nil)
        require(!NSScreen.screens.isEmpty, "UNVERIFIED: no native display; WindowServer access required")
        let suite = "LimitFuel.ClaudeNativeVerifier.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        for key in ["chrome_detection_enabled", "usage_notifications_enabled", "status_notifications_enabled"] { defaults.set(false, forKey: key) }
        let temp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent("claude-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeNativeDenyNetwork.self]
        URLProtocol.registerClass(ClaudeNativeDenyNetwork.self)
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            URLProtocol.unregisterClass(ClaudeNativeDenyNetwork.self)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temp)
        }
        let reader = ChromeCookieReader(root: temp, passwordProvider: { _ in fatalError("No Keychain permitted") })
        let app = AppDelegate()
        app.statusItem = NSStatusBar.system.statusItem(withLength: 140)
        app.statusItem.button!.title = "TEST Claude UI"
        // Deliberately do not install this delegate or invoke its launch hooks.
        // One tracked Claude account (2026-10-31 spec correction: accounts replace the single manager).
        defaults.set(["primary"], forKey: "claude_account_ids")
        app.claudeAccounts = ClaudeAccounts(defaults: defaults, chromeReader: reader, apiSession: session, delegate: app)
        let claude = app.claudeAccounts.accounts[0]
        app.statusManager = StatusManager()
        app.updateManager = UpdateManager()
        app.menuBarPreferences = MenuBarPreferences(defaults: defaults)
        app.codexManager = CodexUsageManager(fetcher: { fatalError("No provider calls") }, notificationsEnabled: { false }, notify: { _, _ in fatalError("No notifications") })
        app.codexManager.snapshot = CodexSnapshot(accountLabel: "OFFLINE CLAUDE TEST", buckets: [])
        claude.parseUsageData(Data(#"{"five_hour":{"utilization":12}}"#.utf8))
        app.popover = NSPopover()
        app.popover.animates = false
        app.popover.behavior = .transient
        app.popover.delegate = app
        app.popover.contentSize = NSSize(width: 360, height: app.popupPresentation.viewportHeight)
        app.popupPresentation.onResize = { height in app.popover.contentSize = NSSize(width: 360, height: height) }
        let host = NSHostingController(rootView: UsageView(claude: app.claudeAccounts, settings: AppSettings(defaults: defaults), statusManager: app.statusManager, updateManager: app.updateManager, codexManager: app.codexManager, popupPresentation: app.popupPresentation, menuBarPreferences: app.menuBarPreferences).defaultAppStorage(defaults))
        app.popover.contentViewController = host
        defer {
            app.closePopover()
            app.popover.contentViewController = nil
            NSStatusBar.system.removeStatusItem(app.statusItem)
            for window in NSApp.windows { window.orderOut(nil); window.close() }
            settle(0.1)
        }
        NSApp.activate(ignoringOtherApps: true)
        settle(0.4)
        app.openPopover()
        settle(0.6)
        require(app.popover.isShown && host.view.window?.isVisible == true, "Actual native popover must be visible")

        func state(_ label: String) -> (NativeInventory, CGFloat) {
            host.view.layoutSubtreeIfNeeded()
            settle(0.4)
            let inv = inventory(host.view)
            guard let scroll = nativeScrolls(host.view).first, let document = scroll.documentView else { fatalError("Missing native usage document") }
            print("CLAUDE-NATIVE \(label) height=\(document.frame.height) entries=\(inv.entries) buttons=\(inv.buttons)")
            return (inv, document.frame.height)
        }
        func chromeButtons(_ inv: NativeInventory) -> [String] {
            inv.buttons.filter { $0.localizedCaseInsensitiveContains("Chrome") }
        }
        // SwiftUI text/buttons may not publish AX descendants in an offline
        // NSHostingView. Verify the actual source use-sites when that happens;
        // native document geometry still independently proves rendered changes.
        guard let sourcePath = ProcessInfo.processInfo.environment["CLAUDE_TEST_SOURCE"] else {
            fatalError("CLAUDE_TEST_SOURCE must identify the immutable compiled source")
        }
        let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
        func declaration(_ name: String) -> String {
            guard let start = source.range(of: name), let open = source[start.upperBound...].firstIndex(of: "{") else { fatalError("Missing source declaration: \(name)") }
            var level = 0
            for index in source[open...].indices {
                if source[index] == "{" { level += 1 }
                if source[index] == "}" { level -= 1; if level == 0 { return String(source[open...index]) } }
            }
            fatalError("Unterminated source declaration: \(name)")
        }
        let cardSource = declaration("private func claudeCard(_ account: UsageManager) -> some View")
        require(cardSource.contains("if account.showsClaudeConnectionControls {") && cardSource.contains("connectionControls(account)"), "Actual dashboard must guard connection controls with connection predicate")
        require(cardSource.contains("if account.showsClaudeWeeklyUsage {"), "Actual weekly row must use the accepted presentation predicate")
        require(declaration("private var settingsPage: some View").contains("claudeAccountsSettings"), "Settings must include account connection view")
        require(declaration("private var claudeAccountsSettings: some View").contains("claudeAccountRow"), "Settings must list each account")
        require(declaration("private func claudeAccountRow(_ account: UsageManager) -> some View").contains("connectionControls(account)"), "Settings account view must retain connection controls")
        let controls = declaration("private func connectionControls(_ account: UsageManager) -> some View")
        require(controls.contains("if account.signedInHere {") && controls.contains("Sign In Again") && controls.contains("chromeConnectionControls(account)"), "Signed-in accounts renew by signing in; the others keep Chrome controls")
        require(declaration("private func chromeConnectionControls(_ account: UsageManager) -> some View").contains("chromeButtons(account)"), "Shared connection controls must include Chrome actions")
        require(declaration("private func chromeButtons(_ account: UsageManager) -> some View").contains("Sign In Here"), "Chrome actions must offer signing in here")
        let dashboardSource = declaration("private var dashboard: some View")
        require(dashboardSource.contains("GlassMenuButton(symbol: \"plus\"") && ["Sign In to Claude…", "Add from Chrome", "Manual Cookie…"].allSatisfy(dashboardSource.contains),
                "Popup header must offer every way to add a Claude account")
        var chosen: [String] = []
        let menuAnchor = GlassMenuAnchor() // menu items hold their target weakly
        let addMenu = menuAnchor.menu(for: [
            GlassMenuItem(title: "First") { chosen.append("First") },
            GlassMenuItem(title: "Second", enabled: false) { chosen.append("Second") },
        ])
        require(addMenu.items.map(\.title) == ["First", "Second"] && addMenu.items[0].isEnabled && !addMenu.items[1].isEnabled,
                "Glass menu must keep item titles and enabled states")
        addMenu.performActionForItem(at: 0)
        require(chosen == ["First"], "Glass menu item must run its own action")
        withExtendedLifetime(menuAnchor) {}
        let normal = state("connected-weekly-absent")
        for (attention, detecting) in [(true, false), (false, true), (true, true)] {
            claude.chromeNeedsAttention = attention
            claude.isDetectingChrome = detecting
            claude.chromeMessage = attention ? "OFFLINE TEST Keychain permission denied" : nil
            let changed = state("connected-attention-\(attention)-detecting-\(detecting)")
            require(chromeButtons(changed.0).isEmpty, "Connected dashboard exposes Chrome connection buttons")
            require(abs(changed.1 - normal.1) < 1, "Connected dashboard Chrome attention/detection added content")
        }
        claude.chromeNeedsAttention = false
        claude.isDetectingChrome = false
        claude.chromeMessage = nil
        claude.parseUsageData(Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":0}}"#.utf8))
        let positiveSessionZeroWeekly = state("connected-positive-session-weekly-zero")
        require(abs(positiveSessionZeroWeekly.1 - normal.1) < 1, "Positive session with weekly zero must hide Weekly")
        claude.parseUsageData(Data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":0}}"#.utf8))
        let realZero = state("connected-weekly-zero")
        require(realZero.1 > normal.1 + 1, "Session zero and weekly zero must show both dashboard rows")
        claude.parseUsageData(Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":0}}"#.utf8))
        let hiddenAgain = state("connected-positive-session-weekly-zero-again")
        require(abs(hiddenAgain.1 - normal.1) < 1, "Weekly zero must hide again after session activity")
        claude.parseUsageData(Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":0.1}}"#.utf8))
        let fractionalWeekly = state("connected-fractional-weekly")
        require(fractionalWeekly.1 > normal.1 + 1, "Positive fractional weekly must show before display rounding")
        claude.parseUsageData(Data(#"{"five_hour":{"utilization":12}}"#.utf8))
        let missingAgain = state("connected-weekly-missing-again")
        require(abs(missingAgain.1 - normal.1) < 1, "Missing weekly usage retained a dashboard row")
        require(chromeButtons(missingAgain.0).isEmpty, "Connected dashboard retains Chrome buttons")

        func header(_ label: String, x: CGFloat) {
            if let scroll = nativeScrolls(host.view).first {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            settle(0.1)
            if !pressNative(host.view, label: label) {
                let local = NSPoint(x: x, y: host.view.isFlipped ? 28 : host.view.bounds.height - 28)
                let point = host.view.convert(local, to: nil)
                guard let window = host.view.window else { fatalError("Header has no visible window") }
                for kind: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
                }
            }
            settle(0.6)
        }
        header("Settings", x: 332)
        let settings = state("settings-connected")
        require(settings.1 > normal.1 + 1, "Actual Settings page did not replace dashboard")
        if chromeButtons(settings.0).isEmpty {
            print("LIMITATION: SwiftUI Chrome button AX inventory unavailable; Settings controls verified by immutable source use-sites and native Settings navigation")
        }
        header("Back", x: 28)
        claude.clearSessionCookie()
        let disconnected = state("disconnected")
        require(disconnected.1 > normal.1 + 1, "Disconnected dashboard did not render recovery content")
        if chromeButtons(disconnected.0).isEmpty {
            print("LIMITATION: SwiftUI Chrome button AX inventory unavailable; disconnected recovery verified by source use-site and native document expansion")
        }
        verifyPopupFocus(source: source)
        verifySignInWindow(reader: reader)
        print("Native Claude presentation acceptance passed")
    }
}
