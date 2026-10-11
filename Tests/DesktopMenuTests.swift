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
        check(image.size.width > emptyImage.size.width, "connected providers and percentages occupy visible width")
        let invalid = MenuBarStatus.entries(claude: .nan, codex: .infinity)
        check(invalid.isEmpty, "nonfinite usage excluded")
        check(MenuBarStatus.entries(claude: -1, codex: 101).isEmpty, "out of range excluded")
        // User-spec correction: the app mark is present only when disconnected.
        // Connected states use their actual provider PDF marks, at both scales.
        func rasterAtScale(_ source: NSImage, scale: Int) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(source.size.width)) * scale, pixelsHigh: 18 * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = source.size
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = context
            // rep.size defines the point-to-pixel transform at both scales.
            source.draw(in: NSRect(origin: .zero, size: source.size))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
            rep.colorAt(x: x, y: y)!.alphaComponent
        }
        func difference(_ a: NSBitmapImageRep, _ ax: Int,
                        _ b: NSBitmapImageRep, _ bx: Int, _ scale: Int) -> CGFloat {
            var error: CGFloat = 0
            for y in 0..<(18 * scale) { for x in 0..<(18 * scale) {
                error += abs(alpha(a,ax+x,y)-alpha(b,bx+x,y))
            } }
            return error / CGFloat(18 * 18 * scale * scale)
        }
        let assetRoot = ProcessInfo.processInfo.environment["LIMITFUEL_ASSET_DIR"]
            ?? "/Users/slava/Documents/GitHub/LimitFuel-desktop-fixes/app/Assets"
        func providerPDF(_ filename: String) -> NSImage {
            guard let pdf = NSImage(contentsOfFile: assetRoot + "/" + filename) else {
                fatalError("Missing provider reference PDF: " + filename)
            }
            pdf.size = NSSize(width:18,height:18)
            return pdf
        }
        let claudePDF = providerPDF("ClaudeMark.pdf")
        let codexPDF = providerPDF("OpenAIMark.pdf")
        for scale in [1,2] {
            let emptyRaster = rasterAtScale(emptyImage,scale:scale)
            var ink = 0
            for y in 0..<(18*scale) { for x in 0..<min(18*scale,emptyRaster.pixelsWide) {
                if alpha(emptyRaster,x,y) > 0.1 { ink += 1 }
            } }
            check(ink > 10*scale*scale,"visible app mark")
            let claudeReference = rasterAtScale(claudePDF,scale:scale)
            let codexReference = rasterAtScale(codexPDF,scale:scale)
            check(difference(claudeReference,0,codexReference,0,scale) > 0.05,
                  "provider references are visibly distinct")
            for percent in [0.0,9,50,100] {
                let claudeSingle = MenuBarStatus.image(for: MenuBarStatus.entries(claude:percent,codex:nil))
                let codexSingle = MenuBarStatus.image(for: MenuBarStatus.entries(claude:nil,codex:percent))
                let combined = MenuBarStatus.image(for: MenuBarStatus.entries(claude:percent,codex:percent))
                for source in [claudeSingle,codexSingle,combined] {
                    check(source.isTemplate && source.size.height == 18,"provider image template height")
                    check(source.size.width > 18,"provider percentage has space after logo")
                }
                let c = rasterAtScale(claudeSingle,scale:scale)
                let o = rasterAtScale(codexSingle,scale:scale)
                let b = rasterAtScale(combined,scale:scale)
                check(difference(c,0,claudeReference,0,scale) < 0.06,"Claude first mark matches PDF")
                check(difference(o,0,codexReference,0,scale) < 0.06,"Codex first mark matches OpenAI PDF")
                check(difference(b,0,c,0,scale) < 0.01,"Claude mark consistent across singleton/both widths")
                check(difference(c,0,o,0,scale) > 0.05,"connected provider marks remain distinct")
                // Spacing is unspecified. Search every legal 18pt slice after the
                // first mark for the same OpenAI shape independently of layout code.
                var best: CGFloat = 1
                var bestConsistency: CGFloat = 1
                if b.pixelsWide >= 36*scale {
                    for x in (18*scale)...(b.pixelsWide-18*scale) {
                        best = min(best,difference(b,x,codexReference,0,scale))
                        bestConsistency = min(bestConsistency,difference(b,x,o,0,scale))
                    }
                }
                check(best < 0.06,"second connected provider includes OpenAI PDF mark")
                check(bestConsistency < 0.01,"OpenAI mark consistent across singleton/both widths")
            }
        }
        print("Menu acceptance passed")
    }
}
