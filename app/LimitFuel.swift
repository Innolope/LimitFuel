import SwiftUI
import AppKit
import WebKit
import Carbon
import ServiceManagement

// Secondary text: system gray in dark; darker in light, where the vibrant
// ~50% gray over the white popover backing reads as washed out.
extension Color {
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .secondaryLabelColor
            : NSColor(white: 0.24, alpha: 1.0) // opaque: vibrancy washes out alpha grays
    })
}

// MARK: - Popup design system

// Provider colors, matching the two rows of the app icon.
enum Brand {
    static let claude = Color(red: 1.0, green: 0.541, blue: 0.239)  // #ff8a3d
    static let codex = Color(red: 0.184, green: 0.816, blue: 0.769)  // #2fd0c4
    static let warning = Color(red: 1.0, green: 0.769, blue: 0.0)    // #ffc400
    static let critical = Color(red: 1.0, green: 0.271, blue: 0.227) // #ff453a
}

// Provider color while there is headroom; amber from 70%, red from 90%.
func meterColor(_ fraction: Double, base: Color) -> Color {
    fraction >= 0.9 ? Brand.critical : fraction >= 0.7 ? Brand.warning : base
}

private func litSegments(_ fraction: Double, of segments: Int) -> Int {
    let clamped = max(0, min(1, fraction))
    // Any usage lights the first segment, so 1% never reads as empty.
    return clamped <= 0 ? 0 : min(segments, Int((clamped * Double(segments) - 1e-9).rounded(.up)))
}

// Usage meter drawn as a row of LED segments, like the app icon. Hand-drawn
// because the native linear ProgressView ignores .tint() in light (aqua) and
// vibrant rendering and falls back to accent blue.
struct UsageBar: View {
    let value: Double
    let color: Color
    var segments: Int = 30
    var height: CGFloat = 6
    var glow = false

    var body: some View {
        let lit = litSegments(value, of: segments)
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < lit ? color : Color.primary.opacity(0.1))
                    .shadow(color: glow && index < lit ? color.opacity(0.55) : .clear, radius: 3)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(max(0, min(1, value)) * 100)) percent used")
    }
}

// One usage limit: name, big percentage, glowing segment meter and reset time.
struct MeterRow: View {
    let title: String
    let subtitle: String?
    let percent: Int?
    let fraction: Double
    let color: Color
    let footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Color.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(percent.map { "\($0)" } ?? "–")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if percent != nil {
                        Text("%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(Color.secondaryText)
                    }
                }
            }
            UsageBar(value: percent == nil ? 0 : fraction, color: color, height: 8, glow: true)
            if let footnote = footnote {
                Label(footnote, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProviderHeader: View {
    let name: String
    let color: Color
    let detail: String?

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

// The app icon in miniature: a dark tile with two rows of five segments.
struct BrandGlyph: View {
    var size: CGFloat = 22

    var body: some View {
        let unit = size / 100
        ZStack {
            RoundedRectangle(cornerRadius: 22.5 * unit, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.04)],
                                     startPoint: .top, endPoint: .bottom))
            VStack(spacing: 10 * unit) {
                row(lit: 4, color: Brand.claude, unit: unit)
                row(lit: 2, color: Brand.codex, unit: unit)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    private func row(lit: Int, color: Color, unit: CGFloat) -> some View {
        HStack(spacing: 3 * unit) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3 * unit, style: .continuous)
                    .fill(index < lit ? color : Color(white: 0.21))
                    .frame(width: 10.4 * unit, height: 18 * unit)
            }
        }
    }
}

// Soft provider-colored light behind the cards: Claude orange near the top,
// Codex teal lower down, matching the order of the cards.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let strength = colorScheme == .dark ? 0.42 : 0.30
            ZStack {
                glow(Brand.claude, strength: strength, radius: w * 0.75)
                    .position(x: w * 0.1, y: min(h * 0.12, 90))
                glow(Brand.codex, strength: strength * 0.9, radius: w * 0.75)
                    .position(x: w * 0.95, y: h * 0.7)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // A radial gradient rather than a blurred shape: same softness, and it
    // renders identically in offscreen previews, which ignore blur filters.
    private func glow(_ color: Color, strength: Double, radius: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(strength), color.opacity(strength * 0.35), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
    }
}

// Liquid Glass on macOS 26 when built with the macOS 26 SDK; elsewhere a frosted
// material with a light rim. LEGACY_GLASS forces the fallback (preview renders).
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    var interactive = false

    func body(content: Content) -> some View {
        surface(content)
    }

#if compiler(>=6.2) && !LEGACY_GLASS
    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint.map { $0.opacity(0.22) }).interactive(interactive), in: shape)
        } else {
            frosted(content)
        }
    }
#else
    private func surface(_ content: Content) -> some View {
        frosted(content)
    }
#endif

    private func frosted(_ content: Content) -> some View {
        content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint = tint {
                        shape.fill(tint.opacity(0.14))
                    }
                }
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 10, y: 4)
    }
}

extension View {
    func glassCard(tint: Color? = nil, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: tint))
    }

#if compiler(>=6.2) && !LEGACY_GLASS
    @ViewBuilder
    func prominentButton(tint: Color) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(tint)
        } else {
            self.buttonStyle(.borderedProminent).tint(tint)
        }
    }

    @ViewBuilder
    func secondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
#else
    func prominentButton(tint: Color) -> some View {
        self.buttonStyle(.borderedProminent).tint(tint)
    }

    func secondaryButton() -> some View {
        self.buttonStyle(.bordered)
    }
#endif
}

var usesSystemGlass: Bool {
#if compiler(>=6.2) && !LEGACY_GLASS
    if #available(macOS 26.0, *) { return true }
#endif
    return false
}

struct GlassIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(Color.primary.opacity(0.75))
        .modifier(GlassSurface(shape: Circle(), interactive: true))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct WarningNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Brand.warning)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// "3h 12m · Sat 14:43": time left until the reset, then its local time.
