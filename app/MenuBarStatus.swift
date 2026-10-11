import AppKit

enum MenuBarProvider: String { case claude, codex }

struct MenuBarEntry: Equatable {
    let provider: MenuBarProvider
    let percent: Int
}

enum MenuBarStatus {
    static func entries(claude: Double?, codex: Double?) -> [MenuBarEntry] {
        [(MenuBarProvider.claude, claude), (.codex, codex)].compactMap { provider, value in
            guard let value = value, value.isFinite, (0...100).contains(value) else { return nil }
            return MenuBarEntry(provider: provider, percent: Int(value.rounded(.toNearestOrAwayFromZero)))
        }
    }

    static func accessibilityLabel(for entries: [MenuBarEntry]) -> String {
        guard !entries.isEmpty else { return "LimitFuel: connect Claude or Codex" }
        return entries.map { "\($0.provider == .claude ? "Claude" : "Codex") \($0.percent)%" }.joined(separator: ", ")
    }

    static func image(for entries: [MenuBarEntry]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let strings = entries.map { NSAttributedString(string: "\($0.percent)%", attributes: attributes) }
        let textWidths = strings.map { ceil($0.size().width) }
        let width: CGFloat = entries.isEmpty ? 18 :
            textWidths.reduce(0, +) + CGFloat(entries.count) * 22 + CGFloat(entries.count - 1) * 10
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
                text.draw(at: NSPoint(x: x + 22, y: floor((18 - text.size().height) / 2)))
                x += 22 + textWidths[index] + 10
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func providerMark(_ provider: MenuBarProvider) -> NSImage? {
        let name = provider == .claude ? "ClaudeMark" : "OpenAIMark"
        let directory = ProcessInfo.processInfo.environment["LIMITFUEL_ASSET_DIR"]
        let url = directory.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".pdf") }
            ?? Bundle.main.url(forResource: name, withExtension: "pdf")
        return url.flatMap { NSImage(contentsOf: $0) }
    }
}
