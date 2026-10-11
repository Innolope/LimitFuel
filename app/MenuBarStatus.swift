import AppKit

enum MenuBarProvider: String { case claude, codex }

struct MenuBarEntry: Equatable {
    let provider: MenuBarProvider
    let percent: Int
    var resetsAt: Date? = nil
    var isStale: Bool = false
    var updatedAt: Date? = nil
    var percentageMode: MenuBarPercentageMode? = nil
}

enum MenuBarStatus {
    static func entries(claude: Double?, codex: Double?) -> [MenuBarEntry] {
        [(MenuBarProvider.claude, claude), (.codex, codex)].compactMap { provider, value in
            guard let value = value, value.isFinite, (0...100).contains(value) else { return nil }
            return MenuBarEntry(provider: provider, percent: Int(value.rounded(.toNearestOrAwayFromZero)))
        }
    }

    static func selectedEntries(claude: MenuBarWindowOption?, codex: MenuBarWindowOption?,
                                claudeIsStale: Bool = false, codexIsStale: Bool = false,
                                claudeUpdatedAt: Date? = nil, codexUpdatedAt: Date? = nil,
                                percentageMode: MenuBarPercentageMode? = nil) -> [MenuBarEntry] {
        [(MenuBarProvider.claude, claude, claudeIsStale, claudeUpdatedAt),
         (.codex, codex, codexIsStale, codexUpdatedAt)].compactMap { provider, option, stale, updated in
            guard let option = option, option.provider == provider,
                  option.percent.isFinite, (0...100).contains(option.percent) else { return nil }
            let displayedPercent = percentageMode == .remaining ? 100 - option.percent : option.percent
            return MenuBarEntry(provider: provider, percent: Int(displayedPercent.rounded(.toNearestOrAwayFromZero)),
                                resetsAt: option.resetsAt, isStale: stale, updatedAt: updated, percentageMode: percentageMode)
        }
    }

