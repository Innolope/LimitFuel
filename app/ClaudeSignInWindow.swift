import AppKit
import SwiftUI
import WebKit

/// The claude.ai sign-in window. Every window keeps its website data in memory only, so it
/// starts signed out, never sees Chrome's or another account's sign-in, and leaves nothing
/// on disk: the captured session goes to the Keychain through `ClaudeAccounts`.
final class ClaudeSignInWindowController: NSObject, ObservableObject, NSWindowDelegate,
                                          WKNavigationDelegate, WKUIDelegate {
    enum Phase: Equatable {
        case signingIn
        case saving
        case failed(String)
    }

    private(set) static var current: ClaudeSignInWindowController?
    #if ACCEPTANCE_TESTS
    static var loginURL = URL(string: "https://claude.ai/login")!
    #else
    private static let loginURL = URL(string: "https://claude.ai/login")!
    #endif
    // claude.ai sets lastActiveOrg right after sessionKey; usage can find the org without it.
    private static let organizationGrace: TimeInterval = 5
    // An in-memory cookie store never reports cookies set by a fetch response, and claude.ai
    // finishes signing in with one, so the window checks its cookies on a timer.
    private static let cookieCheckInterval: TimeInterval = 1

    /// Opens the sign-in window, or brings the open one forward.
    static func show(accounts: ClaudeAccounts, expectedEmail: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let current = current {
            current.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ClaudeSignInWindowController(accounts: accounts, expectedEmail: expectedEmail)
        current = controller
        controller.present()
    }

    @Published private(set) var phase: Phase = .signingIn
    @Published private(set) var linkMessage: String?
    let expectedEmail: String?
    let webView: WKWebView
    private weak var accounts: ClaudeAccounts?
    private var window: NSWindow?
    private var popups: [NSWindow] = []
    private var capturedHeader: String?
    private var organizationWait: DispatchWorkItem?
    private var cookieCheck: Timer?
    private var finished = false

    private init(accounts: ClaudeAccounts, expectedEmail: String?) {
        self.accounts = accounts
        self.expectedEmail = expectedEmail
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private var cookieStore: WKHTTPCookieStore { webView.configuration.websiteDataStore.httpCookieStore }

    private func present() {
        let height = min(700, (NSScreen.main?.visibleFrame.height ?? 760) - 60)
        let window = EditingWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: height),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.title = "Sign in to Claude"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ClaudeSignInView(controller: self))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: Self.loginURL))
        let timer = Timer(timeInterval: Self.cookieCheckInterval, repeats: true) { [weak self] _ in
            self?.checkCookies()
        }
        RunLoop.main.add(timer, forMode: .common)
        cookieCheck = timer
    }

    // MARK: Actions

    /// Opens a login link copied from the Claude email here, where the sign-in started.
    func pasteLoginLink() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text), Self.isClaudeLink(url) else {
            linkMessage = "Copy the login link from the Claude email first. Only claude.ai links open here."
            return
        }
        linkMessage = nil
        webView.load(URLRequest(url: url))
    }

    static func isClaudeLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }

    func retry() {
        guard case .failed = phase else { return }
        save()
    }

    /// Forgets this window's sign-in and shows the login page again.
    func startOver() {
        organizationWait?.cancel()
        organizationWait = nil
        capturedHeader = nil
        linkMessage = nil
        phase = .signingIn
        webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            guard let self = self else { return }
            self.webView.load(URLRequest(url: Self.loginURL))
        }
    }

    func cancel() {
        window?.close()
    }

    // MARK: Session capture

    private func checkCookies() {
        guard !finished, phase == .signingIn else { return }
        cookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async { self?.consider(cookies) }
        }
    }

    private func consider(_ cookies: [HTTPCookie]) {
        guard !finished, phase == .signingIn, let header = ClaudeSignInCookies.header(from: cookies) else { return }
        capturedHeader = header
        if ClaudeSessionHeader.value("lastActiveOrg", in: header) != nil {
            save()
        } else if organizationWait == nil {
            let wait = DispatchWorkItem { [weak self] in self?.save() }
            organizationWait = wait
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.organizationGrace, execute: wait)
        }
    }

    private func save() {
        guard !finished, let header = capturedHeader, let accounts = accounts else { return }
        organizationWait?.cancel()
        organizationWait = nil
        phase = .saving
        accounts.completeSignIn(header) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .added, .renewed, .alreadyAdded:
                self.finished = true
                self.window?.close()
            case .failed(let message):
                self.phase = .failed(message)
            }
        }
    }

    // MARK: Web view

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(["https", "about", "blob", "data"].contains(scheme ?? "") ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkCookies()
    }

    // Sign-in providers open popups that report back to the page through window.opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popupView = WKWebView(frame: .zero, configuration: configuration)
        popupView.uiDelegate = self
        let popup = EditingWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.title = "Sign in to Claude"
        popup.contentView = popupView
        if let parent = window {
            popup.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 30, y: parent.frame.maxY - 30))
        } else {
            popup.center()
        }
        popups.append(popup)
        popup.makeKeyAndOrderFront(nil)
        return popupView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let popup = popups.first(where: { $0.contentView === webView }) else { return }
        popup.close()
        popups.removeAll { $0 === popup }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        organizationWait?.cancel()
        organizationWait = nil
        cookieCheck?.invalidate()
        cookieCheck = nil
        webView.stopLoading()
        popups.forEach { $0.close() }
        popups = []
        if Self.current === self { Self.current = nil }
    }
}

/// A menu bar app has no Edit menu, so the standard editing shortcuts are routed here.
private final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: Selector?
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        case (.command, "w"): action = #selector(NSWindow.performClose(_:))
        default: action = nil
        }
        if let action = action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct ClaudeSignInView: View {
    @ObservedObject var controller: ClaudeSignInWindowController

    var body: some View {
        VStack(spacing: 0) {
            WebViewHost(webView: controller.webView)
                .frame(minHeight: 360)
            Divider()
            footer
                .padding(12)
        }
        // The hosting view takes the window's minimum size from this frame. Without a minimum
        // width SwiftUI measures the footer a few points wide, and the window outgrows the screen.
        .frame(minWidth: 400, minHeight: 480)
    }

    private var hint: String {
        let account = controller.expectedEmail.map { "Sign in as \($0). " } ?? ""
        return account + "Use Continue with email. Open the emailed link here with Paste Login Link, or type the code claude.ai shows. Google may block its own sign-in inside apps."
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.phase {
            case .signingIn:
                Text(hint)
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .saving:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving your Claude session…").font(.caption)
                }
            case .failed(let message):
                WarningNote(text: message)
            }
            if let message = controller.linkMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(Brand.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("Paste Login Link") { controller.pasteLoginLink() }
                    .secondaryButton()
                    .disabled(controller.phase == .saving)
                Spacer(minLength: 6)
                if case .failed = controller.phase {
                    Button("Start Over") { controller.startOver() }
                        .secondaryButton()
                    Button("Try Again") { controller.retry() }
                        .prominentButton(tint: Brand.claude)
                }
                Button("Cancel") { controller.cancel() }
                    .secondaryButton()
            }
            .controlSize(.small)
        }
    }
}
