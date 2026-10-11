import AppKit
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main struct PopupAcceptance {
    static func main() {
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, -0.001, 100.001]
        for a in invalid { for b in invalid {
            require(MenuBarStatus.entries(claude: a, codex: b).isEmpty, "Invalid percentages must be absent")
        } }
        let cases: [(Double, Int)] = [(0,0), (0.49,0), (0.5,1), (49.5,50), (99.5,100), (100,100)]
        for (value, rounded) in cases {
            let c = MenuBarStatus.entries(claude: value, codex: nil)
            require(c == [MenuBarEntry(provider: .claude, percent: rounded)], "Claude rounding or zero availability")
            let o = MenuBarStatus.entries(claude: nil, codex: value)
            require(o == [MenuBarEntry(provider: .codex, percent: rounded)], "Codex rounding or zero availability")
            for bad in invalid {
                require(MenuBarStatus.entries(claude: value, codex: bad) == c, "Unavailable Codex leaks")
                require(MenuBarStatus.entries(claude: bad, codex: value) == o, "Unavailable Claude leaks")
            }
        }
        let states: [(Double?, Double?)] = [(nil,nil),(0,nil),(nil,0),(12,87),(100,100)]
        for first in states { for next in states {
            _ = MenuBarStatus.entries(claude: first.0, codex: first.1)
            let actual = MenuBarStatus.entries(claude: next.0, codex: next.1)
            let expected = ([next.0.map { MenuBarEntry(provider: .claude, percent: Int($0.rounded())) }, next.1.map { MenuBarEntry(provider: .codex, percent: Int($0.rounded())) }]).compactMap { $0 }
            require(actual == expected, "Transition retained stale provider state")
        } }
        require(MenuBarStatus.accessibilityLabel(for: []) == "LimitFuel: connect Claude or Codex", "Empty accessibility label")
        let both = MenuBarStatus.entries(claude: 12, codex: 87)
        let label = MenuBarStatus.accessibilityLabel(for: both)
        require(label.contains("Claude") && label.contains("12%") && label.contains("Codex") && label.contains("87%"), "Accessible provider values")
        require(label.range(of: "Claude")!.lowerBound < label.range(of: "Codex")!.lowerBound, "Accessible provider order")
        windows()
        geometry()
        rendering()
        print("Popup acceptance passed: states, windows, 4096 seeded geometry cases, provider rendering at 1x/2x")
    }

    static func windows() {
        let fixtures = [CodexWindow(usedPercent: 0, windowDurationMins: nil, resetsAt: nil), CodexWindow(usedPercent: 100, windowDurationMins: 10080, resetsAt: Date(timeIntervalSince1970: 123456))]
        for p in [nil] + fixtures.map(Optional.some) { for s in [nil] + fixtures.map(Optional.some) {
            let result = CodexBucket(id: "fixture", name: "Offline", primary: p, secondary: s).displayWindows
            require(result.map(\.id) == (p == nil ? [] : ["primary"]) + (s == nil ? [] : ["secondary"]), "Missing window role/order")
            require(result.map(\.window) == [p,s].compactMap { $0 }, "Window metadata or real zero lost")
        } }
    }

    static func geometry() {
        func expected(_ c: CGFloat, _ a: CGFloat) -> CGFloat {
            let cap = a.isFinite && a > 0 ? min(a,600) : 600
            let desired = c.isFinite && c > 0 ? c : 250
            return min(cap,max(100,desired))
        }
        let edges: [CGFloat] = [.nan,.infinity,-.infinity,-100,0,0.001,50,99,100,250,599,600,601,100000]
        func check(_ c: CGFloat, _ a: CGFloat) {
            let h = PopupLayout.viewportHeight(contentHeight: c, availableHeight: a)
            require(h.isFinite && h > 0 && abs(h-expected(c,a)) < 0.000001, "Viewport policy c=\(c) a=\(a) got=\(h)")
            require(h == PopupLayout.viewportHeight(contentHeight: c, availableHeight: a), "Repeated geometry oscillates")
        }
        for c in edges { for a in edges { check(c,a) } }
        var seed: UInt64 = 0x4C494D4954465545
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 11) / CGFloat(UInt64.max >> 11) * 20000 - 1000
        }
        for _ in 0..<4096 { check(random(),random()) }
        for a: CGFloat in [30,100,400,600,1200] {
            var previous: CGFloat = 0
            for c in stride(from: CGFloat(1), through: 2000, by: 7) {
                let value = PopupLayout.viewportHeight(contentHeight: c, availableHeight: a)
                require(value >= previous, "Growing content shrinks viewport")
                previous = value
            }
        }
    }

    static func raster(_ image: NSImage, scale: Int) -> NSBitmapImageRep {
        let w = Int(ceil(image.size.width)) * scale, h = Int(ceil(image.size.height)) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    // Normalize visible alpha bounds, making comparison independent of PDF padding.
    static func mask(_ rep: NSBitmapImageRep, width: Int) -> [Bool] {
        var pixels: [(Int,Int)] = []
        for y in 0..<rep.pixelsHigh { for x in 0..<min(width,rep.pixelsWide) {
            if (rep.colorAt(x: x,y: y)?.alphaComponent ?? 0) > 0.35 { pixels.append((x,y)) }
        } }
        require(!pixels.isEmpty,"Provider mark has no visible pixels")
        let x0 = pixels.map{$0.0}.min()!, x1 = pixels.map{$0.0}.max()!
        let y0 = pixels.map{$0.1}.min()!, y1 = pixels.map{$0.1}.max()!
        var result = Array(repeating:false,count:32*32)
        for (x,y) in pixels {
            let xx = min(31,(x-x0)*32/max(1,x1-x0+1)), yy = min(31,(y-y0)*32/max(1,y1-y0+1))
            result[yy*32+xx] = true
        }
        return result
    }
    static func similarity(_ a: [Bool],_ b: [Bool]) -> Double {
        let union = zip(a,b).filter{$0 || $1}.count
        return Double(zip(a,b).filter{$0 && $1}.count)/Double(max(1,union))
    }
    static func rendering() {
        let root = ProcessInfo.processInfo.environment["LIMITFUEL_ASSET_DIR"] ?? "/Users/slava/Documents/GitHub/LimitFuel-desktop-fixes/app/Assets"
        for scale in [1,2] {
            var reference: [String:[Bool]] = [:]
            for (name,file) in [("claude","ClaudeMark.pdf"),("codex","OpenAIMark.pdf")] {
                let image = NSImage(contentsOfFile: root + "/" + file)!
                image.size = NSSize(width:18,height:18)
                reference[name] = mask(raster(image,scale:scale),width:18*scale)
            }
            require(similarity(reference["claude"]!,reference["codex"]!) < 0.85,"Provider fixtures must be visibly distinct")
            for entries in [[], MenuBarStatus.entries(claude:0,codex:nil),MenuBarStatus.entries(claude:nil,codex:100),MenuBarStatus.entries(claude:12,codex:87)] {
                let image = MenuBarStatus.image(for:entries)
                require(image.isTemplate,"Menu image must be template")
                require(image.size.height == 18 && image.size.width > 0,"Menu image geometry")
                let rep = raster(image,scale:scale)
                let actual = mask(rep,width:18*scale)
                if let first = entries.first {
                    let expected = reference[first.provider.rawValue]!
                    require(similarity(actual,expected) >= 0.65,"First mark must match provider PDF rather than app mark")
                    require(image.size.width > 18,"Connected percentage missing")
                }
                if let tmp = ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] {
                    let name = entries.map{ $0.provider.rawValue }.joined(separator:"-")
                    try! rep.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath:tmp).appendingPathComponent("menu-\(name.isEmpty ? "empty" : name)-\(scale)x.png"))
                }
            }
        }
    }
}