func resetDescription(_ date: Date, now: Date = Date()) -> String {
    let seconds = Int(date.timeIntervalSince(now))
    guard seconds > 0 else { return "now" }
    let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
    let remaining = days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(max(minutes, 1))m"
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: now) ? "jmm" : "EEEjmm")
    return "\(remaining) · \(formatter.string(from: date))"
}

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var statusManager: StatusManager!
    var updateManager: UpdateManager!
    var codexManager: CodexUsageManager!
    private var claudePollTimer: Timer?
    private var codexPollTimer: Timer?
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?
    let popupPresentation = PopupPresentation()
    var menuBarPreferences = MenuBarPreferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDiagnostics.shared.start()
        // NSUserNotification (deprecated but works without permissions for unsigned apps)
        NSLog("✅ App launched, notifications ready")

        // Create status bar item with variable length for compact display
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateSelectedProviderIcon()
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self

            // Force the button to be visible
            button.appearsDisabled = false
            button.isEnabled = true
        }

        // Initialize managers
        usageManager = UsageManager(statusItem: statusItem, delegate: self)
        statusManager = StatusManager()
        updateManager = UpdateManager()
        codexManager = CodexUsageManager()
        codexManager.onChange = { [weak self] in
            self?.updateSelectedProviderIcon()
            self?.scheduleCodexPoll()
        }
        menuBarPreferences.onChange = { [weak self] in self?.updateSelectedProviderIcon() }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: popupPresentation.viewportHeight)
        popover.behavior = .transient
        popover.delegate = self
        popupPresentation.onResize = { [weak self] height in
            guard let self = self else { return }
            let size = NSSize(width: 360, height: height)
            if self.popover.contentSize != size { self.popover.contentSize = size }
        }
        popover.contentViewController = NSHostingController(rootView: UsageView(
            usageManager: usageManager,
            statusManager: statusManager,
            updateManager: updateManager,
            codexManager: codexManager,
            popupPresentation: popupPresentation,
            menuBarPreferences: menuBarPreferences
        ))
        NotificationCenter.default.addObserver(self, selector: #selector(updatePopupScreenBounds),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePopupScreenBounds),
            name: NSWindow.didChangeScreenNotification, object: statusItem.button?.window)

        // Appearance preference: "system" (default) tracks the macOS light/dark
        // setting; "dark"/"light" force one (dark was hard-forced in v1.3.2 and
        // users complained about losing light mode). Applied after the popover
        // exists so both NSApp and the popover get styled.
        applyAppearancePreference()

        // Re-apply when macOS flips light/dark, so a forced mode that matches
        // the system switches back to the native (inherited) rendering.
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // The defaults key can lag the notification; re-resolve a tick later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.applyAppearancePreference()
            }
        }

        // Fetch initial data
        usageManager.fetchUsage()
        usageManager.detectChromeSession()
        codexManager.fetchUsage()
        statusManager.fetch()
        updateManager.fetch()

        scheduleClaudePoll()
        scheduleCodexPoll()
        // Provider usage has independent adaptive timers. Status remains once a minute.
        Timer.scheduledTimer(withTimeInterval: RefreshSchedule.usageInterval, repeats: true) { _ in
            self.statusManager.fetch()
        }

        // App updates are infrequent (new release at most weekly) — poll every 3 hours.
        Timer.scheduledTimer(withTimeInterval: RefreshSchedule.updateInterval, repeats: true) { _ in
            self.updateManager.fetch()
        }

        Timer.scheduledTimer(withTimeInterval: RefreshSchedule.cookieInterval, repeats: true) { _ in
            self.usageManager.detectChromeSession()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.usageManager.detectChromeSessionIfDue()
            self?.usageManager.fetchUsage()
            self?.codexManager.fetchUsage()
        }

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    func scheduleClaudePoll() {
        claudePollTimer?.invalidate()
        let interval = RefreshSchedule.pollingInterval(usedPercent: usageManager.hasFetchedData ? usageManager.sessionUtilization : nil,
            windowDurationMins: 300, resetsAt: usageManager.sessionResetsAt)
        let delay = RefreshSchedule.nextPollDelay(interval: interval, lastStartedAt: usageManager.lastFetchStartedAt)
        claudePollTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.usageManager.fetchUsage()
            self?.scheduleClaudePoll()
        }
    }

    func scheduleCodexPoll() {
        codexPollTimer?.invalidate()
        let windows = codexManager.snapshot?.buckets.flatMap { [$0.primary, $0.secondary].compactMap { $0 } } ?? []
        let interval = windows.map {
            RefreshSchedule.pollingInterval(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt)
        }.min() ?? RefreshSchedule.usageInterval
        let delay = RefreshSchedule.nextPollDelay(interval: interval, lastStartedAt: codexManager.lastFetchStartedAt)
        codexPollTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.codexManager.fetchUsage()
            self?.scheduleCodexPoll()
        }
    }

    func updateSelectedProviderIcon() {
        guard let button = statusItem?.button else { return }
        let codex = MenuBarSelection.selectedOption(provider: .codex,
            options: codexManager?.snapshot?.menuBarOptions ?? [],
            selectionID: menuBarPreferences.selectionID(for: .codex))?.percent
        let claude = MenuBarSelection.selectedOption(provider: .claude,
            options: usageManager?.menuBarOptions ?? [],
            selectionID: menuBarPreferences.selectionID(for: .claude))?.percent
        let entries = MenuBarStatus.entries(claude: claude, codex: codex)
        button.title = ""
        button.image = MenuBarStatus.image(for: entries)
        button.toolTip = MenuBarStatus.accessibilityLabel(for: entries)
        button.setAccessibilityLabel(MenuBarStatus.accessibilityLabel(for: entries))
    }

    func applyAppearancePreference() {
        let mode = UserDefaults.standard.string(forKey: "appearance_mode") ?? "system"
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let isDark: Bool
        switch mode {
        case "dark":  isDark = true
        case "light": isDark = false
        default:      isDark = systemIsDark
        }
        // Always set an explicit, resolved appearance ("System" resolves to the
        // current macOS setting) so every mode uses the same rendering path:
        // inherited "vibrant" rendering drops ProgressView tints (bars turn
        // accent-blue) and shades colors slightly differently, which made
        // System and Dark look different. Set on the popover too — it doesn't
        // reliably restyle from NSApp.appearance alone once created.
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        popover?.appearance = appearance
    }

    func setupKeyboardShortcut() {
        // Only register if user has the shortcut enabled
        if usageManager.shortcutEnabled {
            registerGlobalHotKey()
        }
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    func registerGlobalHotKey() {
        // Guard against double registration
        if hotKeyRef != nil { return }

        var hotKeyID = EventHotKeyID()
        // Use simple numeric ID instead of FourCharCode
        hotKeyID.signature = 0x436C5542 // 'ClUB' as hex
        hotKeyID.id = 1

        // Cmd+U key code
        let keyCode: UInt32 = 32 // 'U' key
        let modifiers: UInt32 = UInt32(cmdKey)

        // Create event spec for hotkey
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install event handler
        var handler: EventHandlerRef?
        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            // Get the AppDelegate instance
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()

            // Toggle popover
            DispatchQueue.main.async {
                appDelegate.togglePopover()
            }

            return noErr
        }

        // Install the handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &handler)

        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            NSLog("✅ Registered Cmd+U hotkey successfully")
        } else {
            NSLog("❌ Failed to register hotkey, status: \(status)")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
            NSLog("🗑️ Unregistered Cmd+U hotkey")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        claudePollTimer?.invalidate()
        codexPollTimer?.invalidate()
        unregisterGlobalHotKey()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right click - show menu
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "Toggle Usage (⌘U)", action: #selector(togglePopover), keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit LimitFuel", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click - toggle popover
            togglePopover()
        }
    }

    func openPopover() {
        guard !popover.isShown else { return }
        if let button = statusItem.button {
            // Force UI refresh by updating percentages
            DispatchQueue.main.async {
                self.usageManager.updatePercentages()
            }

            updatePopupScreenBounds()
            popupPresentation.beginPresentation()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Add event monitor to detect clicks outside the popover
            removePopoverEventMonitor()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        removePopoverEventMonitor()
    }

    func popoverDidShow(_ notification: Notification) {
        updatePopupScreenBounds()
        // A retained hosting controller does not necessarily receive onAppear
        // again. Signal each actual presentation after its window is attached.
        popupPresentation.beginPresentation()
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverEventMonitor()
    }

    @objc func updatePopupScreenBounds() {
        guard let button = statusItem.button, let anchorWindow = button.window,
              let screen = anchorWindow.screen else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        // Reserve native arrow/border space before first presentation, then use
        // the actual decoration height when a popover window is available.
        var chrome: CGFloat = 32
        if popover.isShown, let view = popover.contentViewController?.view, let window = view.window {
            chrome = max(chrome, window.frame.height - view.bounds.height)
        }
        let heightBelowAnchor = min(visible.maxY, anchor.minY) - visible.minY
        popupPresentation.constrain(availableHeight: max(1, heightBelowAnchor - chrome))
    }

    private func removePopoverEventMonitor() {
        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

}

// NSColor extension for hex conversion
extension NSColor {
    var hexString: String {
        guard let rgbColor = self.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// Main entry point
#if !ACCEPTANCE_TESTS
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif

class UsageManager: ObservableObject {
    @Published private(set) var menuBarOptions: [MenuBarWindowOption] = []
    @Published var sessionUsage: Int = 0
    @Published var sessionUtilization: Double = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var weeklyFableUsage: Int = 0
    @Published var weeklyFableLimit: Int = 100
    // Extra usage spend (from /overage_spend_limit). Shown only when there's spend.
    @Published var extraSpentMinor: Int = 0
    @Published var extraLimitMinor: Int = 0
    @Published var extraResetsAt: Date?
    @Published var freeCreditsMinor: Int = 0   // remaining free/promo credits (/prepaid/credits)
    // Banked usage-limit resets the user can trigger on claude.ai (e.g. the Opus 5.5
    // launch grant). Read-only here: using one is a POST on /reset_rate_limits.
    @Published var limitResetsLeft: Int = 0
    @Published var limitResetsEndAt: Date?
    @Published var creditCurrency: String = "USD"
    @Published var hasCreditUsage: Bool = false
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var weeklyFableResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var usageNotificationsEnabled: Bool = true
    @Published var statusNotificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasWeeklyFable: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var shortcutEnabled: Bool = true
    @Published var isDetectingChrome = false
    @Published var chromeMessage: String?
    @Published var chromeNeedsAttention = false
    @Published var chromeProfiles: [ChromeProfile] = []
    @Published var chromeProfileName: String?
    @Published var lastChromeCheck: Date?
    @Published var chromeDetectionEnabled = true
    private(set) var lastFetchStartedAt: Date?

    private var statusItem: NSStatusItem?
    private var sessionCookie: String = ""
    private weak var delegate: AppDelegate?
    private var lastNotifiedThreshold: Int = 0
    private let defaults: UserDefaults
    private let chromeReader: ChromeCookieReader
    private var connectionRevision = UUID()
    private let chromeQueue = DispatchQueue(label: "com.claude.usagebar.chrome", qos: .userInitiated)
    private var activeRequests: [UUID: URLSessionDataTask] = [:]
    private lazy var apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: ClaudeSessionDelegate(), delegateQueue: nil)
    }()

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil,
         defaults: UserDefaults = .standard, chromeReader: ChromeCookieReader = ChromeCookieReader(),
         apiSession: URLSession? = nil) {
        self.defaults = defaults
        self.chromeReader = chromeReader
        self.statusItem = statusItem
        self.delegate = delegate
        if let session = apiSession { self.apiSession = session }
        chromeDetectionEnabled = defaults.object(forKey: "chrome_detection_enabled") as? Bool
            ?? (defaults.string(forKey: "claude_session_cookie") == nil)
        loadSessionCookie()
        loadSettings()
    }

    func detectChromeSessionIfDue() {
        if lastChromeCheck == nil || Date().timeIntervalSince(lastChromeCheck!) >= RefreshSchedule.cookieInterval {
            detectChromeSession()
        }
    }

    func detectChromeSession(interactive: Bool = false, chooseProfile: Bool = false, profileID: String? = nil) {
        guard !isDetectingChrome, interactive || chromeDetectionEnabled else { return }
        isDetectingChrome = true
        chromeMessage = nil
        chromeNeedsAttention = false
        chromeProfiles = []
        let revision = connectionRevision
        let pinned = chooseProfile ? nil : (profileID ?? defaults.string(forKey: "chrome_profile_id"))
        chromeQueue.async { [weak self] in
            guard let reader = self?.chromeReader else { return }
            let result = Result { try reader.discover(profileID: pinned, allowInteraction: interactive) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDetectingChrome = false
                guard self.connectionRevision == revision else { return }
                self.lastChromeCheck = Date()
                switch result {
                case .failure(let error):
                    self.chromeNeedsAttention = true
                    self.chromeMessage = error.localizedDescription
                    let code: DiagnosticErrorCode
                    switch error as? ChromeCookieError {
                    case .keychain: code = .signIn
                    case .invalidCookie, .encryption: code = .invalidData
                    case .unavailable, .profile: code = .unavailable
                    default: code = .protocolFailure
                    }
                    AppDiagnostics.shared.recordFailure(provider: .claude, code: code)
                case .success(let sessions):
                    self.chromeProfiles = sessions.map(\.profile)
                    guard sessions.count == 1, let session = sessions.first else {
                        self.chromeNeedsAttention = true
                        self.chromeMessage = sessions.isEmpty
                            ? "No signed-in Claude session found. Open Claude in Chrome, sign in, then detect again."
                            : "Choose the Chrome profile to connect."
                        return
                    }
                    self.defaults.set(session.profile.id, forKey: "chrome_profile_id")
                    self.defaults.set(true, forKey: "chrome_detection_enabled")
                    self.chromeDetectionEnabled = true
                    self.chromeProfileName = session.profile.name
                    self.chromeProfiles = []
                    self.chromeMessage = "Connected to Chrome: \(session.profile.name). Rechecks hourly."
                    if self.sessionCookie != session.cookieHeader {
                        self.replaceSessionCookie(session.cookieHeader)
                        self.fetchUsage()
                    } else if !self.hasFetchedData { self.fetchUsage() }
                }
            }
        }
    }

    func openClaudeInChrome() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let url = URL(string: "https://claude.ai/settings/usage") else {
            chromeMessage = "Google Chrome is not installed. Install Chrome, or use a manual cookie."
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: chrome,
                               configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil {
                DispatchQueue.main.async { self?.chromeMessage = "Could not open Chrome. Open Claude in Chrome manually and sign in." }
            }
        }
    }

    private func invalidateConnection() {
        connectionRevision = UUID()
        activeRequests.values.forEach { $0.cancel() }
        activeRequests.removeAll()
        isLoading = false
    }

    private func performRequest(_ request: URLRequest,
                                completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        let revision = connectionRevision
        let id = UUID()
        let task = apiSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, self.connectionRevision == revision else { return }
                self.activeRequests.removeValue(forKey: id)
                completion(data, response, error)
                if self.activeRequests.isEmpty { self.isLoading = false }
            }
        }
        activeRequests[id] = task
        task.resume()
    }

    func loadSessionCookie() {
        if let savedCookie = defaults.string(forKey: "claude_session_cookie") {
            sessionCookie = savedCookie
        }
    }

    func loadSettings() {
        // Migrate from legacy single notifications_enabled flag (pre-v1.1) to split flags
        let hasUsageKey  = defaults.object(forKey: "usage_notifications_enabled")  != nil
        let hasStatusKey = defaults.object(forKey: "status_notifications_enabled") != nil

        if !hasUsageKey || !hasStatusKey {
            let legacyHasKey = defaults.object(forKey: "notifications_enabled") != nil
            let legacyValue  = legacyHasKey ? defaults.bool(forKey: "notifications_enabled") : true
            if !hasUsageKey {
                usageNotificationsEnabled = legacyValue
                defaults.set(legacyValue, forKey: "usage_notifications_enabled")
            }
            if !hasStatusKey {
                statusNotificationsEnabled = legacyValue
                defaults.set(legacyValue, forKey: "status_notifications_enabled")
            }
        }
        if hasUsageKey {
            usageNotificationsEnabled = defaults.bool(forKey: "usage_notifications_enabled")
        }
        if hasStatusKey {
            statusNotificationsEnabled = defaults.bool(forKey: "status_notifications_enabled")
        }

        // Reflect the real system login-item state, not just a stored bool.
        if #available(macOS 13.0, *) {
            openAtLogin = (SMAppService.mainApp.status == .enabled)
        } else {
            openAtLogin = defaults.bool(forKey: "open_at_login")
        }
        lastNotifiedThreshold = defaults.integer(forKey: "last_notified_threshold")
        // Default shortcut to enabled if not previously set
        if defaults.object(forKey: "shortcut_enabled") == nil {
            shortcutEnabled = true
        } else {
            shortcutEnabled = defaults.bool(forKey: "shortcut_enabled")
        }
    }

    func saveSettings() {
        defaults.set(usageNotificationsEnabled,  forKey: "usage_notifications_enabled")
        defaults.set(statusNotificationsEnabled, forKey: "status_notifications_enabled")
        defaults.set(openAtLogin, forKey: "open_at_login")
        defaults.set(shortcutEnabled, forKey: "shortcut_enabled")
        defaults.synchronize()
    }

    // Actually register/unregister the app as a macOS login item.
    func applyLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            NSLog("🔑 Login item \(enabled ? "registered" : "unregistered")")
        } catch {
            NSLog("❌ Login item error: \(error.localizedDescription)")
        }
    }

    func saveSessionCookie(_ cookie: String) {
        let normalized = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChromeCookieReader.validateHeader(normalized) else {
            errorMessage = "Paste a valid full Cookie header containing sessionKey."
            return
        }
        chromeDetectionEnabled = false
        defaults.set(false, forKey: "chrome_detection_enabled")
        chromeProfileName = nil
        chromeProfiles = []
        chromeMessage = "Using a manual cookie. Detect Chrome Session to enable hourly sync."
        replaceSessionCookie(normalized)
        fetchUsage()
    }

    private func replaceSessionCookie(_ cookie: String) {
        invalidateConnection()
        let sameSession = sessionIdentity(sessionCookie) == sessionIdentity(cookie) && !sessionCookie.isEmpty
        let priorThreshold = lastNotifiedThreshold
        resetUsageData()
        if sameSession {
            lastNotifiedThreshold = priorThreshold
            defaults.set(priorThreshold, forKey: "last_notified_threshold")
        }
        sessionCookie = cookie
        defaults.set(cookie, forKey: "claude_session_cookie")
    }

    private func sessionIdentity(_ header: String) -> [String] {
        header.split(separator: ";").compactMap { part in
            let field = part.trimmingCharacters(in: .whitespaces)
            return field.hasPrefix("sessionKey=") || field.hasPrefix("lastActiveOrg=") ? field : nil
        }.sorted()
    }

    func clearSessionCookie() {
        invalidateConnection()
        chromeDetectionEnabled = false
        chromeProfileName = nil
        chromeProfiles = []
        chromeMessage = "Session cleared. Detect Chrome Session to reconnect."
        defaults.set(false, forKey: "chrome_detection_enabled")
        sessionCookie = ""
        defaults.removeObject(forKey: "claude_session_cookie")
        defaults.synchronize()

        resetUsageData()
    }

    private func resetUsageData() {
        menuBarOptions = []
        // Reset all data when credentials change so accounts never share usage state.
        sessionUsage = 0
        sessionUtilization = 0
        weeklyUsage = 0
        weeklySonnetUsage = 0
        weeklyFableUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        weeklyFableResetsAt = nil
        extraSpentMinor = 0
        extraLimitMinor = 0
        extraResetsAt = nil
        freeCreditsMinor = 0
        limitResetsLeft = 0
        limitResetsEndAt = nil
        hasCreditUsage = false
        hasFetchedData = false
        hasWeeklySonnet = false
        hasWeeklyFable = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        defaults.set(0, forKey: "last_notified_threshold")

        // Update status bar to show 0%
        delegate?.updateSelectedProviderIcon()

    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        // Get org ID from the lastActiveOrg cookie value
        let cookieParts = sessionCookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
                if UUID(uuidString: orgId) != nil {
                    completion(orgId)
                    return
                }
            }
        }

        // If not in cookie, fetch from bootstrap
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")

        NSLog("📡 Fetching bootstrap to get org ID...")

        performRequest(request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String,
                  UUID(uuidString: lastActiveOrgId) != nil,
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                NSLog("❌ Could not parse org ID from bootstrap")
                completion(nil)
                return
            }
            NSLog("Claude organization resolved")
            completion(lastActiveOrgId)
        }
    }

    func fetchUsage() {
        guard activeRequests.isEmpty else { return }
        lastFetchStartedAt = Date()
        guard !sessionCookie.isEmpty else {

                self.errorMessage = "Session cookie not set"
                self.updateStatusBar()

            return
        }

        isLoading = true
        errorMessage = nil

        // Extract org ID from cookie
        fetchOrganizationId { [weak self] orgId in
            guard let self = self, let orgId = orgId else {

                    self?.errorMessage = "Could not get org ID from cookie"
                    self?.isLoading = false
                    AppDiagnostics.shared.recordFailure(provider: .claude, code: .signIn)

                return
            }

            self.fetchUsageWithOrgId(orgId)
            self.fetchExtraUsage(orgId)
            self.fetchFreeCredits(orgId)
            self.fetchLimitResets(orgId)
        }
    }

    // Usage-limit resets the account can still use. claude.ai's Settings > Usage reads
    // the same `cedar_ember` object from /usage with `cedar_ember=1`; we only GET it.
    func fetchLimitResets(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage?cedar_ember=1&skip_spend=1") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        performRequest(request) { [weak self] data, response, _ in

                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let (left, endAt) = Self.parseLimitResets(json["cedar_ember"])
                self.limitResetsLeft = left
                self.limitResetsEndAt = endAt
                NSLog("🔄 Limit resets available: \(left)")

        }
    }

    /// Counts resets still usable across grants (not paused, inside their window)
    /// and returns the earliest end date among them.
    static func parseLimitResets(_ raw: Any?, now: Date = Date()) -> (Int, Date?) {
        guard let obj = raw as? [String: Any],
              (obj["eligible"] as? Bool) == true,
              let grants = obj["grants"] as? [[String: Any]] else { return (0, nil) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? {
            guard let s = v as? String else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }
        var total = 0
        var earliestEnd: Date?
        for g in grants {
            let left = (g["resets_left"] as? Int) ?? 0
            guard left > 0, (g["paused"] as? Bool) != true,
                  let end = date(g["ends_at"]), end > now else { continue }
            if let start = date(g["starts_at"]), start > now { continue }
            total += left
            earliestEnd = min(earliestEnd ?? end, end)
        }
        return (total, earliestEnd)
    }

    // Remaining free/promo credits (balance) from /prepaid/credits.
    func fetchFreeCredits(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/prepaid/credits") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        performRequest(request) { [weak self] data, response, _ in

                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                // `amount` is the current balance; fall back to summing remaining tranches.
                if let amount = json["amount"] as? Int {
                    self.freeCreditsMinor = amount
                } else {
                    var remaining = 0
                    for key in ["tranches", "promo_tranches"] {
                        if let arr = json[key] as? [[String: Any]] {
                            for t in arr { remaining += (t["remaining_amount_minor_units"] as? Int) ?? 0 }
                        }
                    }
                    self.freeCreditsMinor = remaining
                }
                if let cur = json["currency"] as? String { self.creditCurrency = cur }
                NSLog("🎁 Free credits left: \(self.freeCreditsMinor) \(self.creditCurrency)")

        }
    }

    // Extra usage spend + monthly limit live on a separate endpoint (not /usage).
    func fetchExtraUsage(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/overage_spend_limit") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        performRequest(request) { [weak self] data, response, _ in

                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                let spent = (json["used_credits"] as? Int) ?? 0
                let limit = (json["monthly_credit_limit"] as? Int) ?? 0
                self.extraSpentMinor = spent
                self.extraLimitMinor = limit
                self.creditCurrency = (json["currency"] as? String) ?? "USD"
                if let resetStr = json["disabled_until"] as? String {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    self.extraResetsAt = f.date(from: resetStr) ?? ISO8601DateFormatter().date(from: resetStr)
                }
                self.hasCreditUsage = spent > 0
                NSLog("💳 Extra usage: \(spent)/\(limit) \(self.creditCurrency)")

        }
    }

    func fetchUsageWithOrgId(_ orgId: String) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {

                self.errorMessage = "Invalid URL"
                self.isLoading = false

            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("Fetching Claude usage")

        performRequest(request) { [weak self] data, response, error in

                self?.isLoading = false

                if let error = error {
                    self?.errorMessage = "Network error"
                    let code: DiagnosticErrorCode = (error as NSError).code == NSURLErrorTimedOut ? .timeout : .protocolFailure
                    AppDiagnostics.shared.recordFailure(provider: .claude, code: code)
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response"
                    self?.menuBarOptions = []
                    AppDiagnostics.shared.recordFailure(provider: .claude, code: .protocolFailure)
                    self?.updateStatusBar()
                    return
                }

                NSLog("📡 Status: \(httpResponse.statusCode)")


                if httpResponse.statusCode == 200, let data = data {
                    self?.parseUsageData(data)
                } else {
                    self?.errorMessage = "HTTP \(httpResponse.statusCode)"
                    self?.menuBarOptions = []
                    AppDiagnostics.shared.recordFailure(provider: .claude,
                        code: [401, 403].contains(httpResponse.statusCode) ? .signIn : .protocolFailure)
                }

                self?.updateStatusBar()

        }
    }

    func parseUsageData(_ data: Data) {
        menuBarOptions = []
        defer { delegate?.updateSelectedProviderIcon() }
        // Every response must establish fresh adaptive state, including invalid JSON.
        sessionUtilization = 0
        sessionUsage = 0
        sessionResetsAt = nil
        hasFetchedData = false
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON"
                AppDiagnostics.shared.recordFailure(provider: .claude, code: .invalidData)
                return
            }

            NSLog("📊 Parsing usage data...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plainFormatter = ISO8601DateFormatter()
            plainFormatter.formatOptions = [.withInternetDateTime]
            func resetDate(_ value: Any?) -> Date? {
                guard let text = value as? String else { return nil }
                return iso8601Formatter.date(from: text) ?? plainFormatter.date(from: text)
            }
            func percentage(_ value: Any?) -> Double? {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                let result = number.doubleValue
                return result.isFinite && result >= 0 && result <= 100 ? result : nil
            }

            // Parse the actual claude.ai response format
            guard let fiveHour = json["five_hour"] as? [String: Any],
                  let sessionUtil = percentage(fiveHour["utilization"]) else {
                sessionUtilization = 0
                sessionUsage = 0
                sessionResetsAt = nil
                hasFetchedData = false
                errorMessage = "Claude five-hour usage is unavailable or invalid. Refresh to try again."
                AppDiagnostics.shared.recordFailure(provider: .claude, code: .invalidData)
                return
            }
            sessionUtilization = sessionUtil
            sessionUsage = Int(sessionUtil)
            sessionLimit = 100
            sessionResetsAt = resetDate(fiveHour["resets_at"])
            var availableWindows = [MenuBarWindowOption(id: "claude:five_hour", provider: .claude,
                label: "Session · 5h", percent: sessionUtil, durationMinutes: 300, isPreferredBucket: true)]

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = percentage(sevenDay["utilization"]) {
                    availableWindows.append(MenuBarWindowOption(id: "claude:seven_day", provider: .claude,
                        label: "Weekly · 7d", percent: weeklyUtil, durationMinutes: 10080, isPreferredBucket: true))
                    weeklyUsage = Int(weeklyUtil)
                    weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String {
                    NSLog("🕐 Weekly resets_at string: \(resetsAtString)")
                    if let resetsAt = resetDate(resetsAtString) {
                        weeklyResetsAt = resetsAt
                        NSLog("✅ Parsed weekly reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly reset time")
                    }
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                hasWeeklySonnet = true
                if let sonnetUtil = percentage(sevenDaySonnet["utilization"]) {
                    availableWindows.append(MenuBarWindowOption(id: "claude:seven_day_sonnet", provider: .claude,
                        label: "Sonnet · 7d", percent: sonnetUtil, durationMinutes: 10080, isPreferredBucket: false))
                    weeklySonnetUsage = Int(sonnetUtil)
                    weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String {
                    NSLog("🕐 Weekly Sonnet resets_at string: \(resetsAtString)")
                    if let resetsAt = resetDate(resetsAtString) {
                        weeklySonnetResetsAt = resetsAt
                        NSLog("✅ Parsed weekly Sonnet reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly Sonnet reset time")
                    }
                }
            } else {
                hasWeeklySonnet = false
            }

            // Fable is a new, separately-counted model. It isn't a top-level
            // key like seven_day_sonnet — it lives in the `limits` array as a
            // model-scoped weekly limit (scope.model.display_name == "Fable").
            // The bar is only surfaced in the UI when usage is above 1%.
            hasWeeklyFable = false
            if let limits = json["limits"] as? [[String: Any]] {
                let fableLimit = limits.first { entry in
                    let scope = entry["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    return (model?["display_name"] as? String) == "Fable"
                }
                if let fable = fableLimit {
                    hasWeeklyFable = true
                    // `percent` may decode as Int or Double depending on payload.
                    if let p = percentage(fable["percent"]) {
                        availableWindows.append(MenuBarWindowOption(id: "claude:seven_day_fable", provider: .claude,
                            label: "Fable · 7d", percent: p, durationMinutes: 10080, isPreferredBucket: false))
                        weeklyFableUsage = Int(p)
                    }
                    weeklyFableLimit = 100
                    if let resetsAtString = fable["resets_at"] as? String {
                        NSLog("🕐 Weekly Fable resets_at string: \(resetsAtString)")
                        if let resetsAt = resetDate(resetsAtString) {
                            weeklyFableResetsAt = resetsAt
                            NSLog("✅ Parsed weekly Fable reset time: \(resetsAt)")
                        } else {
                            NSLog("❌ Failed to parse weekly Fable reset time")
                        }
                    }
                }
            }

            // (Prepaid usage credits are fetched separately from /prepaid/credits.)

            // Log what we found
            NSLog("✅ Parsed: Session \(sessionUsage)%, Weekly \(weeklyUsage)%\(hasWeeklySonnet ? ", Weekly Sonnet \(weeklySonnetUsage)%" : "")\(hasWeeklyFable ? ", Weekly Fable \(weeklyFableUsage)%" : "")")

            lastUpdated = Date()
            errorMessage = nil
            hasFetchedData = true
            menuBarOptions = availableWindows
            AppDiagnostics.shared.recordRecovery(provider: .claude)

            // Update percentage values for progress bars
            updatePercentages()
        } catch {
            NSLog("❌ Parse error: \(error.localizedDescription)")
            errorMessage = "Parse error"
            AppDiagnostics.shared.recordFailure(provider: .claude, code: .invalidData)
        }
    }

    func updateStatusBar() {
        let sessionPercent = Int((Double(sessionUsage) / Double(sessionLimit)) * 100)

        // Update the icon color
        delegate?.updateSelectedProviderIcon()
        delegate?.scheduleClaudePoll()

        // Check for notification thresholds
        if hasFetchedData { checkNotificationThresholds(percentage: sessionPercent) }
    }

    func checkNotificationThresholds(percentage: Int) {
        NSLog("🔔 Checking notifications: percentage=\(percentage)%, enabled=\(usageNotificationsEnabled), lastNotified=\(lastNotifiedThreshold)%")

        guard usageNotificationsEnabled else {
            NSLog("⚠️ Usage notifications disabled")
            return
        }

        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                NSLog("📬 Sending notification for \(threshold)% threshold")
                sendNotification(percentage: percentage, threshold: threshold)
                lastNotifiedThreshold = threshold
                // Persist the threshold
                defaults.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
                defaults.synchronize()
            }
        }

        // Reset if usage drops below current threshold
        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold from \(lastNotifiedThreshold)% to \(newThreshold)%")
            lastNotifiedThreshold = newThreshold
            defaults.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
            defaults.synchronize()
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")

        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "Test notification - You've reached 75% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Test notification sent successfully")
    }

    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0
    @Published var weeklyFablePercentage: Double = 0.0

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
        weeklyFablePercentage = Double(weeklyFableUsage) / Double(weeklyFableLimit)
    }
}