    static func resetLabel(resetsAt: Date?, now: Date = Date()) -> String? {
        guard let resetsAt = resetsAt else { return nil }
        let timestamp = resetsAt.timeIntervalSince1970
        let current = now.timeIntervalSince1970
        // Keep arithmetic and integer conversion bounded to supported calendar dates.
        guard timestamp.isFinite, current.isFinite,
              (-62_135_596_800...253_402_300_799).contains(timestamp),
              (-62_135_596_800...253_402_300_799).contains(current) else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "0m" }
        if remaining >= 86_400 { return "\(Int(remaining / 86_400))d" }
        if remaining >= 3_600 { return "\(Int(remaining / 3_600))h" }
        return "\(Int(ceil(remaining / 60)))m"
    }

    private static func updateAge(lastUpdated: Date?, now: Date) -> TimeInterval? {
        guard let updated = lastUpdated else { return nil }
        let timestamp = updated.timeIntervalSince1970
        let current = now.timeIntervalSince1970
        guard timestamp.isFinite, current.isFinite,
              (-62_135_596_800...253_402_300_799).contains(timestamp),
              (-62_135_596_800...253_402_300_799).contains(current) else { return nil }
        return max(0, now.timeIntervalSince(updated))
    }

    static func blurRadius(lastUpdated: Date?, now: Date = Date()) -> CGFloat {
        guard let age = updateAge(lastUpdated: lastUpdated, now: now) else { return 0 }
        return CGFloat(min(1.2, max(0, (age - 600) / 1_200 * 1.2)))
    }

    static func accessibilityLabel(for entries: [MenuBarEntry], now: Date = Date()) -> String {
        guard !entries.isEmpty else { return "LimitFuel: connect Claude or Codex" }
        return entries.map { entry in
            var label = "\(entry.provider == .claude ? "Claude" : "Codex") \(entry.percent)%"
            if let mode = entry.percentageMode { label += " \(mode.rawValue)" }
            if let reset = resetLabel(resetsAt: entry.resetsAt, now: now) { label += ", resets in \(reset)" }
            let age = updateAge(lastUpdated: entry.updatedAt, now: now)
            if entry.isStale || (age ?? 0) > 600 { label += " (last known)" }
            if let age = age {
                if age < 60 { label += ", updated just now" }
                else { label += ", updated \(Int(age / 60)) minutes ago" }
            }
            return label
        }.joined(separator: ", ")
    }

    static func image(for entries: [MenuBarEntry], now: Date = Date(), allowsBlur: Bool = true) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let strings = entries.map { NSAttributedString(string: "\($0.percent)%", attributes: attributes) }
        let textWidths = strings.map { ceil($0.size().width) }
        let badgeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.black
        ]
        let badges = entries.map { entry in
            resetLabel(resetsAt: entry.resetsAt, now: now).map { NSAttributedString(string: $0, attributes: badgeAttributes) }
        }
        let badgeWidths = badges.map { $0.map { ceil($0.size().width) + 8 } ?? 0 }
        let badgeExtents = badgeWidths.map { $0 > 0 ? $0 + 4 : 0 }
        let width: CGFloat = entries.isEmpty ? 18 :
            textWidths.reduce(0, +) + badgeExtents.reduce(0, +) + CGFloat(entries.count) * 22 + CGFloat(entries.count - 1) * 10
        let marks = entries.map { providerMark($0.provider) }
        // Draw at the destination's resolution. lockFocus caches the source at
        // an implicit scale, causing width-dependent edge resampling at 1x/2x.
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // The app icon's two rows of five LEDs, drawn as a template for light
            // and dark menu bars. Outlines preserve the unlit segments at this size.
            if entries.isEmpty {
                for row in 0..<2 {
                    for column in 0..<5 {
                        let rect = NSRect(x: 1 + CGFloat(column) * 3.25,
                                          y: row == 0 ? 10 : 3, width: 2.5, height: 5)
                        let segment = NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8)
                        if column < (row == 0 ? 4 : 2) { segment.fill() }
                        else { segment.lineWidth = 0.65; segment.stroke() }
                    }
                }
            }
            let blurEnabled = allowsBlur && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            var x: CGFloat = 0
            for index in entries.indices {
                if let mark = marks[index] {
                    mark.draw(in: NSRect(x: x, y: 0, width: 18, height: 18),
                              from: .zero, operation: .sourceOver, fraction: 1)
                } else {
                    // Keep the provider identifiable if its resource is missing.
                    let fallback = NSAttributedString(string: entries[index].provider == .claude ? "C" : "O",
                                                      attributes: attributes)
                    fallback.draw(at: NSPoint(x: x + 3, y: floor((18 - fallback.size().height) / 2)))
                }
                let text = strings[index]
                let radius = blurEnabled ? blurRadius(lastUpdated: entries[index].updatedAt, now: now) : 0
                drawText(text, at: NSPoint(x: x + 22, y: floor((18 - text.size().height) / 2)), radius: radius)
                if let badge = badges[index] {
                    let badgeX = x + 22 + textWidths[index] + 4
                    let rect = NSRect(x: badgeX, y: 2, width: badgeWidths[index], height: 14)
                    NSColor.black.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                    NSColor.black.set()
                    drawText(badge, at: NSPoint(x: badgeX + 4, y: floor((18 - badge.size().height) / 2)), radius: radius)
                }
                x += 22 + textWidths[index] + badgeExtents[index] + 10
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawText(_ text: NSAttributedString, at point: NSPoint, radius: CGFloat) {
        guard radius > 0, let destination = NSGraphicsContext.current?.cgContext else {
            text.draw(at: point)
            return
        }
        // Rasterize only glyphs at the destination scale. Four points of transparent
        // padding contain the 1.2pt Gaussian kernel without touching the provider logo.
        let scale = max(1, min(4, hypot(destination.ctm.a, destination.ctm.c)))
        let padding: CGFloat = 4
        let width = ceil(text.size().width) + 2 * padding
        let pixelWidth = Int(ceil(width * scale))
        let pixelHeight = Int(ceil(18 * scale))
        guard let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            text.draw(at: point)
            return
        }
        bitmap.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        text.draw(at: NSPoint(x: padding, y: point.y))
        NSGraphicsContext.restoreGraphicsState()
        guard let storage = bitmap.data else {
            text.draw(at: point)
            return
        }
        // A tiny separable Gaussian over alpha avoids Core Image's OpenCL/GPU
        // dependency. RGB stays black, so the image remains a monochrome template.
        let pixels = storage.assumingMemoryBound(to: UInt8.self)
        let sigma = Double(radius * scale)
        let support = Int(ceil(3 * sigma))
        let weights = (-support...support).map { offset in
            exp(-Double(offset * offset) / (2 * sigma * sigma))
        }
        let weightSum = weights.reduce(0, +)
        let kernel = weights.map { $0 / weightSum }
        var horizontal = [Double](repeating: 0, count: pixelWidth * pixelHeight)
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                var alpha = 0.0
                for offset in -support...support {
                    let sourceX = x + offset
                    if sourceX >= 0 && sourceX < pixelWidth {
                        alpha += Double(pixels[(y * pixelWidth + sourceX) * 4 + 3]) * kernel[offset + support]
                    }
                }
                horizontal[y * pixelWidth + x] = alpha
            }
        }
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                var alpha = 0.0
                for offset in -support...support {
                    let sourceY = y + offset
                    if sourceY >= 0 && sourceY < pixelHeight {
                        alpha += horizontal[sourceY * pixelWidth + x] * kernel[offset + support]
                    }
                }
                let index = (y * pixelWidth + x) * 4
                pixels[index] = 0
                pixels[index + 1] = 0
                pixels[index + 2] = 0
                pixels[index + 3] = UInt8(min(255, max(0, alpha.rounded())))
            }
        }
        guard let output = bitmap.makeImage() else {
            text.draw(at: point)
            return
        }
        destination.saveGState()
        // Clip explicitly at the text layer's padded boundary (18pt for the
        // percentage), preventing image sampling from reaching logo pixels at 2x.
        destination.clip(to: CGRect(x: point.x - padding, y: 0, width: width, height: 18))
        destination.interpolationQuality = .none
        destination.draw(output, in: CGRect(x: point.x - padding, y: 0,
            width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale))
        destination.restoreGState()
    }

    private static func providerMark(_ provider: MenuBarProvider) -> NSImage? {
        let name = provider == .claude ? "ClaudeMark" : "OpenAIMark"
        let directory = ProcessInfo.processInfo.environment["LIMITFUEL_ASSET_DIR"]
        let url = directory.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".pdf") }
            ?? Bundle.main.url(forResource: name, withExtension: "pdf")
        return url.flatMap { NSImage(contentsOf: $0) }
    }
}
