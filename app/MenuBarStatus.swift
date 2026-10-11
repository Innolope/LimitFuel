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
        let pairWidths = strings.map { ceil($0.size().width) + 20 }
        let width = entries.isEmpty ? 18 : pairWidths.reduce(0, +) + CGFloat(max(0, entries.count - 1)) * 10
        let image = NSImage(size: NSSize(width: width, height: 18))
        image.lockFocus()
        var x: CGFloat = 0
        if entries.isEmpty {
            NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)?.draw(in: NSRect(x: 1, y: 1, width: 16, height: 16))
        }
        for (index, entry) in entries.enumerated() {
            let name = entry.provider == .claude ? "ClaudeMark" : "OpenAIMark"
            // Bundled PDFs preserve vector geometry and need no network access.
            let icon = Bundle.main.url(forResource: name, withExtension: "pdf").flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Assets/\(name).pdf").path)
            icon?.draw(in: NSRect(x: x, y: 1, width: 16, height: 16))
            let text = strings[index]
            text.draw(at: NSPoint(x: x + 20, y: floor((18 - text.size().height) / 2)))
            x += pairWidths[index] + 10
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