// MARK: - Anthropic Service Status

struct StatusIncident: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // investigating | identified | monitoring | resolved
    let latestUpdate: String
    let updatedAt: Date?
    let componentIds: [String]
}

struct AffectedComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // degraded_performance | partial_outage | major_outage
}

struct StatusComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // operational | degraded_performance | ...
}

private let defaultTrackedComponents: [StatusComponent] = [
    StatusComponent(id: "c-claude-ai",      name: "claude.ai",                          status: "operational"),
    StatusComponent(id: "c-claude-console", name: "Claude Console (platform.claude.com)", status: "operational"),
    StatusComponent(id: "c-claude-api",     name: "Claude API (api.anthropic.com)",     status: "operational"),
    StatusComponent(id: "c-claude-code",    name: "Claude Code",                         status: "operational"),
    StatusComponent(id: "c-claude-cowork",  name: "Claude Cowork",                       status: "operational"),
    StatusComponent(id: "c-claude-gov",     name: "Claude for Government",              status: "operational"),
]

private let defaultTrackedComponentIdSet: Set<String> = Set(
    defaultTrackedComponents.map { $0.id }.filter { $0 != "c-claude-gov" }
)

class StatusManager: ObservableObject {
    @Published var indicator: String = "none"        // none | minor | major | critical (raw, global)
    @Published var statusDescription: String = "All systems operational"
    @Published var incidents: [StatusIncident] = []
    @Published var affectedComponents: [AffectedComponent] = []
    @Published var allComponents: [StatusComponent] = defaultTrackedComponents
    @Published var selectedComponentIds: Set<String> = defaultTrackedComponentIdSet
    @Published var lastUpdated: Date?
    @Published var hasFetched: Bool = false

