import Foundation
import AppKit

// Frozen spec-only acceptance suite. Seed 0xC0FFEE; 4,096 generated boundaries.
// No production source or existing tests were read when authoring this file.
private enum CountdownFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case let .assertion(message): return message } }
}

@main
struct MenuCountdownAcceptanceTests {
    private static var checks = 0
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw CountdownFailure.assertion(message) }
    }
    private static func option(_ id: String, _ provider: MenuBarProvider, _ percent: Double,
                               minutes: Int? = 300, preferred: Bool = true,
                               reset: Date? = nil) -> MenuBarWindowOption {
        MenuBarWindowOption(id: id, provider: provider, label: id, percent: percent,
                            durationMinutes: minutes, isPreferredBucket: preferred, resetsAt: reset)
    }
    private static func reference(_ seconds: Double) -> String {
        if seconds <= 0 { return "0m" }
        if seconds >= 86_400 { return "\(Int(floor(seconds / 86_400)))d" }
        if seconds >= 3_600 { return "\(Int(floor(seconds / 3_600)))h" }
        return "\(Int(ceil(seconds / 60)))m"
    }
    private static func label(_ seconds: Double) -> String? {
        MenuBarStatus.resetLabel(resetsAt: now.addingTimeInterval(seconds), now: now)
    }
    private static func pixels(_ image: NSImage) throws -> Data {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = cg.dataProvider?.data else {
            throw CountdownFailure.assertion("native image has no raster representation")
        }
        return data as Data
    }
    private static func countdownBoundaries() throws {
        for seconds: Double in [-86_400, -1, 0, 0.001, 1, 59.999, 60, 60.001,
                                 119.999, 120, 3_599.999, 3_600, 3_600.001,
                                 7_199.999, 7_200, 86_399.999, 86_400,
                                 86_400.001, 172_799.999, 172_800, 864_000] {
            try expect(label(seconds) == reference(seconds), "reset edge \(seconds): \(String(describing: label(seconds)))")
        }
        try expect(MenuBarStatus.resetLabel(resetsAt: nil, now: now) == nil, "missing reset omits badge")
        for raw in [Double.nan, Double.infinity, -Double.infinity, 1e100] {
            let date = Date(timeIntervalSince1970: raw)
            try expect(MenuBarStatus.resetLabel(resetsAt: date, now: now) == nil,
                       "invalid/unsupported reset \(raw) omits badge")
        }
        // LCG-generated values include fractional minute/hour/day edges and past resets.
        var seed: UInt64 = 0xC0FFEE
        for index in 0..<4_096 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let units = [60.0, 3_600.0, 86_400.0][index % 3]
            let boundary = Double(seed % 100) * units
            let offset = [-0.25, 0, 0.25][Int((seed >> 8) % 3)]
            let seconds = boundary + offset
            try expect(label(seconds) == reference(seconds), "seed 0xC0FFEE index \(index), seconds \(seconds)")
        }
    }
    private static func selectionAndEntries() throws {
        let claudeReset = now.addingTimeInterval(4_000)
        let codexReset = now.addingTimeInterval(90_000)
        let claude = option("claude-session", .claude, 0, reset: claudeReset)
        let codex = option("codex-session", .codex, 37, reset: codexReset)
        let entries = MenuBarStatus.selectedEntries(claude: claude, codex: codex,
                                                  claudeIsStale: true, codexIsStale: false)
        try expect(entries.count == 2, "two selected providers")
        try expect(entries.map(\.provider) == [.claude, .codex], "stable provider order")
        try expect(entries.map(\.percent) == [0, 37], "zero remains visible")
        try expect(entries.map(\.resetsAt) == [claudeReset, codexReset], "each percentage carries its own reset")
        try expect(entries.map(\.isStale) == [true, false], "stale flags are provider-specific")
        let noReset = MenuBarStatus.selectedEntries(claude: option("unknown", .claude, 0), codex: nil)
        try expect(noReset.count == 1 && noReset[0].percent == 0 && noReset[0].resetsAt == nil,
                   "missing reset never drops zero percentage")
        try expect(MenuBarStatus.selectedEntries(claude: nil, codex: nil).isEmpty, "no available values")
        try expect(MenuBarStatus.entries(claude: 0, codex: 37).map(\.percent) == [0, 37], "legacy entries preserve zero")

        let weekly = option("weekly", .codex, 70, minutes: 10_080, preferred: true,
                            reset: now.addingTimeInterval(604_800))
        let secondarySession = option("secondary-session", .codex, 22, preferred: false,
                                     reset: now.addingTimeInterval(7_200))
        let preferredSession = option("preferred-session", .codex, 11, preferred: true,
                                     reset: now.addingTimeInterval(3_600))
        let options = [weekly, secondarySession, preferredSession]
        let selected = MenuBarSelection.selectedOption(provider: .codex, options: options, selectionID: nil)
        try expect(selected?.id == preferredSession.id, "default is session-first, preferred bucket")
        let explicit = MenuBarSelection.selectedOption(provider: .codex, options: options, selectionID: weekly.id)
        try expect(explicit?.id == weekly.id && explicit?.resetsAt == weekly.resetsAt,
                   "saved selection chooses matching percentage and reset")
        try expect(MenuBarSelection.selectedOption(provider: .codex, options: options, selectionID: "removed")?.id == preferredSession.id,
                   "missing saved ID preserves default preference")
        try expect(MenuBarSelection.selectedOption(provider: .codex, options: [secondarySession, option("later", .codex, 90, preferred: false)], selectionID: nil)?.id == secondarySession.id,
                   "equal preferences preserve input order")
        try expect(MenuBarSelection.selectedOption(provider: .claude, options: options, selectionID: nil) == nil,
                   "selection never borrows other provider")
    }
    private static func nativeRendering() throws {
        let base = [MenuBarEntry(provider: .claude, percent: 0)]
        let countdown = [MenuBarEntry(provider: .claude, percent: 0, resetsAt: now.addingTimeInterval(7_200))]
        let codex = [MenuBarEntry(provider: .codex, percent: 0)]
        let both = base + codex
        let emptyImage = MenuBarStatus.image(for: [], now: now)
        let baseImage = MenuBarStatus.image(for: base, now: now)
        let countdownImage = MenuBarStatus.image(for: countdown, now: now)
        let codexImage = MenuBarStatus.image(for: codex, now: now)
        let bothImage = MenuBarStatus.image(for: both, now: now)
        for image in [emptyImage, baseImage, countdownImage, codexImage, bothImage] {
            try expect(image.isTemplate, "native status image is a template")
            try expect(image.size.height == 18 && image.size.width > 0, "native status image has 18pt height and positive width")
            try expect(!(try pixels(image)).isEmpty, "native status image has pixels")
        }
        try expect(countdownImage.size.width > baseImage.size.width, "badge contributes visible width")
        try expect(bothImage.size.width > baseImage.size.width, "both provider slots contribute width")
        try expect(try pixels(baseImage) != pixels(codexImage), "provider logos remain distinct")
        try expect(try pixels(emptyImage) != pixels(baseImage), "app mark differs from available provider")
        for bad in [Double.nan, Double.infinity, 1e100] {
            let invalid = [MenuBarEntry(provider: .claude, percent: 0, resetsAt: Date(timeIntervalSince1970: bad))]
            let image = MenuBarStatus.image(for: invalid, now: now)
            try expect(image.size == baseImage.size, "invalid reset omits badge width, preserves percentage")
            try expect(try pixels(image) == pixels(baseImage), "invalid reset renders same provider percentage")
        }
        let accessible = MenuBarStatus.accessibilityLabel(for: countdown, now: now).lowercased()
        try expect(accessible.contains("claude") && accessible.contains("0%") && accessible.contains("2h"),
                   "accessibility identifies provider, zero percentage and matching reset")
        let bothAccessible = MenuBarStatus.accessibilityLabel(for: both, now: now).lowercased()
        try expect(bothAccessible.contains("claude") && bothAccessible.contains("codex"), "accessibility contains both providers")
    }
    static func main() {
        do {
            _ = NSApplication.shared
            try countdownBoundaries()
            try selectionAndEntries()
            try nativeRendering()
            print("PASS MenuCountdownAcceptanceTests: \(checks) checks; seed=0xC0FFEE; generated=4096")
        } catch {
            fputs("FAIL MenuCountdownAcceptanceTests: \(error)\n", stderr)
            exit(1)
        }
    }
}
