import Foundation

fileprivate func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("Acceptance failure: \(message)") }
}

@main
struct LaunchGateTests {
    static let binary = "/Applications/LimitFuel.app/Contents/MacOS/LimitFuel"
    static let info: [String: Any] = ["CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "42"]

    static func versionFlagPrintsInsteadOfLaunching() {
        check(LaunchGate.versionLine(arguments: [binary, "--version"], info: info) == "LimitFuel 1.4.0 (42)", "version and build are printed")
        check(LaunchGate.versionLine(arguments: [binary, "--version"], info: ["CFBundleShortVersionString": "1.4.0"]) == "LimitFuel 1.4.0", "missing build omits the parentheses")
        check(LaunchGate.versionLine(arguments: [binary, "--version"], info: nil) == "LimitFuel development", "unbundled binary still answers")
        check(LaunchGate.versionLine(arguments: [binary], info: info) == nil, "plain launch starts the app")
        check(LaunchGate.versionLine(arguments: [binary, "-NSDocumentRevisionsDebugMode", "YES"], info: info) == nil, "AppKit arguments start the app")
        check(LaunchGate.versionLine(arguments: ["--version"], info: info) == nil, "the executable path is never read as a flag")
    }

    static func laterCopyYieldsToTheRunningOne() {
        let running = LaunchGate.Instance(pid: 13908, started: Date(timeIntervalSince1970: 1_000))
        // The reported duplicate had a lower, wrapped PID but started two days later.
        let probe = LaunchGate.Instance(pid: 10549, started: Date(timeIntervalSince1970: 200_000))
        check(LaunchGate.shouldYield(probe, to: [running]), "later copy exits even with a lower PID")
        check(!LaunchGate.shouldYield(running, to: [probe]), "running copy keeps the menu bar")
        check(!LaunchGate.shouldYield(running, to: [running]), "a process never yields to itself")
        check(!LaunchGate.shouldYield(probe, to: []), "the only copy starts")
    }

    static func simultaneousStartsKeepExactlyOne() {
        let started = Date(timeIntervalSince1970: 5_000)
        let low = LaunchGate.Instance(pid: 300, started: started)
        let high = LaunchGate.Instance(pid: 301, started: started)
        check(LaunchGate.shouldYield(high, to: [low]) && !LaunchGate.shouldYield(low, to: [high]), "exact tie keeps the lower PID only")
    }

    static func kernelStartTimeIsRead() {
        guard let own = LaunchGate.startDate(of: getpid()) else { fatalError("Acceptance failure: own start time is readable") }
        check(own <= Date() && own > Date().addingTimeInterval(-3_600), "own start time is recent and not in the future")
        check(LaunchGate.startDate(of: 1).map { $0 < own } == true, "launchd started before this test")
        check(LaunchGate.startDate(of: -1) == nil, "invalid PID has no start time")
        check(!LaunchGate.otherInstanceIsRunning(bundleIdentifier: nil), "unbundled build never yields")
        check(!LaunchGate.otherInstanceIsRunning(bundleIdentifier: "com.innolope.limitfuel.tests.\(UUID().uuidString)"), "no other copy means launch")
    }

    static func main() {
        versionFlagPrintsInsteadOfLaunching()
        laterCopyYieldsToTheRunningOne()
        simultaneousStartsKeepExactlyOne()
        kernelStartTimeIsRead()
        print("LaunchGate tests passed")
    }
}