    // Canonical URL (status.anthropic.com 302-redirects here)
    private let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!

    init() {
        if let saved = UserDefaults.standard.array(forKey: "tracked_component_ids") as? [String] {
            selectedComponentIds = Set(saved)
        }
        // Clean up legacy debug pref if present
        UserDefaults.standard.removeObject(forKey: "status_preview_mode")
    }

    func toggleComponent(_ id: String) {
        if selectedComponentIds.contains(id) {
            selectedComponentIds.remove(id)
        } else {
            selectedComponentIds.insert(id)
        }
        UserDefaults.standard.set(Array(selectedComponentIds), forKey: "tracked_component_ids")
    }

    func isTracked(_ id: String) -> Bool {
        selectedComponentIds.contains(id)
    }

    // MARK: - Filtered/effective views (respect tracked components)

    var filteredAffectedComponents: [AffectedComponent] {
        affectedComponents.filter { selectedComponentIds.contains($0.id) }
    }

    var filteredIncidents: [StatusIncident] {
        incidents.filter { incident in
            guard !incident.componentIds.isEmpty else { return true }
            return incident.componentIds.contains(where: { selectedComponentIds.contains($0) })
        }
    }

    var effectiveIndicator: String {
        let trackedComponents = allComponents.filter { selectedComponentIds.contains($0.id) }
        let max = trackedComponents.map { severity(for: $0.status) }.max() ?? 0
        switch max {
        case 0:  return "none"
        case 1:  return "minor"
        case 2:  return "major"
        default: return "critical"
        }
    }

