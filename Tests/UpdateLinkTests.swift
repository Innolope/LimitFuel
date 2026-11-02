import Foundation

fileprivate func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("Acceptance failure: \(message)") }
}

// Update banner links: https only, and only hosts LimitFuel controls or trusts.
@main
struct UpdateLinkTests {
    static func safe(_ text: String) -> Bool { UpdateManager.isSafeURL(URL(string: text)!) }

    static func main() {
        check(safe("https://download.innolope.com/limitfuel/LimitFuel.dmg"), "installer host is allowed")
        check(safe("https://github.com/Innolope/LimitFuel"), "GitHub stays allowed")
        check(safe("https://claudeusagebar.com"), "upstream site stays allowed")
        check(!safe("http://download.innolope.com/limitfuel/LimitFuel.dmg"), "plain http is refused")
        check(!safe("https://innolope.com/limitfuel"), "only the download host of innolope.com is allowed")
        check(!safe("https://evil-download.innolope.com/LimitFuel.dmg"), "a lookalike subdomain is refused")
        check(!safe("https://download.innolope.com.example.net/LimitFuel.dmg"), "a lookalike domain is refused")
        print("UpdateLinkTests passed")
    }
}
