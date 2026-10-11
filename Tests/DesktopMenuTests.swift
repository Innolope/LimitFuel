import Foundation
import AppKit
private func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
@main struct MenuAcceptance {
    static func main() {
        let empty = MenuBarStatus.entries(claude: nil, codex: nil)
        check(empty.isEmpty, "missing usage has no fake zero")
        let emptyImage = MenuBarStatus.image(for: empty)
        check(emptyImage.isTemplate && emptyImage.size.height == 18, "empty mark is 18pt template")
        check(emptyImage.size.width > 0, "empty state retains app mark")
        let entries = MenuBarStatus.entries(claude: 49.6, codex: 75)
        check(entries.count == 2, "both providers appear")
        check(entries[0].percent == 50 && entries[1].percent == 75, "stable ordering and rounding")
        switch entries[0].provider { case .claude: break; default: fatalError("Claude first") }
        switch entries[1].provider { case .codex: break; default: fatalError("Codex second") }
        let label = MenuBarStatus.accessibilityLabel(for: entries)
        check(label.localizedCaseInsensitiveContains("claude") && label.localizedCaseInsensitiveContains("codex"), "accessibility names providers")
        let image = MenuBarStatus.image(for: entries)
        check(image.isTemplate && image.size.height == 18, "filled image template height")
        check(image.size.width > emptyImage.size.width, "percentages follow persistent mark")
        let invalid = MenuBarStatus.entries(claude: .nan, codex: .infinity)
        check(invalid.isEmpty, "nonfinite usage excluded")
        check(MenuBarStatus.entries(claude: -1, codex: 101).isEmpty, "out of range excluded")
        // Rasterize at one pixel per point. At x<18 the app mark must be identical
        // regardless of provider availability. Separate provider logos violate this.
        func raster(_ source: NSImage) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(source.size.width), pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(origin: .zero, size: source.size))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        let mark = raster(emptyImage), filled = raster(image)
        var ink = 0
        for y in 0..<18 { for x in 0..<min(18,mark.pixelsWide) {
            let a = mark.colorAt(x: x, y: y)!.alphaComponent
            let b = filled.colorAt(x: x, y: y)!.alphaComponent
            check(abs(a-b) < 0.03,
                  "same single app mark with every provider state: x=\(x), y=\(y), emptyAlpha=\(a), filledAlpha=\(b), "
                    + "emptyRepresentations=\(emptyImage.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh) points=\($0.size)" }), "
                    + "filledRepresentations=\(image.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh) points=\($0.size)" })")
            if a > 0.1 { ink += 1 }
        } }
        check(ink > 10, "visible app mark")
        // Draw into explicit destination scales to keep the app mark stable on
        // ordinary and Retina menu bars, regardless of the percentage text width.
        func rasterAtScale(_ source: NSImage, scale: Int) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: Int(source.size.width) * scale,
                                       pixelsHigh: 18 * scale, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = source.size
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            source.draw(in: NSRect(origin: .zero, size: source.size))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        for scale in [1, 2] {
            let scaledMark = rasterAtScale(emptyImage, scale: scale)
            let scaledFilled = rasterAtScale(image, scale: scale)
            for y in 0..<(18 * scale) { for x in 0..<(18 * scale) {
                let a = scaledMark.colorAt(x: x, y: y)!.alphaComponent
                let b = scaledFilled.colorAt(x: x, y: y)!.alphaComponent
                check(abs(a-b) < 0.03,
                      "same app mark at destination scale=\(scale): x=\(x), y=\(y), emptyAlpha=\(a), filledAlpha=\(b)")
            } }
        }
        print("Menu acceptance passed")
    }
}