    private func severity(for componentStatus: String) -> Int {
        switch componentStatus {
        case "operational":          return 0
        case "under_maintenance":    return 1
        case "degraded_performance": return 1
        case "partial_outage":       return 2
        case "major_outage":         return 3
        default:                     return 0
        }
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            self.parse(data)
        }.resume()
    }

    private func parse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let indicator = status["indicator"] as? String,
              let desc = status["description"] as? String else {
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var parsedIncidents: [StatusIncident] = []
        if let raw = json["incidents"] as? [[String: Any]] {
            for inc in raw {
                guard let id = inc["id"] as? String,
                      let name = inc["name"] as? String,
                      let st = inc["status"] as? String else { continue }
                if st == "resolved" || st == "postmortem" { continue }
                let updates = inc["incident_updates"] as? [[String: Any]] ?? []
                let latest = (updates.first?["body"] as? String) ?? ""
                let dateStr = (updates.first?["created_at"] as? String) ?? (inc["updated_at"] as? String)
                let updatedAt = dateStr.flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }
                let compIds = (inc["components"] as? [[String: Any]] ?? [])
                    .compactMap { $0["id"] as? String }
                parsedIncidents.append(StatusIncident(
                    id: id, name: name, status: st, latestUpdate: latest,
                    updatedAt: updatedAt,
                    componentIds: compIds
                ))
            }
        }

        var parsedAffected: [AffectedComponent] = []
        var parsedAll: [StatusComponent] = []
        if let raw = json["components"] as? [[String: Any]] {
            for c in raw {
                guard let id = c["id"] as? String,
                      let name = c["name"] as? String,
                      let st = c["status"] as? String else { continue }
                parsedAll.append(StatusComponent(id: id, name: name, status: st))
                if st != "operational" {
                    parsedAffected.append(AffectedComponent(id: id, name: name, status: st))
                }
            }
        }

        DispatchQueue.main.async {
            let isFirstFetch = !self.hasFetched

            self.indicator = indicator
            self.statusDescription = desc
            self.incidents = parsedIncidents
            self.affectedComponents = parsedAffected
            if !parsedAll.isEmpty {
                self.allComponents = parsedAll
                // First time we see real components: track all except Claude for Government by default
                if UserDefaults.standard.array(forKey: "tracked_component_ids") == nil {
                    let defaultIds = parsedAll
                        .filter { !$0.name.localizedCaseInsensitiveContains("Government") }
                        .map { $0.id }
                    self.selectedComponentIds = Set(defaultIds)
                    UserDefaults.standard.set(Array(self.selectedComponentIds),
                                              forKey: "tracked_component_ids")
                }
            }
            self.lastUpdated = Date()
            self.hasFetched = true

            // Notify on transitions of EFFECTIVE (filtered) indicator
            let effective = self.effectiveIndicator
            let previous = UserDefaults.standard.string(forKey: "last_effective_indicator")
            if !isFirstFetch, let previous = previous, previous != effective {
                self.notifyStatusChange(to: effective, description: desc)
            }
            UserDefaults.standard.set(effective, forKey: "last_effective_indicator")
        }
    }

    private func notifyStatusChange(to indicator: String, description: String) {
        guard UserDefaults.standard.bool(forKey: "status_notifications_enabled") else { return }

        let notification = NSUserNotification()
        if indicator == "none" {
            notification.title = "Claude is back online"
            notification.informativeText = "All systems operational"
        } else {
            notification.title = "Claude status: \(description)"
            notification.informativeText = "Visit status.anthropic.com for details"
        }
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent status-change notification: \(indicator)")
    }
}

// MARK: - App Updates

struct BannerButton: Equatable {
    let label: String
    let url: URL?         // optional — opens this URL (validated)
    let action: String?   // "dismiss" closes the banner; nil = no extra side effect
    let style: String?    // "primary" | "secondary" | nil
}

struct AvailableUpdate: Equatable {
    let version: String
    let title: String
    let body: String
    let buttons: [BannerButton]
}

// Free-form message channel, decoupled from the app version. Driven by the
// `message` object in latest.json and keyed on `id` (not version), so any
// message can be sent at any time without shipping a new build. Every field is
// author-controlled — including the notification title, which is NOT possible
// on the legacy version-based channel.
struct Announcement: Equatable {
    let id: String
    let heading: String?          // optional small top line on the card (nil = none)
    let title: String
    let body: String
    let buttons: [BannerButton]
    let notify: Bool              // false = show the in-app card only, no OS notification
    let notifTitle: String        // fully custom notification title
    let notifBody: String         // fully custom notification body
}

class UpdateManager: ObservableObject {
    @Published var available: AvailableUpdate?
    @Published var announcement: Announcement?

    // Fork-owned feed prevents upstream releases from replacing LimitFuel changes.
    private let endpoint = URL(string: "https://raw.githubusercontent.com/Innolope/LimitFuel/main/website/fork-latest.json")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static let allowedHostSuffixes = [
        "github.com",
        "claudeusagebar.com"
    ]

