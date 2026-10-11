import AppKit
import SwiftUI

func spin(_ secs: Double = 0.5) { RunLoop.current.run(until: Date().addingTimeInterval(secs)) }
func scrolls(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
}
func snapshot(_ count: Int) -> CodexSnapshot {
    CodexSnapshot(accountLabel: "OFFLINE LAYOUT TEST", buckets: (0..<count).map { n in
        CodexBucket(id: "codex-\(n)", name: "Codex bucket \(n)",
                    primary: CodexWindow(usedPercent: 33, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(3000)),
                    secondary: CodexWindow(usedPercent: 55, windowDurationMins: 10080, resetsAt: Date().addingTimeInterval(86400)))
    })
}
final class DenyNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { fatalError("Native acceptance attempted network") }
    override func stopLoading() {}
}
func demand(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
func press(_ object: Any, help: String, depth: Int = 0) -> Bool {
    guard depth < 40, let element = object as? NSObject else { return false }
    func value(_ name:String)->Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to:selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }
    let label = value("accessibilityLabel") as? String
    let tip = value("accessibilityHelp") as? String
    if label == help || tip == help {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if element.responds(to:selector) {
            typealias Action = @convention(c) (AnyObject,Selector)->Bool
            let action = unsafeBitCast(element.method(for:selector),to:Action.self)
            if action(element,selector) { return true }
        }
    }
    let children = value("accessibilityChildren") as? [Any] ?? []
    if children.contains(where:{ press($0,help:help,depth:depth+1) }) { return true }
    if let view = element as? NSView {
        return view.subviews.contains { press($0,help:help,depth:depth+1) }
    }
    return false
}
@main struct PopupNativeAcceptance {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        setbuf(stdout,nil)
        guard !NSScreen.screens.isEmpty else { fatalError("UNVERIFIED: no native display; run with WindowServer access") }
        let suite = "LimitFuel.PopupVerifier.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        for key in ["chrome_detection_enabled","usage_notifications_enabled","status_notifications_enabled"] { defaults.set(false,forKey:key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DenyNetwork.self]
        URLProtocol.registerClass(DenyNetwork.self)
        let temp = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent("native-empty-browser")
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        let reader = ChromeCookieReader(root:temp,passwordProvider:{ _ in fatalError("No Keychain permitted") })
        let app = AppDelegate()
        app.statusItem = NSStatusBar.system.statusItem(withLength:120)
        app.statusItem.button!.title = "TEST LimitFuel"
        defer { app.closePopover(); NSStatusBar.system.removeStatusItem(app.statusItem) }
        app.usageManager = UsageManager(statusItem:nil,delegate:app,defaults:defaults,chromeReader:reader,apiSession:URLSession(configuration:config))
        app.usageManager.hasFetchedData = true
        app.usageManager.sessionUsage = 92
        app.usageManager.sessionUtilization = 92
        app.usageManager.weeklyUsage = 34
        app.menuBarPreferences = MenuBarPreferences(defaults:defaults)
        app.menuBarPreferences.onChange = { [weak app] in app?.updateSelectedProviderIcon() }
        app.statusManager = StatusManager()
        app.updateManager = UpdateManager()
        app.codexManager = CodexUsageManager(fetcher:{ fatalError("No provider calls") },notificationsEnabled:{false},notify:{ _,_ in fatalError("No notifications") })
        app.codexManager.snapshot = snapshot(4)
        app.usageManager.parseUsageData(Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34},"seven_day_sonnet":{"utilization":56},"limits":[{"percent":78,"scope":{"model":{"display_name":"Fable"}}}]}"#.utf8))
        // Frozen before selection implementation: provider availability must use
        // a valid window even when the preferred bucket/window is unavailable.
        let valid42 = CodexWindow(usedPercent:42,windowDurationMins:300,resetsAt:nil)
        let realZero = CodexWindow(usedPercent:0,windowDurationMins:10080,resetsAt:nil)
        let invalid101 = CodexWindow(usedPercent:101,windowDurationMins:300,resetsAt:nil)
        let weekly14 = CodexWindow(usedPercent:14,windowDurationMins:10080,resetsAt:nil)
        let session92 = CodexWindow(usedPercent:92,windowDurationMins:300,resetsAt:nil)
        let session80 = CodexWindow(usedPercent:80,windowDurationMins:300,resetsAt:nil)
        let hour40 = CodexWindow(usedPercent:40,windowDurationMins:60,resetsAt:nil)
        let sessionZero = CodexWindow(usedPercent:0,windowDurationMins:300,resetsAt:nil)
        let selectionCases: [([CodexBucket],Int)] = [
            ([CodexBucket(id:"codex",name:"session-secondary",primary:weekly14,secondary:session92)],92),
            ([CodexBucket(id:"codex",name:"weekly",primary:weekly14,secondary:nil),CodexBucket(id:"other",name:"session",primary:session80,secondary:nil)],80),
            ([CodexBucket(id:"other",name:"session",primary:session80,secondary:nil),CodexBucket(id:"codex",name:"zero session",primary:sessionZero,secondary:nil)],0),
            ([CodexBucket(id:"codex",name:"hour session",primary:weekly14,secondary:hour40)],40),
            ([CodexBucket(id:"codex",name:"weekly only",primary:weekly14,secondary:nil)],14),
            ([CodexBucket(id:"codex",name:"empty",primary:nil,secondary:nil),CodexBucket(id:"other",name:"valid",primary:valid42,secondary:nil)],42),
            ([CodexBucket(id:"first",name:"empty",primary:nil,secondary:nil),CodexBucket(id:"later",name:"zero",primary:nil,secondary:realZero)],0),
            ([CodexBucket(id:"codex",name:"secondary fallback",primary:invalid101,secondary:valid42)],42),
            ([CodexBucket(id:"other",name:"other",primary:realZero,secondary:nil),CodexBucket(id:"codex",name:"preferred",primary:valid42,secondary:realZero)],42)
        ]
        app.usageManager.hasFetchedData = false
        for (buckets,expected) in selectionCases {
            app.codexManager.snapshot = CodexSnapshot(accountLabel:"OFFLINE LAYOUT TEST",buckets:buckets)
            app.updateSelectedProviderIcon()
            let label = app.statusItem.button!.toolTip ?? ""
            print("menu-selection expected=\(expected) actual=\(label)")
            demand(label.contains("Codex") && label.contains("\(expected)%"),"Valid connected Codex window hidden by unavailable bucket/window")
            demand(!(label.contains("connect")),"Connected Codex must not show disconnected label")
        }
        app.usageManager.hasFetchedData = true
        app.codexManager.snapshot = snapshot(4)
        // Actual delegate rendering and post-mutation preference callback.
        func menu(_ claude:Int?,_ codex:Int?) {
            let label = app.statusItem.button!.toolTip ?? ""
            print("integration-menu \(label)")
            if let p = claude { demand(label.contains("Claude \(p)%"),"Claude selected window") }
            else { demand(!label.contains("Claude "),"Unavailable Claude leaked") }
            if let p = codex { demand(label.contains("Codex \(p)%"),"Codex selected window") }
            else { demand(!label.contains("Codex "),"Unavailable Codex leaked") }
            demand(label.filter{$0 == "%"}.count == (claude == nil ? 0:1)+(codex == nil ? 0:1),"Exactly one percentage per available provider")
        }
        app.codexManager.snapshot = CodexSnapshot(accountLabel:"OFFLINE LAYOUT TEST",buckets:[CodexBucket(id:"codex",name:"Codex",primary:CodexWindow(usedPercent:33,windowDurationMins:300,resetsAt:nil),secondary:CodexWindow(usedPercent:55,windowDurationMins:10080,resetsAt:nil))])
        app.updateSelectedProviderIcon();menu(12,33)
        let cw = app.usageManager.menuBarOptions.first{$0.durationMinutes == 10080 && $0.percent == 34}!.id
        let ow = app.codexManager.snapshot!.menuBarOptions.first{$0.durationMinutes == 10080}!.id
        app.menuBarPreferences.select(cw,for:.claude);menu(34,33)
        app.menuBarPreferences.select(ow,for:.codex);menu(34,55)
        app.codexManager.snapshot = CodexSnapshot(accountLabel:"OFFLINE LAYOUT TEST",buckets:[CodexBucket(id:"codex",name:"renamed",primary:CodexWindow(usedPercent:22,windowDurationMins:300,resetsAt:nil),secondary:nil)])
        app.updateSelectedProviderIcon();menu(34,22)
        demand(app.menuBarPreferences.selectionID(for:.codex) == ow,"Missing selection was destroyed")
        app.codexManager.snapshot = CodexSnapshot(accountLabel:"OFFLINE LAYOUT TEST",buckets:[CodexBucket(id:"codex",name:"renamed",primary:nil,secondary:CodexWindow(usedPercent:0,windowDurationMins:10080,resetsAt:nil))])
        app.updateSelectedProviderIcon();menu(34,0)
        app.usageManager.parseUsageData(Data(#"{"five_hour":{"utilization":9}}"#.utf8));menu(9,0)
        demand(app.menuBarPreferences.selectionID(for:.claude) == cw,"Missing Claude selection was destroyed")
        app.usageManager.parseUsageData(Data(#"{"five_hour":{"utilization":7},"seven_day":{"utilization":0}}"#.utf8));menu(0,0)
        app.usageManager.parseUsageData(Data("invalid".utf8));menu(nil,0)
        demand(app.usageManager.menuBarOptions.isEmpty,"Invalid Claude JSON retained account options")
        app.usageManager.parseUsageData(Data(#"{"five_hour":{"utilization":7}}"#.utf8));menu(7,0)
        app.usageManager.clearSessionCookie();menu(nil,0)
        demand(app.usageManager.menuBarOptions.isEmpty,"Disconnect retained account options")
        app.menuBarPreferences.select(MenuBarSelection.automaticID,for:.claude)
        app.menuBarPreferences.select(MenuBarSelection.automaticID,for:.codex)
        app.usageManager.parseUsageData(Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8))
        app.codexManager.snapshot = snapshot(4)
        app.popover = NSPopover()
        app.popover.animates = false
        app.popover.behavior = .transient
        app.popover.delegate = app
        app.popover.contentSize = NSSize(width:360,height:app.popupPresentation.viewportHeight)
        app.popupPresentation.onResize = { height in app.popover.contentSize = NSSize(width:360,height:height) }
        let host = NSHostingController(rootView:UsageView(usageManager:app.usageManager,statusManager:app.statusManager,updateManager:app.updateManager,codexManager:app.codexManager,popupPresentation:app.popupPresentation,menuBarPreferences:app.menuBarPreferences).defaultAppStorage(defaults))
        app.popover.contentViewController = host
        spin()
        var nativeBoundsFailures: [String] = []
        func state(_ label: String, top: Bool = false) {
            guard let scroll = scrolls(host.view).first,let doc = scroll.documentView,let window = host.view.window,let screen = app.statusItem.button?.window?.screen else { fatalError("Missing native integration view") }
            demand(app.popover.isShown && window.isVisible,"Popover must actually be visible")
            let visible = screen.visibleFrame
            let content = window.convertToScreen(host.view.convert(host.view.bounds,to:nil))
            print("  content=\(content) full-screen=\(screen.frame)")
            print("\(label) shown=\(app.popover.isShown) visible=\(window.isVisible) anchor=\(String(describing:app.statusItem.button?.window?.frame)) button=\(String(describing:app.statusItem.button?.frame)) window=\(window.frame) screen=\(visible) viewport=\(scroll.contentView.bounds) document=\(doc.frame) model=\(app.popupPresentation.viewportHeight) property=\(app.popover.contentSize)")
            // AppKit arrow may enter the menu-bar area; all actual content and
            // the entire lower/horizontal native frame must remain usable.
            if !(content.minY >= visible.minY-1 && content.maxY <= visible.maxY+1 && content.minX >= visible.minX-1 && content.maxX <= visible.maxX+1) { nativeBoundsFailures.append(label + ": content") }
            if !(window.frame.minY >= visible.minY-1 && window.frame.maxY <= screen.frame.maxY+1 && window.frame.minY >= screen.frame.minY-1) { nativeBoundsFailures.append(label + ": native vertical") }
            if !(window.frame.minX >= visible.minX-1 && window.frame.maxX <= visible.maxX+1) { nativeBoundsFailures.append(label + ": horizontal") }
            demand(abs(scroll.contentView.bounds.height-app.popupPresentation.viewportHeight)<1,"SwiftUI viewport differs from shared model")
            demand(abs(app.popover.contentSize.height-app.popupPresentation.viewportHeight)<1,"Popover differs from shared model")
            if top { demand(abs(scroll.contentView.bounds.minY)<1,"Fresh open/page switch must start at top") }
        }
        func bottom() {
            let scroll=scrolls(host.view).first!,doc=scroll.documentView!
            // Bounded settling handles asynchronous page measurement before
            // evaluating reachability against the final document dimensions.
            for attempt in 0..<4 {
                host.view.layoutSubtreeIfNeeded()
                scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,doc.bounds.maxY-scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                spin(0.25)
                print("  bottom-attempt=\(attempt) clip=\(scroll.contentView.bounds) document=\(doc.bounds)")
                if abs(scroll.contentView.bounds.maxY-doc.bounds.maxY)<1 { return }
            }
            demand(false,"Bottom content unreachable after bounded layout settling")
        }
        NSApp.activate(ignoringOtherApps:true); spin(0.5)
        app.openPopover(); spin(1); state("initial",top:true)
        bottom(); state("bottom")
        for n in 0..<3 { app.closePopover(); spin(0.1); app.openPopover(); spin(0.5); state("reopen-\(n)",top:true); bottom() }
        app.codexManager.snapshot = snapshot(2);spin(0.5);state("shrink");bottom()
        app.codexManager.snapshot = snapshot(8);spin(0.5);state("grow");bottom()
        func activateHeader(_ help:String, x:CGFloat) {
            let scroll = scrolls(host.view).first!
            scroll.contentView.scroll(to:.zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            spin(0.2)
            let oldHeight = scroll.documentView!.frame.height
            if !press(host.view,help:help) {
                // Local window events exercise the real visible header button.
                let local = NSPoint(x:x,y:host.view.isFlipped ? 28 : host.view.bounds.height-28)
                let point = host.view.convert(local,to:nil)
                let window = host.view.window!
                for kind: NSEvent.EventType in [.leftMouseDown,.leftMouseUp] {
                    let event = NSEvent.mouseEvent(with:kind,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
                    window.sendEvent(event)
                }
            }
            spin(0.8)
            demand(abs(scroll.documentView!.frame.height-oldHeight)>1,"Real header button did not change page")
        }
        activateHeader("Settings",x:332);state("settings",top:true)
        func pickerControls(_ view:NSView)->[NSPopUpButton] {
            (view as? NSPopUpButton).map{[$0]} ?? view.subviews.flatMap(pickerControls)
        }
        let providerPickers = pickerControls(host.view).filter { $0.itemTitles.contains("Automatic (session preferred)") }
        print("native-provider-pickers=\(providerPickers.map{$0.itemTitles})")
        demand(providerPickers.count == 2,"Settings must contain two independent provider selectors")
        let expectedCounts = [app.usageManager.menuBarOptions.count+1,app.codexManager.snapshot!.menuBarOptions.count+1].sorted()
        demand(providerPickers.map{$0.numberOfItems}.sorted() == expectedCounts,"Native provider selectors omit or invent usage options")
        bottom()
        activateHeader("Back",x:28);state("dashboard",top:true);bottom()
        app.codexManager.snapshot = CodexSnapshot(accountLabel:"OFFLINE LAYOUT TEST",buckets:[CodexBucket(id:"secondary-only",name:"Secondary",primary:nil,secondary:CodexWindow(usedPercent:0,windowDurationMins:10080,resetsAt:nil))])
        spin(0.5);state("secondary-only");bottom()
        app.closePopover();spin(0.1);app.openPopover();spin(0.5);state("secondary-reopen",top:true)
        demand(nativeBoundsFailures.isEmpty,"Native window containment violations: \(nativeBoundsFailures)")
        print("Native popup acceptance passed")
    }
}
