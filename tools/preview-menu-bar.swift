import AppKit

@main
struct PreviewMenuBar {
    static func main() throws {
        _ = NSApplication.shared
        let rows: [(String, Double?, Double?)] = [
            ("Both connected", 45, 82), ("Claude only", 45, nil),
            ("Codex only", nil, 82), ("Neither connected", nil, nil),
            ("At limit", 100, 100), ("Zero usage", 0, 0)
        ]
        for dark in [false, true] {
            let preview = NSImage(size: NSSize(width: 600, height: 310))
            preview.lockFocus()
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: 600, height: 310).fill()
            let foreground = dark ? NSColor.white : NSColor.black
            for (index, row) in rows.enumerated() {
                let y = CGFloat(265 - index * 47)
                (row.0 as NSString).draw(at: NSPoint(x: 20, y: y + 6), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 15), .foregroundColor: foreground])
                let image = MenuBarStatus.image(for: MenuBarStatus.entries(claude: row.1, codex: row.2))
                let tinted = NSImage(size: image.size)
                tinted.lockFocus()
                foreground.setFill()
                NSRect(origin: .zero, size: image.size).fill()
                image.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
                tinted.unlockFocus()
                tinted.draw(in: NSRect(x: 210, y: y, width: image.size.width * 2, height: 36))
            }
            preview.unlockFocus()
            let bitmap = NSBitmapImageRep(data: preview.tiffRepresentation!)!
            let path = "/private/tmp/limitfuel-menubar-\(dark ? "dark" : "light").png"
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            print(path)
        }
    }
}
