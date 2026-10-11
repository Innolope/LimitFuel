import Foundation
import AppKit

// Frozen against SPEC.md only. No network, services, credentials or preference writes.
@main
struct StaleBlurAcceptanceTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static var failures: [String] = []
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    static func radius(_ age: TimeInterval) -> CGFloat {
        MenuBarStatus.blurRadius(lastUpdated: now.addingTimeInterval(-age), now: now)
    }

    static func close(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        check(actual.isFinite && abs(actual - expected) <= 0.000_001,
              "\(message): expected \(expected), got \(actual)")
    }

    static func scalarAcceptance() {
        close(MenuBarStatus.blurRadius(lastUpdated: nil, now: now), 0, "missing update")
        for age: Double in [-86_400, -1, 0, 1, 599.999, 600] {
            close(radius(age), 0, "sharp age \(age)")
        }
        for age: Double in [600.001, 601, 750, 900, 1_200, 1_500, 1_799.999, 1_800] {
            close(radius(age), CGFloat((age - 600) / 1_200 * 1.2), "linear age \(age)")
        }
        for age: Double in [1_800.001, 1_801, 86_400, 31_536_000] {
            close(radius(age), 1.2, "maximum age \(age)")
        }
        for value in [Double.nan, Double.infinity, -Double.infinity,
                      Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            let invalid = Date(timeIntervalSince1970: value)
            close(MenuBarStatus.blurRadius(lastUpdated: invalid, now: now), 0,
                  "invalid update timestamp \(value)")
            close(MenuBarStatus.blurRadius(lastUpdated: now, now: invalid), 0,
                  "invalid current timestamp \(value)")
        }
        // LCG seed 0x5A1E_B10B; 2,048 ages spanning future to seven days stale.
        var seed: UInt64 = 0x5A1E_B10B
        var ages: [Double] = []
        for _ in 0..<2_048 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            ages.append(Double(seed >> 11) / Double(UInt64.max >> 11) * 608_400 - 3_600)
        }
        var previous: CGFloat = 0
        for age in ages.sorted() {
            let actual = radius(age)
            let expected = CGFloat(min(1.2, max(0, (age - 600) / 1_200 * 1.2)))
            close(actual, expected, "seeded radius at \(age)")
            check(actual >= previous && actual >= 0 && actual <= 1.2,
                  "seeded monotonic/bounded radius at \(age)")
            previous = actual
        }
    }

    static func option(_ provider: MenuBarProvider, _ percent: Double,
                       reset: Date? = nil) -> MenuBarWindowOption {
        MenuBarWindowOption(id: provider.rawValue, provider: provider,
                            label: "Acceptance window", percent: percent,
                            durationMinutes: 300, isPreferredBucket: true, resetsAt: reset)
    }

    static func selectionAcceptance() {
        let claudeUpdate = now.addingTimeInterval(-1_200)
        let codexUpdate = now.addingTimeInterval(-1_800)
        let reset = now.addingTimeInterval(3_600)
        let selected = MenuBarStatus.selectedEntries(
            claude: option(.claude, 43, reset: reset), codex: option(.codex, 76),
            claudeIsStale: true, codexIsStale: true,
            claudeUpdatedAt: claudeUpdate, codexUpdatedAt: codexUpdate)
        check(selected.count == 2, "both providers selected")
        let claude = selected.first { $0.provider == .claude }
        let codex = selected.first { $0.provider == .codex }
        check(claude?.percent == 43 && claude?.resetsAt == reset && claude?.isStale == true,
              "Claude exact value, reset and stale state preserved")
        check(codex?.percent == 76 && codex?.isStale == true,
              "Codex exact value and stale state preserved")
        check(claude?.updatedAt == claudeUpdate && codex?.updatedAt == codexUpdate,
              "independent provider timestamps preserved")
        if let claude, let codex {
            close(MenuBarStatus.blurRadius(lastUpdated: claude.updatedAt, now: now), 0.6,
                  "Claude independent radius")
            close(MenuBarStatus.blurRadius(lastUpdated: codex.updatedAt, now: now), 1.2,
                  "Codex independent radius")
        }
        let refreshed = MenuBarStatus.selectedEntries(
            claude: option(.claude, 43, reset: reset), codex: option(.codex, 76),
            claudeIsStale: false, codexIsStale: true,
            claudeUpdatedAt: now, codexUpdatedAt: codexUpdate)
        check(refreshed.first { $0.provider == .claude }?.updatedAt == now,
              "successful Claude response replaces Claude timestamp")
        check(refreshed.first { $0.provider == .codex }?.updatedAt == codexUpdate,
              "successful Claude response preserves Codex timestamp")
        close(MenuBarStatus.blurRadius(lastUpdated: refreshed.first { $0.provider == .claude }?.updatedAt,
                                       now: now), 0, "refresh restores sharpness immediately")
        let zero = MenuBarStatus.selectedEntries(claude: option(.claude, 0), codex: nil)
        check(zero.count == 1 && zero.first?.percent == 0 && zero.first?.resetsAt == nil,
              "valid zero usage remains visible without a badge")
        check(MenuBarStatus.selectedEntries(claude: nil, codex: nil).isEmpty,
              "absent providers produce no entries")
        // These calls intentionally exercise defaults required for existing callers.
        let legacy = MenuBarEntry(provider: .claude, percent: 43)
        check(legacy.updatedAt == nil && !legacy.isStale && legacy.resetsAt == nil,
              "new entry fields preserve defaults")
    }

    static func matches(_ label: String, _ pattern: String) -> Bool {
        label.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func accessibilityAcceptance() {
        let stale = MenuBarEntry(provider: .claude, percent: 43,
                                 resetsAt: now.addingTimeInterval(3_600),
                                 isStale: true, updatedAt: now.addingTimeInterval(-1_200))
        let fresh = MenuBarEntry(provider: .codex, percent: 76, updatedAt: now)
        let label = MenuBarStatus.accessibilityLabel(for: [stale, fresh], now: now)
        check(matches(label, "claude") && matches(label, "codex"),
              "accessible label identifies both providers: \(label)")
        check(matches(label, "43\\s*(%|percent)") && matches(label, "76\\s*(%|percent)"),
              "accessible label retains exact readable percentages: \(label)")
        check(matches(label, "stale|last[ -]?known|out[ -]?of[ -]?date|updated|ago"),
              "accessible stale state remains readable: \(label)")
        check(matches(label, "20\\s*(minutes?|mins?|m)\\b"),
              "accessible label includes twenty-minute update age: \(label)")
        let old = MenuBarEntry(provider: .claude, percent: 0, isStale: true,
                               updatedAt: now.addingTimeInterval(-90_000))
        let oldLabel = MenuBarStatus.accessibilityLabel(for: [old], now: now)
        check(matches(oldLabel, "claude") && matches(oldLabel, "0\\s*(%|percent)"),
              "old zero remains exact and provider identified: \(oldLabel)")
        check(matches(oldLabel, "(1\\s*(days?|d)\\b|25\\s*(hours?|hrs?|h)\\b|1500\\s*(minutes?|mins?|m)\\b)"),
              "accessible age supports updates older than a day: \(oldLabel)")
        let hour = MenuBarEntry(provider: .codex, percent: 76, isStale: true,
                               updatedAt: now.addingTimeInterval(-7_200))
        let hourLabel = MenuBarStatus.accessibilityLabel(for: [hour], now: now)
        check(matches(hourLabel, "(2\\s*(hours?|hrs?|h)\\b|120\\s*(minutes?|mins?|m)\\b)"),
              "accessible age supports hours: \(hourLabel)")
        let laterLabel = MenuBarStatus.accessibilityLabel(for: [stale], now: now.addingTimeInterval(600))
        check(matches(laterLabel, "30\\s*(minutes?|mins?|m)\\b"),
              "accessible update age advances with supplied clock: \(laterLabel)")
    }

    struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    static func pixels(_ image: NSImage, scale: Int) -> Pixels? {
        let width = Int((image.size.width * CGFloat(scale)).rounded())
        let height = Int((image.size.height * CGFloat(scale)).rounded())
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32) else { return nil }
        // The context captures pixels-per-point at creation; size must come first.
        bitmap.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        close(context.cgContext.ctm.a, CGFloat(scale), "raster context native x scale \(scale)x")
        close(context.cgContext.ctm.d, CGFloat(scale), "raster context native y scale \(scale)x")
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size),
                   from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: false, hints: nil)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.bitmapData else { return nil }
        return Pixels(width: width, height: height,
                      bytes: Array(UnsafeBufferPointer(start: data, count: width * height * 4)))
    }

    static func region(_ a: Pixels, _ b: Pixels, startX: Int, endX: Int) -> Bool {
        guard a.width == b.width, a.height == b.height,
              startX >= 0, endX <= a.width, startX <= endX else { return false }
        for y in 0..<a.height {
            let start = (y * a.width + startX) * 4
            let end = (y * a.width + endX) * 4
            if a.bytes[start..<end] != b.bytes[start..<end] { return false }
        }
        return true
    }

    static func imageAcceptance() {
        for provider: MenuBarProvider in [.claude, .codex] {
            // No reset exercises percentage alone; reset exercises the plain separator/countdown.
            for reset in [nil, Optional(now.addingTimeInterval(3_600))] {
                let stale = MenuBarEntry(provider: provider, percent: 43, resetsAt: reset,
                                         isStale: true, updatedAt: now.addingTimeInterval(-1_800))
                let fresh = MenuBarEntry(provider: provider, percent: 43, resetsAt: reset,
                                         isStale: false, updatedAt: now)
                let sharp = MenuBarStatus.image(for: [fresh], now: now, allowsBlur: true)
                let blurred = MenuBarStatus.image(for: [stale], now: now, allowsBlur: true)
                let fallback = MenuBarStatus.image(for: [stale], now: now, allowsBlur: false)
                let missing = MenuBarEntry(provider: provider, percent: 43, resetsAt: reset,
                                           isStale: true, updatedAt: nil)
                let unknown = MenuBarStatus.image(for: [missing], now: now, allowsBlur: true)
                let context = "\(provider.rawValue), badge=\(reset != nil)"
                check(sharp.isTemplate && blurred.isTemplate && fallback.isTemplate,
                      "monochrome template contract: \(context)")
                check(sharp.size.height == 18 && sharp.size.width > 18,
                      "native 18-point image with visible text: \(context)")
                check(sharp.size == blurred.size && sharp.size == fallback.size && sharp.size == unknown.size,
                      "blur and fallback preserve native dimensions: \(context)")
                for scale in [1, 2] {
                    guard let a = pixels(sharp, scale: scale),
                          let b = pixels(blurred, scale: scale),
                          let c = pixels(fallback, scale: scale),
                          let d = pixels(unknown, scale: scale) else {
                        check(false, "render native bitmap: \(context), \(scale)x")
                        continue
                    }
                    check(a.height == 18 * scale, "native pixel height: \(context), \(scale)x")
                    check(region(a, b, startX: 0, endX: 18 * scale),
                          "provider logo remains sharp: \(context), \(scale)x")
                    check(!region(a, b, startX: 18 * scale, endX: a.width),
                          "stale text visibly blurs: \(context), \(scale)x")
                    check(a.bytes == c.bytes, "reduced-blur fallback is sharp: \(context), \(scale)x")
                    check(a.bytes == d.bytes, "unknown timestamp remains sharp: \(context), \(scale)x")
                }
            }
        }
    }

    static func accessibilityPolicyAcceptance() {
        let live = NSWorkspace.shared
        let liveContrast = live.accessibilityDisplayShouldIncreaseContrast
        let liveTransparency = live.accessibilityDisplayShouldReduceTransparency
        print("ACCESSIBILITY-RECEIPT increaseContrast=\(liveContrast) reduceTransparency=\(liveTransparency)")
        for provider: MenuBarProvider in [.claude, .codex] {
            let stale = MenuBarEntry(provider: provider, percent: 81,
                resetsAt: now.addingTimeInterval(6 * 86_400), isStale: true,
                updatedAt: now.addingTimeInterval(-1_800))
            for scale in [1, 2] {
                guard let sharp = pixels(MenuBarStatus.image(for: [stale], now: now, allowsBlur: false), scale: scale),
                      let blurred = pixels(MenuBarStatus.image(for: [stale], now: now, allowsBlur: true), scale: scale) else {
                    check(false, "policy reference raster \(provider), \(scale)x"); continue
                }
                check(sharp.bytes != blurred.bytes, "policy references preserve visible blur: \(provider), \(scale)x")
                for contrast in [false, true] {
                    for transparency in [false, true] {
                        var omittedCalls = 0
                        var nilCalls = 0
                        let omitted = MenuBarStatus.image(for: [stale], now: now, accessibilityPreferences: {
                            omittedCalls += 1
                            return (increaseContrast: contrast, reduceTransparency: transparency)
                        })
                        let explicitNil = MenuBarStatus.image(for: [stale], now: now, allowsBlur: nil, accessibilityPreferences: {
                            nilCalls += 1
                            return (increaseContrast: contrast, reduceTransparency: transparency)
                        })
                        guard let a = pixels(omitted, scale: scale), let b = pixels(explicitNil, scale: scale) else {
                            check(false, "injected policy raster"); continue
                        }
                        let expected = contrast || transparency ? sharp : blurred
                        check(a.bytes == expected.bytes && b.bytes == expected.bytes,
                              "omitted/nil respects preference truth table contrast=\(contrast), transparency=\(transparency), \(provider), \(scale)x")
                        check(omittedCalls > 0 && nilCalls > 0, "default policy consults injected preferences")
                        for forced in [false, true] {
                            var overrideCalls = 0
                            let image = MenuBarStatus.image(for: [stale], now: now, allowsBlur: forced, accessibilityPreferences: {
                                overrideCalls += 1
                                return (increaseContrast: contrast, reduceTransparency: transparency)
                            })
                            guard let actual = pixels(image, scale: scale) else {
                                check(false, "override policy raster"); continue
                            }
                            check(actual.bytes == (forced ? blurred : sharp).bytes,
                                  "explicit override controls fixture pixels for all preferences")
                            check(overrideCalls == 0, "explicit override never reads accessibility preferences")
                        }
                    }
                }
                let defaultLiveImage = MenuBarStatus.image(for: [stale], now: now)
                guard let actualLive = pixels(defaultLiveImage, scale: scale) else {
                    check(false, "live default policy raster"); continue
                }
                check(actualLive.bytes == (liveContrast || liveTransparency ? sharp : blurred).bytes,
                      "real app default respects sampled live preferences: \(provider), \(scale)x")
            }
        }
    }

    static func columnInk(_ image: Pixels, x: Int) -> Int {
        (0..<image.height).reduce(0) { count, y in
            count + (image.bytes[(y * image.width + x) * 4 + 3] > 8 ? 1 : 0)
        }
    }
    static func prefixEqual(_ a: Pixels, _ b: Pixels, endX: Int) -> Bool {
        guard a.height == b.height && endX <= min(a.width, b.width) else { return false }
        for y in 0..<a.height {
            if a.bytes[(y * a.width) * 4..<(y * a.width + endX) * 4] !=
               b.bytes[(y * b.width) * 4..<(y * b.width + endX) * 4] { return false }
        }
        return true
    }
    static func plainResetAcceptance() {
        for provider: MenuBarProvider in [.claude, .codex] {
            let bare = MenuBarEntry(provider: provider, percent: 81, updatedAt: now)
            let reset = MenuBarEntry(provider: provider, percent: 81,
                resetsAt: now.addingTimeInterval(6 * 86_400), updatedAt: now)
            let staleReset = MenuBarEntry(provider: provider, percent: 81,
                resetsAt: reset.resetsAt, isStale: true, updatedAt: now.addingTimeInterval(-1_800))
            let bareImage = MenuBarStatus.image(for: [bare], now: now, allowsBlur: true)
            let resetImage = MenuBarStatus.image(for: [reset], now: now, allowsBlur: true)
            let staleImage = MenuBarStatus.image(for: [staleReset], now: now, allowsBlur: true)
            check(bareImage.isTemplate && resetImage.isTemplate && staleImage.isTemplate,
                  "plain reset images remain templates")
            check(bareImage.size.height == 18 && resetImage.size.height == 18 && resetImage.size.width > bareImage.size.width,
                  "known reset adds separator/countdown width at native height")
            for scale in [1, 2] {
                guard let barePixels = pixels(bareImage, scale: scale),
                      let resetPixels = pixels(resetImage, scale: scale),
                      let stalePixels = pixels(staleImage, scale: scale) else {
                    check(false, "plain reset raster \(provider), \(scale)x"); continue
                }
                check(prefixEqual(barePixels, resetPixels, endX: barePixels.width),
                      "adding reset preserves aligned logo/percentage prefix: \(provider), \(scale)x")
                let percentColumns = (18 * scale..<barePixels.width).filter { columnInk(barePixels, x: $0) > 0 }
                guard let percentEnd = percentColumns.last,
                      let dividerStart = (percentEnd + 1..<resetPixels.width).first(where: { columnInk(resetPixels, x: $0) > 0 }) else {
                    check(false, "known reset has appended separator ink"); continue
                }
                let dividerEnd = (dividerStart..<resetPixels.width).first(where: { columnInk(resetPixels, x: $0) == 0 }) ?? resetPixels.width
                let dividerWidth = dividerEnd - dividerStart
                check(dividerStart - percentEnd > scale && dividerWidth > 0 && dividerWidth <= 2 * scale,
                      "plain divider is narrow with clear leading spacing: \(provider), \(scale)x")
                check(((dividerStart..<dividerEnd).map { columnInk(resetPixels, x: $0) }.max() ?? 0) >= 8 * scale,
                      "plain divider is a tall vertical stroke")
                let countdownStart = (dividerEnd..<resetPixels.width).first(where: { columnInk(resetPixels, x: $0) > 0 })
                check(countdownStart.map { $0 - dividerEnd >= scale } ?? false,
                      "plain divider has clear spacing before countdown")
                check(region(resetPixels, stalePixels, startX: dividerStart, endX: dividerEnd),
                      "plain divider remains sharp when provider text blurs: \(provider), \(scale)x")
                var filledRun = 0
                var broadFill = false
                for x in percentEnd + 1..<resetPixels.width {
                    filledRun = columnInk(resetPixels, x: x) >= 8 * scale ? filledRun + 1 : 0
                    if filledRun > 3 * scale { broadFill = true }
                }
                check(!broadFill, "plain reset has no broad filled badge-alpha region: \(provider), \(scale)x")
                if let countdownStart {
                    let countdownRows = (0..<resetPixels.height).filter { y in
                        (countdownStart..<resetPixels.width).contains { x in resetPixels.bytes[(y * resetPixels.width + x) * 4 + 3] > 8 }
                    }
                    let percentageRows = (0..<barePixels.height).filter { y in
                        (18 * scale..<barePixels.width).contains { x in barePixels.bytes[(y * barePixels.width + x) * 4 + 3] > 8 }
                    }
                    if let a = percentageRows.first, let b = percentageRows.last,
                       let c = countdownRows.first, let d = countdownRows.last {
                        check(abs((a + b) - (c + d)) <= 2 * scale,
                              "percentage/countdown share vertical text alignment: \(provider), \(scale)x")
                    } else { check(false, "plain percentage/countdown both have visible ink") }
                }
            }
        }
    }

    static func main() {
        scalarAcceptance()
        selectionAcceptance()
        accessibilityAcceptance()
        imageAcceptance()
        accessibilityPolicyAcceptance()
        plainResetAcceptance()
        if failures.isEmpty {
            print("PASS: \(assertions) frozen stale-blur acceptance assertions; seed=0x5A1EB10B; 2048 ages; native 1x/2x")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            fputs("\(failures.count) failures / \(assertions) assertions\n", stderr)
            exit(1)
        }
    }
}
