import AppKit
import Foundation

// Spec-only acceptance runner. Compile together with app/MenuBarStatus.swift.
// Generated workload: LCG seed 0x4C_49_4D_49_54, 256 pairs; no network or timers.
@main
struct MenuBarStatusAcceptanceTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Acceptance failure: \(message)") }
    }

    static func expected(_ value: Double?) -> Int? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return Int(value.rounded(.toNearestOrAwayFromZero))
    }

    static func check(_ claude: Double?, _ codex: Double?) {
        var wanted: [MenuBarEntry] = []
        if let percent = expected(claude) {
            wanted.append(MenuBarEntry(provider: .claude, percent: percent))
        }
        if let percent = expected(codex) {
            wanted.append(MenuBarEntry(provider: .codex, percent: percent))
        }
        let actual = MenuBarStatus.entries(claude: claude, codex: codex)
        require(actual == wanted, "entries for Claude \(String(describing: claude)), Codex \(String(describing: codex))")
        let label = wanted.isEmpty ? "LimitFuel: connect Claude or Codex" : wanted.map {
            "\($0.provider == .claude ? "Claude" : "Codex") \($0.percent)%"
        }.joined(separator: ", ")
        require(MenuBarStatus.accessibilityLabel(for: actual) == label, "accessible label: \(label)")
    }

    static func main() {
        let fixtures: [Double?] = [nil, -.infinity, .infinity, .nan,
            -100, -0.001, -Double.leastNonzeroMagnitude, -0.0, 0,
            Double.leastNonzeroMagnitude, 0.49, 0.5, 0.51, 1.5,
            44.49, 44.5, 45, 81.5, 82, 99.49, 99.5, 100,
            100.000001, 101, Double.greatestFiniteMagnitude]
        for claude in fixtures {
            for codex in fixtures { check(claude, codex) }
        }
        require(MenuBarStatus.entries(claude: 44.5, codex: 81.5) == [
            MenuBarEntry(provider: .claude, percent: 45),
            MenuBarEntry(provider: .codex, percent: 82)
        ], "fixed order and half rounding")
        require(MenuBarStatus.accessibilityLabel(for: MenuBarStatus.entries(claude: 45, codex: 82)) == "Claude 45%, Codex 82%", "literal combined label")

        var state: UInt64 = 0x4C_49_4D_49_54
        func next() -> Double? {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            if state % 13 == 0 { return nil }
            return Double(Int((state >> 16) % 140_001) - 20_000) / 1000
        }
        for _ in 0..<256 { check(next(), next()) }

        // Alternating snapshots must drop formerly present providers immediately.
        for _ in 0..<8 {
            check(45, 82); check(nil, 82); check(45, nil); check(nil, nil)
            check(100, 100); check(.nan, 0); check(0, .infinity); check(nil, nil)
        }

        _ = NSApplication.shared
        let snapshots: [(Double?, Double?)] = [(nil, nil), (0, nil),
            (nil, 0), (100, nil), (nil, 100), (0, 0), (100, 100), (45, 82)]
        var widths: [CGFloat] = []
        for (claude, codex) in snapshots {
            let entries = MenuBarStatus.entries(claude: claude, codex: codex)
            let image = MenuBarStatus.image(for: entries)
            require(image.isTemplate, "image must be monochrome template")
            require(image.size.width.isFinite && image.size.width > 0, "positive finite image width")
            require(image.size.height == 18, "image height is 18 points")
            // A representation must exist; metadata alone does not prove rendering.
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else {
                fatalError("Rendering unavailable: cannot obtain image pixels; report headless limitation, do not count this as passing")
            }
            require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "nonempty raster representation")
            widths.append(image.size.width)
        }
        require(widths[5] > max(widths[1], widths[2]), "both zero-percent pairs wider than either singleton")
        require(widths[6] > max(widths[3], widths[4]), "both 100-percent pairs wider than either singleton")
        require(widths[3] >= widths[1] && widths[4] >= widths[2], "100-percent singleton receives sufficient width")
        print("MenuBarStatus acceptance passed: 625 fixture pairs, 256 generated pairs (seed 0x4C494D4954), 64 transition snapshots, 8 rendered snapshots.")
    }
}