    static func isSafeURL(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    private static func parseButtons(from json: [String: Any]) -> [BannerButton] {
        // Explicit `buttons` array (new schema, supports any combination)
        if let raw = json["buttons"] as? [[String: Any]] {
            return raw.compactMap { dict -> BannerButton? in
                guard let label = dict["label"] as? String, !label.isEmpty else { return nil }
                let urlStr = dict["url"] as? String
                let url = urlStr.flatMap { URL(string: $0) }
                if let url = url, !isSafeURL(url) { return nil }   // reject unsafe URLs
                return BannerButton(
                    label: label,
                    url: url,
                    action: dict["action"] as? String,
                    style: dict["style"] as? String
                )
            }
        }
        // Back-compat: legacy `download_url` builds the default 2-button layout
        if let urlStr = json["download_url"] as? String,
           let url = URL(string: urlStr),
           isSafeURL(url) {
            return [
                BannerButton(label: "Download", url: url, action: nil, style: "primary"),
                BannerButton(label: "Later",    url: nil, action: "dismiss", style: nil)
            ]
        }
        return []
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("⚠️ Update fetch failed or invalid payload")
                return
            }

            // ---- Legacy version-update channel (for real releases; also what
            //      pre-1.3.1 apps rely on). Optional — absent fields = no update.
            let updatePayload: AvailableUpdate? = {
                guard let version = json["version"] as? String,
                      let title = json["title"] as? String,
                      let body = json["description"] as? String else { return nil }
                return AvailableUpdate(version: version, title: title, body: body,
                                       buttons: Self.parseButtons(from: json))
            }()

            // ---- Free-form message channel (`message` object, keyed on `id`).
            //      Every field author-controlled, including the notification title.
            let announcementPayload: Announcement? = {
                guard let msg = json["message"] as? [String: Any],
                      let id = msg["id"] as? String, !id.isEmpty else { return nil }
                let title = msg["title"] as? String ?? ""
                let body  = msg["body"]  as? String ?? ""
                let notif = msg["notification"] as? [String: Any]
                return Announcement(
                    id: id,
                    heading: msg["heading"] as? String,
                    title: title,
                    body: body,
                    buttons: Self.parseButtons(from: msg),
                    notify: (msg["notify"] as? Bool) ?? true,
                    notifTitle: (notif?["title"] as? String) ?? (title.isEmpty ? "LimitFuel" : title),
                    notifBody:  (notif?["body"]  as? String) ?? body
                )
            }()

            DispatchQueue.main.async {
                // First-seen times decide which banner wins when both are live.
                let d = UserDefaults.standard
                let now = Date().timeIntervalSince1970
                if let update = updatePayload, self.isNewer(remote: update.version, than: self.currentVersion),
                   d.string(forKey: "update_seen_version") != update.version {
                    d.set(update.version, forKey: "update_seen_version")
                    d.set(now, forKey: "update_seen_at")
                }
                if let ann = announcementPayload, d.string(forKey: "message_seen_id") != ann.id {
                    d.set(ann.id, forKey: "message_seen_id")
                    d.set(now, forKey: "message_seen_at")
                }

                // Version-update channel
                if let update = updatePayload, self.isNewer(remote: update.version, than: self.currentVersion) {
                    if self.available != update {
                        self.available = update
                        NSLog("⬆️ Update available: \(update.version)")
                    }
                    let lastNotified = UserDefaults.standard.string(forKey: "last_notified_update_version")
                    if lastNotified != update.version {
                        let n = NSUserNotification()
                        n.title = "LimitFuel \(update.version) is available"
                        n.informativeText = update.title
                        n.soundName = NSUserNotificationDefaultSoundName
                        NSUserNotificationCenter.default.deliver(n)
                        UserDefaults.standard.set(update.version, forKey: "last_notified_update_version")
                        NSLog("📬 Sent update notification for \(update.version)")
                    }
                } else {
                    self.available = nil
                }

                // Message channel — notify once per `id`. On the very first run
                // that supports messages, seed the current id WITHOUT notifying so
                // updating from an older version doesn't re-ping the live message.
                if let ann = announcementPayload {
                    let dismissed = UserDefaults.standard.string(forKey: "dismissed_message_id")
                    self.announcement = (dismissed == ann.id) ? nil : ann

                    let lastShown = UserDefaults.standard.string(forKey: "last_shown_message_id")
                    if lastShown == nil {
                        UserDefaults.standard.set(ann.id, forKey: "last_shown_message_id")   // seed, no notif
                    } else if lastShown != ann.id {
                        if ann.notify {
                            let n = NSUserNotification()
                            n.title = ann.notifTitle
                            n.informativeText = ann.notifBody
                            n.soundName = NSUserNotificationDefaultSoundName
                            NSUserNotificationCenter.default.deliver(n)
                            NSLog("📬 Sent message notification for id \(ann.id)")
                        }
                        UserDefaults.standard.set(ann.id, forKey: "last_shown_message_id")
                    }
                } else {
                    self.announcement = nil
                }
            }
        }.resume()
    }

    enum Banner { case none, message, update }

    /// When a message card and an update banner are both live, the popover shows the
    /// one published last (first seen most recently), so a newer update or message
    /// replaces an older card even if it was never closed. Ties go to the update.
    static func pickBanner(hasMessage: Bool, hasUpdate: Bool,
                           messageSeenAt: Double, updateSeenAt: Double) -> Banner {
        switch (hasMessage, hasUpdate) {
        case (false, false): return .none
        case (true, false): return .message
        case (false, true): return .update
        case (true, true): return updateSeenAt >= messageSeenAt ? .update : .message
        }
    }

    var visibleBanner: Banner {
        let d = UserDefaults.standard
        return Self.pickBanner(hasMessage: announcement != nil,
                               hasUpdate: available != nil && !isCurrentDismissed,
                               messageSeenAt: d.double(forKey: "message_seen_at"),
                               updateSeenAt: d.double(forKey: "update_seen_at"))
    }

    func dismissCurrent() {
        // Dismiss the banner on screen; the other one, if any, shows next.
        if visibleBanner == .message, let id = announcement?.id {
            UserDefaults.standard.set(id, forKey: "dismissed_message_id")
            announcement = nil
            return
        }
        if let v = available?.version {
            UserDefaults.standard.set(v, forKey: "dismissed_update_version")
        }
        available = nil
    }

    var isCurrentDismissed: Bool {
        guard let v = available?.version else { return false }
        return UserDefaults.standard.string(forKey: "dismissed_update_version") == v
    }

    private func isNewer(remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

// Custom NSTextField that properly handles paste
class CustomTextField: NSTextField {
    var onTextChange: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if (event.modifierFlags.contains(.command)) {
                switch event.charactersIgnoringModifiers {
                case "v":
                    if let string = NSPasteboard.general.string(forType: .string) {
                        self.stringValue = string
                        onTextChange?(string)
                        NSLog("ClaudeUsage: Pasted text length: \(string.count)")
                        return true
                    }
                case "a":
                    self.currentEditor()?.selectAll(nil)
                    return true
                case "c":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    return true
                case "x":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    self.stringValue = ""
                    onTextChange?("")
                    return true
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(self.stringValue)
    }
}

// Custom TextView that ensures keyboard commands work
class PasteableNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": // Paste
                paste(nil)
                return true
            case "c": // Copy
                copy(nil)
                return true
            case "x": // Cut
                cut(nil)
                return true
            case "a": // Select All
                selectAll(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Multi-line text field with proper paste support
struct PasteableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PasteableNSTextView()

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true

        // Enable wrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteableNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteableTextField

        init(_ parent: PasteableTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var codexManager: CodexUsageManager = CodexUsageManager()
    @ObservedObject var popupPresentation: PopupPresentation = PopupPresentation()
    @ObservedObject var menuBarPreferences: MenuBarPreferences = MenuBarPreferences()
    // Lets the offline preview renderer capture the Settings page.
    var startsInSettings = false
    @State private var sessionCookieInput: String = ""
    @State private var showingCookieInput: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingStatusDetails: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance_mode") private var appearanceMode: String = "system"
    @State private var diagnosticsEnabled = AppDiagnostics.shared.enabled

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showingSettings {
                        settingsPage
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        dashboard
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                    .padding(14)
                    .id("top")
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .frame(width: 360, height: popupPresentation.viewportHeight)
            .background(popupBackground)
            .onPreferenceChange(ContentHeightKey.self) { value in
                popupPresentation.measure(contentHeight: value)
            }
            .onAppear {
                usageManager.updatePercentages()
                if startsInSettings { showingSettings = true }
            }
            .onChange(of: showingSettings) { _ in
                resetScroll(proxy)
            }
            .onChange(of: popupPresentation.opening) { _ in
                resetScroll(proxy)
            }
        }
    }

    private func resetScroll(_ proxy: ScrollViewProxy) {
        // Wait for the new page/document bounds before resolving its top anchor.
        // Keep all account, settings and text-entry state in the retained view.
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("top", anchor: .top) }
        }
    }

    // On macOS 26 the popover itself is Liquid Glass, so only the provider glow
    // is added. Earlier systems keep the tuned scrim over the native material:
    // dark sits between fully native (too transparent) and the v1.3.2 0.62 scrim
    // (read as "too dark"); light needs a near-opaque backing, or a dark desktop
    // bleeds through as murky blue-gray when forced.
    private var popupBackground: some View {
        ZStack {
            if !usesSystemGlass {
                colorScheme == .dark
                    ? Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.3)
                    : Color.white.opacity(0.85)
            }
            AmbientBackground()
        }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                BrandGlyph()
                Text("LimitFuel")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                if usageManager.isLoading || codexManager.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                GlassIconButton(symbol: "arrow.clockwise", help: "Refresh") { refresh() }
                GlassIconButton(symbol: "gearshape", help: "Settings") {
                    withAnimation(.easeInOut(duration: 0.25)) { showingSettings = true }
                }
            }

            banners
            claudeCard
            CodexUsageView(manager: codexManager)

            if statusManager.hasFetched {
                serviceStatus
            }

            if let updated = lastUpdated {
                Text("Updated \(formatTime(updated))")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var lastUpdated: Date? {
        let claude = usageManager.hasFetchedData ? usageManager.lastUpdated : nil
        let codex = codexManager.snapshot != nil ? codexManager.lastUpdated : nil
        return [claude, codex].compactMap { $0 }.max()
    }

    private func refresh() {
        usageManager.fetchUsage()
        codexManager.fetchUsage()
        statusManager.fetch()
        updateManager.fetch()
    }

    @ViewBuilder
    private var banners: some View {
        // Free-form message banner (author-controlled). Takes priority over
        // the version-update banner when both are present.
        if updateManager.visibleBanner == .message, let ann = updateManager.announcement {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let heading = ann.heading, !heading.isEmpty {
                        Text(heading)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    Spacer()
                    dismissBannerButton
                }
                if !ann.title.isEmpty {
                    Text(ann.title)
                        .font(.caption)
                }
                if !ann.body.isEmpty {
                    Text(ann.body)
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !ann.buttons.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(ann.buttons.indices, id: \.self) { i in
                            bannerButton(ann.buttons[i])
                        }
                    }
                }
            }
            .glassCard(tint: .accentColor)
        }

        // App update banner (version-based). Shares the slot with the message
        // card; the more recently published of the two is shown.
        if updateManager.visibleBanner == .update, let update = updateManager.available {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("Version \(update.version) available")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    dismissBannerButton
                }
                Text(update.title)
                    .font(.caption)
                Text(update.body)
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !update.buttons.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(update.buttons.indices, id: \.self) { i in
                            bannerButton(update.buttons[i])
                        }
                    }
                }
            }
            .glassCard(tint: .accentColor)
        }
    }

    private var dismissBannerButton: some View {
        Button(action: { updateManager.dismissCurrent() }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.secondaryText)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Dismiss")
    }

    private var claudeSource: String? {
        guard usageManager.hasFetchedData else { return nil }
        if !usageManager.chromeDetectionEnabled { return "Manual cookie" }
        return usageManager.chromeProfileName.map { "Chrome · \($0)" } ?? "Chrome"
    }

    private var claudeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderHeader(name: "Claude", color: Brand.claude, detail: claudeSource)

            if let error = usageManager.errorMessage {
                WarningNote(text: error)
            }

            if usageManager.hasFetchedData {
                MeterRow(title: "Session", subtitle: "5h",
                         percent: Int(usageManager.sessionPercentage * 100),
                         fraction: usageManager.sessionPercentage,
                         color: meterColor(usageManager.sessionPercentage, base: Brand.claude),
                         footnote: usageManager.sessionResetsAt.map { resetDescription($0) })
                MeterRow(title: "Weekly", subtitle: "7d",
                         percent: Int(usageManager.weeklyPercentage * 100),
                         fraction: usageManager.weeklyPercentage,
                         color: meterColor(usageManager.weeklyPercentage, base: Brand.claude),
                         footnote: usageManager.weeklyResetsAt.map { resetDescription($0) })
                claudeExtras
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    chromeConnectionControls
                }
            }
            if usageManager.hasFetchedData && (usageManager.isDetectingChrome || usageManager.chromeNeedsAttention) {
                chromeConnectionControls
            }
        }
        .glassCard()
    }

    @ViewBuilder
    private var claudeExtras: some View {
        let fableActive = usageManager.hasWeeklyFable && usageManager.weeklyFableUsage >= 1
        let extraActive = usageManager.hasCreditUsage || usageManager.freeCreditsMinor > 0

        // Weekly Sonnet only when the plan reports it; Fable only once it is in
        // use (new model, counted separately; hidden while idle to avoid clutter).
        if usageManager.hasWeeklySonnet {
            MeterRow(title: "Sonnet", subtitle: "7d",
                     percent: Int(usageManager.weeklySonnetPercentage * 100),
                     fraction: usageManager.weeklySonnetPercentage,
                     color: meterColor(usageManager.weeklySonnetPercentage, base: Brand.claude),
                     footnote: usageManager.weeklySonnetResetsAt.map { resetDescription($0) })
        }
        if fableActive {
            MeterRow(title: "Fable", subtitle: "7d",
                     percent: Int(usageManager.weeklyFablePercentage * 100),
                     fraction: usageManager.weeklyFablePercentage,
                     color: meterColor(usageManager.weeklyFablePercentage, base: Brand.claude),
                     footnote: usageManager.weeklyFableResetsAt.map { resetDescription($0) })
        }
        if extraActive {
            extraUsage
        }

        // Available limit resets, when the account has any.
        if usageManager.limitResetsLeft > 0 {
            let n = usageManager.limitResetsLeft
            let until: String = usageManager.limitResetsEndAt.map { d in
                // Last usable instant: an end at local midnight would read as the next day.
                let f = DateFormatter(); f.dateFormat = "MMM d"
                return " until \(f.string(from: d.addingTimeInterval(-1)))"
            } ?? ""
            infoLine("\(n) limit reset\(n == 1 ? "" : "s") available\(until)")
        }
    }

    private func infoLine(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(Color.secondaryText)
            .opacity(0.8)
            .frame(maxWidth: .infinity)
    }

    // Usage credits (pay-as-you-go). Only shown once credits are actually
    // used; links out to manage credits on claude.ai.
    private var extraUsage: some View {
        let spentMinor = usageManager.extraSpentMinor
        let limitMinor = usageManager.extraLimitMinor
        let pct = limitMinor > 0 ? Double(spentMinor) / Double(limitMinor) : 0
        let pctInt = Int((pct * 100).rounded())
        // Show the exact % up to the limit; once over, just say "over limit".
        let pctLabel = pctInt > 100 ? "over limit" : "\(pctInt)%"
        let fmt: (Int) -> String = { minor in
            let v = Double(minor) / 100.0
            return usageManager.creditCurrency == "USD"
                ? String(format: "$%.2f", v)
                : String(format: "%@ %.2f", usageManager.creditCurrency, v)
        }
        // Reset date, shortened (e.g. "Resets Aug 1").
        let shortReset: String? = usageManager.extraResetsAt.map { d in
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return "Resets \(f.string(from: d))"
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Extra usage")
                    .font(.system(size: 13, weight: .semibold))
                if let r = shortReset {
                    Text(r)
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondaryText)
                }
                Spacer(minLength: 6)
                Button(action: {
                    if let url = URL(string: "https://claude.ai/new#settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Manage →")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Brand.claude)
                }
                .buttonStyle(.borderless)
            }

            // Spend vs monthly limit — only when there's actual spend.
            if usageManager.hasCreditUsage {
                if limitMinor > 0 {
                    UsageBar(value: min(pct, 1.0), color: meterColor(pct, base: Brand.claude), height: 8, glow: true)
                }
                Text(limitMinor > 0
                     ? "\(fmt(spentMinor)) of \(fmt(limitMinor)) · \(pctLabel)"
                     : "\(fmt(spentMinor)) spent")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
            }

            if usageManager.freeCreditsMinor > 0 {
                Text("\(fmt(usageManager.freeCreditsMinor)) free credits left")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
            }
        }
    }

    private var chromeButtons: some View {
        HStack(spacing: 6) {
            Button(usageManager.isDetectingChrome ? "Detecting…" : "Detect Chrome Session") {
                usageManager.detectChromeSession(interactive: true, chooseProfile: true)
            }
            .disabled(usageManager.isDetectingChrome)
            .prominentButton(tint: Brand.claude)
            Button("Open Claude in Chrome") { usageManager.openClaudeInChrome() }
                .secondaryButton()
        }
        .controlSize(.small)
    }

    private var chromeConnectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if usageManager.isDetectingChrome {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading Claude sessions from Chrome…").font(.caption)
                }
            } else {
                Text(usageManager.chromeMessage ?? "Sign in to claude.ai in Chrome, then detect the session.")
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("macOS may ask for access to Chrome Safe Storage to read your session. Approve in the system dialog; LimitFuel never asks for your password.")
                .font(.caption2)
                .foregroundColor(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            chromeButtons
            ForEach(usageManager.chromeProfiles) { profile in
                Button("Use \(profile.name) (\(profile.id))") {
                    usageManager.detectChromeSession(interactive: true, profileID: profile.id)
                }
                .disabled(usageManager.isDetectingChrome)
                .font(.caption)
            }
        }
    }

    // Anthropic service status (compact; expandable on issue)
    private var serviceStatus: some View {
        let effective = statusManager.effectiveIndicator
        let filteredIncidents = statusManager.filteredIncidents
        let filteredAffected = statusManager.filteredAffectedComponents
        let hasIssue = effective != "none"
            && (!filteredIncidents.isEmpty || !filteredAffected.isEmpty)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(statusColor(for: effective))
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor(for: effective).opacity(0.8), radius: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(effective == "none"
                         ? "Claude services operational"
                         : statusManager.statusDescription)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if hasIssue {
                        Text(statusContextLine(for: statusManager))
                            .font(.system(size: 10))
                            .foregroundColor(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if hasIssue {
                    Button(action: { showingStatusDetails.toggle() }) {
                        HStack(spacing: 2) {
                            Text(showingStatusDetails ? "Hide" : "Details")
                            Image(systemName: showingStatusDetails ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8))
                        }
                        .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if hasIssue && showingStatusDetails {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredIncidents) { incident in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(incident.name)
                                .font(.system(size: 12, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                Text(incident.status.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(badgeColor(for: incident.status))
                                    .cornerRadius(3)
                                if let updated = incident.updatedAt {
                                    Text("Updated \(relativeTime(updated))")
                                        .font(.caption2)
                                        .foregroundColor(Color.secondaryText)
                                }
                            }

                            if !incident.latestUpdate.isEmpty {
                                Text(incident.latestUpdate)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 2)
                            }
                        }
                    }

                    // Affected components (when no formal incident)
                    if filteredIncidents.isEmpty && !filteredAffected.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Affected services")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(Color.secondaryText)
                            ForEach(filteredAffected) { c in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 5, height: 5)
                                    Text(c.name).font(.caption2)
                                    Spacer()
                                    Text(componentLabel(c.status))
                                        .font(.caption2)
                                        .foregroundColor(Color.secondaryText)
                                }
                            }
                        }
                    }

                    Divider()

                    HStack {
                        if let lastCheck = statusManager.lastUpdated {
                            Text("Checked \(relativeTime(lastCheck))")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
                        }) {
                            Text("Open status page →")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.top, 4)
            }
        }
        .glassCard(tint: hasIssue ? .orange : nil, padding: 12)
    }

    // MARK: Settings

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GlassIconButton(symbol: "chevron.left", help: "Back") {
                    withAnimation(.easeInOut(duration: 0.25)) { showingSettings = false }
                }
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text("v\(updateManager.currentVersion)")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
            }

            settingsCard("Claude account") {
                chromeSession
            }

            if showingCookieInput {
                manualCookie
            }

            settingsCard("Codex account") {
                CodexAccountSettings(manager: codexManager)
            }

            settingsCard("Menu bar usage") {
                menuBarSelector(provider: .claude, options: usageManager.menuBarOptions)
                menuBarSelector(provider: .codex, options: codexManager.snapshot?.menuBarOptions ?? [])
            }

            settingsCard("General") {
                settingToggle("Send crash and error reports", detail: "Helps improve LimitFuel using Sentry. Excludes credentials, account details and application logs.", isOn: Binding(
                    get: { diagnosticsEnabled },
                    set: { enabled in
                        diagnosticsEnabled = enabled
                        AppDiagnostics.shared.setEnabled(enabled)
                    }
                ))
                Text(AppDiagnostics.shared.statusText)
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                settingToggle("Open at Login", detail: nil, isOn: Binding(
                    get: { usageManager.openAtLogin },
                    set: { newValue in
                        usageManager.openAtLogin = newValue
                        usageManager.applyLoginItem(newValue)
                        usageManager.saveSettings()
                    }
                ))
                settingToggle("Keyboard Shortcut (⌘U)",
                              detail: "Toggles this popup from any app",
                              isOn: Binding(
                    get: { usageManager.shortcutEnabled },
                    set: { newValue in
                        usageManager.shortcutEnabled = newValue
                        usageManager.saveSettings()
                        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                            appDelegate.setShortcutEnabled(newValue)
                        }
                    }
                ))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Appearance")
                        .font(.caption)
                    Picker("Appearance", selection: $appearanceMode) {
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: appearanceMode) { _ in
                        (NSApplication.shared.delegate as? AppDelegate)?.applyAppearancePreference()
                    }
                }
            }

            settingsCard("Notifications") {
                settingToggle("Usage Alerts", detail: "At 25, 50, 75 and 90% of the session", isOn: Binding(
                    get: { usageManager.usageNotificationsEnabled },
                    set: { newValue in
                        usageManager.usageNotificationsEnabled = newValue
                        usageManager.saveSettings()
                    }
                ))
                settingToggle("Status Alerts", detail: "Outages in tracked services", isOn: Binding(
                    get: { usageManager.statusNotificationsEnabled },
                    set: { newValue in
                        usageManager.statusNotificationsEnabled = newValue
                        usageManager.saveSettings()
                    }
                ))
                Button("Send Test Notification") {
                    usageManager.sendTestNotification()
                }
                .secondaryButton()
                .controlSize(.small)
            }

            settingsCard("Tracked Claude services") {
                ForEach(statusManager.allComponents) { component in
                    Toggle(isOn: Binding(
                        get: { statusManager.isTracked(component.id) },
                        set: { _ in statusManager.toggleComponent(component.id) }
                    )) {
                        Text(component.name)
                            .font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Text("Refreshes every minute, every 12 s above 90%. Chrome rechecks hourly.")
                .font(.caption2)
                .foregroundColor(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func menuBarSelector(provider: MenuBarProvider, options: [MenuBarWindowOption]) -> some View {
        let valid = options.filter { $0.percent.isFinite && (0...100).contains($0.percent) }
        let selectedID = menuBarPreferences.selectionID(for: provider)
        let unavailable = selectedID != MenuBarSelection.automaticID && !valid.contains { $0.id == selectedID }
        return VStack(alignment: .leading, spacing: 4) {
            Picker(provider == .claude ? "Claude" : "Codex", selection: Binding(
                get: { menuBarPreferences.selectionID(for: provider) },
                set: { menuBarPreferences.select($0, for: provider) }
            )) {
                Text("Automatic (session preferred)").tag(MenuBarSelection.automaticID)
                ForEach(valid) { option in
                    Text(option.label).tag(option.id)
                }
                if unavailable {
                    Text("Saved window unavailable").tag(selectedID)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            if unavailable {
                Text("Using Automatic until your saved window returns.")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Color.secondaryText)
            content()
        }
        .glassCard(padding: 12)
    }

    private func settingToggle(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                if let detail = detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Brand.claude)
        }
    }

    private var chromeSession: some View {
        VStack(alignment: .leading, spacing: 10) {
            chromeConnectionControls

            HStack {
                if let checked = usageManager.lastChromeCheck {
                    Text("Checked \(formatTime(checked))")
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                }
                Spacer()
                Button(showingCookieInput ? "Hide Manual Cookie" : "Use a Manual Cookie") {
                    showingCookieInput.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
    }

    private var manualCookie: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual cookie")
                .font(.system(size: 12, weight: .semibold))
            Text("Paste a full claude.ai Cookie header.")
                .font(.caption2)
                .foregroundColor(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            PasteableTextField(text: $sessionCookieInput, placeholder: "Paste cookie here...")
                .frame(height: 60)
                .cornerRadius(8)

            HStack(spacing: 8) {
                Button("Save Cookie & Fetch") {
                    if sessionCookieInput.isEmpty {
                        usageManager.errorMessage = "Cookie field is empty!"
                    } else {
                        usageManager.saveSessionCookie(sessionCookieInput)
                        sessionCookieInput = ""
                    }
                }
                .prominentButton(tint: Brand.claude)
                .controlSize(.small)

                if UserDefaults.standard.string(forKey: "claude_session_cookie") != nil {
                    Button("Clear Cookie") {
                        sessionCookieInput = ""
                        usageManager.clearSessionCookie()
                    }
                    .secondaryButton()
                    .controlSize(.small)
                }
            }
        }
        .glassCard(padding: 12)
    }

    func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func colorForPercentage(_ percentage: Double) -> Color {
        if percentage < 0.7 {
            return .green
        } else if percentage < 0.9 {
            return .orange
        } else {
            return .red
        }
    }

    func statusColor(for indicator: String) -> Color {
        switch indicator {
        case "none":     return .green
        case "minor":    return .yellow
        case "major":    return .orange
        case "critical": return .red
        default:         return .gray
        }
    }

    func statusLabel(for indicator: String, description: String) -> String {
        if indicator == "none" {
            return "Claude: all systems operational"
        }
        return "Claude: \(description)"
    }

    func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 {
            let m = elapsed / 60
            return "\(m) min\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86_400 {
            let h = elapsed / 3600
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = elapsed / 86_400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    func statusContextLine(for sm: StatusManager) -> String {
        let tracked = sm.allComponents.filter { sm.selectedComponentIds.contains($0.id) }
        let trackedNames = tracked.prefix(4).map { shortName($0.name) }.joined(separator: ", ")
        let extra = tracked.count > 4 ? " +\(tracked.count - 4)" : ""
        let trackedSummary = tracked.isEmpty ? "No services tracked" : "Tracks \(trackedNames)\(extra)"

        if sm.effectiveIndicator == "none" {
            if let lastCheck = sm.lastUpdated {
                return "\(trackedSummary) · checked \(relativeTime(lastCheck))"
            }
            return trackedSummary
        }
        let affected = sm.filteredAffectedComponents
        if !affected.isEmpty {
            let names = affected.prefix(3).map { shortName($0.name) }.joined(separator: ", ")
            let more = affected.count > 3 ? " +\(affected.count - 3)" : ""
            return "Affects: \(names)\(more)"
        }
        if let lastCheck = sm.lastUpdated {
            return "Checked \(relativeTime(lastCheck))"
        }
        return ""
    }

    func shortName(_ raw: String) -> String {
        if let paren = raw.range(of: " (") {
            return String(raw[..<paren.lowerBound])
        }
        return raw
    }

    @ViewBuilder
    func bannerButton(_ btn: BannerButton) -> some View {
        let tap = {
            if let url = btn.url {
                NSWorkspace.shared.open(url)
            }
            if btn.action == "dismiss" {
                updateManager.dismissCurrent()
            }
        }
        if btn.style == "primary" {
            Button(btn.label, action: tap)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(btn.label, action: tap)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    func badgeColor(for status: String) -> Color {
        switch status {
        case "investigating": return Color.red.opacity(0.8)
        case "identified":    return Color.orange
        case "monitoring":    return Color.blue
        case "resolved":      return Color.green
        default:              return Color.gray
        }
    }

    func componentLabel(_ status: String) -> String {
        switch status {
        case "degraded_performance": return "degraded"
        case "partial_outage":       return "partial outage"
        case "major_outage":         return "major outage"
        case "under_maintenance":    return "maintenance"
        default:                     return status
        }
    }

}
