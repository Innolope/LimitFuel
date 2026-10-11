import Foundation
import CommonCrypto
import SQLite3

// Spec-authored acceptance tests. Fuzz seed 0xC0FFEE; 512 invalid headers.
// All credentials are synthetic. All storage is disposable; no Keychain calls.
private enum TestError: Error { case fixture(String), denied }
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let password = Data("synthetic-test-password".utf8)
private var checks = 0
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    checks += 1
    do {
        if try !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    } catch { fputs("FAIL: \(message): \(error)\n", stderr); exit(1) }
}
private func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); check(false, message) } catch { checks += 1 }
}
private func exec(_ db: OpaquePointer?, _ sql: String) throws {
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
        throw TestError.fixture(String(cString: sqlite3_errmsg(db)))
    }
}
private struct Row {
    var host = ".claude.ai"
    var name = "sessionKey"
    var value = "synthetic-session"
    var encrypted = Data()
    var path = "/"
    var expiry: Int64 = 0
    var secure = 1
    var partition = ""
}
private func database(_ root: URL, _ profile: String = "Default", network: Bool = false, version: Int = 23, rows: [Row]) throws -> URL {
    let folder = root.appendingPathComponent(profile).appendingPathComponent(network ? "Network" : "")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("Cookies")
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw TestError.fixture("open") }
    defer { sqlite3_close(db) }
    try exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO meta VALUES('version','\(version)'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,top_frame_site_key TEXT)")
    for row in rows {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES(?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw TestError.fixture("prepare") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, row.host, -1, transient)
        sqlite3_bind_text(statement, 2, row.name, -1, transient)
        sqlite3_bind_text(statement, 3, row.value, -1, transient)
        _ = row.encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_text(statement, 5, row.path, -1, transient)
        sqlite3_bind_int64(statement, 6, row.expiry)
        sqlite3_bind_int(statement, 7, Int32(row.secure))
        sqlite3_bind_text(statement, 8, row.partition, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError.fixture("insert") }
    }
    return url
}
private func encrypt(_ payload: Data) throws -> Data {
    var key = [UInt8](repeating: 0, count: 16)
    let salt = Array("saltysalt".utf8)
    let status = password.withUnsafeBytes { bytes in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
    }
    guard status == kCCSuccess else { throw TestError.fixture("derive") }
    let iv = [UInt8](repeating: 32, count: 16)
    var output = [UInt8](repeating: 0, count: payload.count + 16)
    var written = 0
    let capacity = output.count
    let result = payload.withUnsafeBytes { bytes in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, bytes.baseAddress, payload.count, &output, capacity, &written)
    }
    guard result == kCCSuccess else { throw TestError.fixture("encrypt") }
    return Data("v10".utf8) + Data(output.prefix(written))
}
private func hash(_ host: String) -> Data {
    let bytes = Data(host.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = bytes.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(bytes.count), &digest) }
    return Data(digest)
}

@main struct AcceptanceTests {
    static func main() throws {
        let fixtureRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? "/private/tmp", isDirectory: true)
        let base = fixtureRoot.appendingPathComponent("chrome-cookie-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var serial = 0
        func root() throws -> URL {
            serial += 1
            let url = base.appendingPathComponent("case-\(serial)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func reader(_ url: URL) -> ChromeCookieReader { ChromeCookieReader(root: url, passwordProvider: { _ in password }) }
        func fields(_ session: ChromeSession) -> Set<String> {
            Set(session.cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        check(RefreshSchedule.usageInterval == 60, "minute usage interval")
        check(RefreshSchedule.cookieInterval == 3600, "hourly cookie interval")
        check(RefreshSchedule.updateInterval == 10800, "independent update interval")
        check(RefreshSchedule.fastUsageInterval == 12, "adaptive fast interval")
        let pollingNow = Date(timeIntervalSince1970: 1_800_000_000)
        func interval(_ percent: Double?, _ duration: Int? = 300, _ reset: Date? = nil) -> TimeInterval {
            RefreshSchedule.pollingInterval(usedPercent: percent, windowDurationMins: duration, resetsAt: reset, now: pollingNow)
        }
        for percent: Double? in [nil, 0, 89.99, 90, .nan, .infinity, -.infinity] {
            check(interval(percent) == 60, "normal polling for missing/nonfinite/below or at threshold")
        }
        check(interval(90.0001) == 12, "strictly above threshold accelerates")
        check(interval(100, 300, pollingNow.addingTimeInterval(1)) == 12, "future reset permits fast polling")
        check(interval(100, 300, pollingNow) == 60, "exact reset restores normal despite stale usage")
        check(interval(100, 300, pollingNow.addingTimeInterval(-1)) == 60, "past reset restores normal despite stale usage")
        for duration: Int? in [nil, 0, 60, 299, 301, 10080] {
            check(interval(99, duration) == 60, "only exact five-hour window accelerates")
        }
        check(RefreshSchedule.cookieInterval == 3600, "adaptive usage policy preserves hourly cookie sync")
        for cadence in [12.0, 60.0] {
            check(RefreshSchedule.nextPollDelay(interval: cadence, lastStartedAt: pollingNow, now: pollingNow.addingTimeInterval(5)) == cadence - 5, "cadence subtracts elapsed request time")
            check(RefreshSchedule.nextPollDelay(interval: cadence, lastStartedAt: pollingNow, now: pollingNow) == cadence, "request start keeps complete cadence interval")
            check(RefreshSchedule.nextPollDelay(interval: cadence, lastStartedAt: nil, now: pollingNow) == cadence, "missing request start uses complete interval")
            check(RefreshSchedule.nextPollDelay(interval: cadence, lastStartedAt: pollingNow, now: pollingNow.addingTimeInterval(cadence + 5)) == 1, "overdue request schedules minimum one second")
        }

        check(ChromeCookieReader.validateHeader("sessionKey=abc"), "minimal header")
        check(ChromeCookieReader.validateHeader("other=a=b; sessionKey=abc=="), "equals in values")
        for bad in ["", "sessionKey=", "x=y", "sessionKey=a; sessionKey=b", "sessionKey=a\r\nX-Evil: yes", "sessionKey=a\u{0}", "sessionKey=é", "sessionKey=a; invalid", "sessionKey=a; =b"] {
            check(!ChromeCookieReader.validateHeader(bad), "reject invalid header \(bad.debugDescription)")
        }
        check(ChromeCookieReader.validateHeader("sessionKey=" + String(repeating: "a", count: 16373)), "exact 16KiB header accepted")
        check(!ChromeCookieReader.validateHeader("sessionKey=" + String(repeating: "a", count: 16374)), "over 16KiB rejected")
        var seed: UInt64 = 0xC0FFEE
        let invalidScalars: [UInt32] = Array(0...31) + [127, 128, 233, 0x2028]
        for _ in 0..<512 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let scalar = UnicodeScalar(invalidScalars[Int(seed % UInt64(invalidScalars.count))])!
            check(!ChromeCookieReader.validateHeader("sessionKey=abc\(Character(scalar))def"), "fuzz control/non-ASCII rejection; seed C0FFEE")
        }

        let cipher = try encrypt(Data("synthetic=token".utf8))
        check(try ChromeCookieReader.decrypt(cipher, host: ".claude.ai", version: 23, password: password) == "synthetic=token", "v10 decrypt")
        let bound = try encrypt(hash(".claude.ai") + Data("bound-token".utf8))
        check(try ChromeCookieReader.decrypt(bound, host: ".claude.ai", version: 24, password: password) == "bound-token", "v24 domain binding")
        rejects("wrong host hash") { _ = try ChromeCookieReader.decrypt(bound, host: "claude.ai", version: 24, password: password) }
        rejects("future version still validates hash") { _ = try ChromeCookieReader.decrypt(cipher, host: ".claude.ai", version: 25, password: password) }
        rejects("unknown prefix") { _ = try ChromeCookieReader.decrypt(Data("v20".utf8) + cipher.dropFirst(3), host: ".claude.ai", version: 23, password: password) }
        rejects("truncated block") { _ = try ChromeCookieReader.decrypt(cipher.dropLast(), host: ".claude.ai", version: 23, password: password) }
        rejects("invalid padding") { _ = try ChromeCookieReader.decrypt(Data("v10".utf8) + Data(repeating: 0, count: 16), host: ".claude.ai", version: 23, password: password) }
        let nonUTF8 = try encrypt(Data([0xff, 0xfe]))
        rejects("invalid UTF8") { _ = try ChromeCookieReader.decrypt(nonUTF8, host: ".claude.ai", version: 23, password: password) }

        let absent = base.appendingPathComponent("absent")
        check(try reader(absent).discover().isEmpty, "absent Chrome gives no sessions")
        let empty = try root()
        check(try reader(empty).discover().isEmpty, "empty Chrome root")
        for invalid in ["../Default", "/Default", "Default/../Profile 1", "", "Profile -1", "Other", "Default\u{0}"] {
            rejects("invalid profile ID \(invalid.debugDescription)") { _ = try reader(empty).discover(profileID: invalid) }
        }
        let multi = try root()
        _ = try database(multi, rows: [Row()])
        _ = try database(multi, "Profile 1", network: true, rows: [Row(value: "second-session")])
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Person A"},"Profile 1":{"name":"Person B"}}}}"#.utf8).write(to: multi.appendingPathComponent("Local State"))
        let sessions = try reader(multi).discover()
        check(sessions.count == 2, "discover every signed-in profile")
        check(Set(sessions.map { $0.profile.id }) == ["Default", "Profile 1"], "profile identities")
        check(Set(sessions.map { $0.profile.name }) == ["Person A", "Person B"], "Local State display names")
        let pinned = try reader(multi).discover(profileID: "Profile 1")
        check(pinned.count == 1 && pinned[0].profile.id == "Profile 1", "pinned profile selection")

        let filterRoot = try root()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let chromeNow = Int64((now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        _ = try database(filterRoot, rows: [Row(), Row(host: "claude.ai", name: "api", value: "ok", path: "/api"), Row(name: "apiSlash", path: "/api/", expiry: chromeNow + 1_000_000), Row(host: "evilclaude.ai", name: "evil"), Row(host: ".claude.ai.evil", name: "evil2"), Row(name: "expired", expiry: chromeNow - 1), Row(name: "exactExpiry", expiry: chromeNow), Row(name: "partitioned", partition: "https://other.example"), Row(name: "wrongPath", path: "/account"), Row(name: "nearPath", path: "/ap")])
        let filtered = try reader(filterRoot).discover(now: now)
        check(filtered.count == 1, "filtered session exists")
        check(fields(filtered[0]) == ["sessionKey=synthetic-session", "api=ok", "apiSlash=synthetic-session"], "domain expiry partition path filtering")
        let noSession = try root()
        _ = try database(noSession, rows: [Row(name: "other")])
        check(try reader(noSession).discover().isEmpty, "missing session is not a login")
        let encryptedRoot = try root()
        _ = try database(encryptedRoot, version: 24, rows: [Row(value: "", encrypted: bound)])
        var interactions: [Bool] = []
        let injected = ChromeCookieReader(root: encryptedRoot, passwordProvider: { interaction in interactions.append(interaction); return password })
        check(try injected.discover().first?.cookieHeader == "sessionKey=bound-token", "encrypted DB cookie")
        check(!interactions.isEmpty && interactions.allSatisfy { !$0 }, "background Keychain interaction disabled")
        interactions.removeAll()
        _ = try injected.discover(allowInteraction: true)
        check(!interactions.isEmpty && interactions.allSatisfy { $0 }, "explicit interaction passed to provider")
        rejects("Keychain denial propagates") { _ = try ChromeCookieReader(root: encryptedRoot, passwordProvider: { _ in throw TestError.denied }).discover() }

        for count in [128, 129] {
            let countRoot = try root()
            var rows = [Row()]
            rows += (1..<count).map { Row(name: "cookie\($0)") }
            _ = try database(countRoot, rows: rows)
            if count == 128 { check(try reader(countRoot).discover().count == 1, "128 eligible rows accepted") }
            else { rejects("129 eligible rows rejected") { _ = try reader(countRoot).discover() } }
        }
        let irrelevant = try root()
        _ = try database(irrelevant, rows: [Row()] + (0..<200).map { Row(host: "example.com", name: "irrelevant\($0)") })
        check(try reader(irrelevant).discover().count == 1, "irrelevant rows do not consume eligible limit")
        for badRows in [[Row(), Row(value: "duplicate")], [Row(value: "injected\r\nX: evil")], [Row(value: "synthetic; lastActiveOrg=11111111-2222-4333-8444-555555555555")], [Row(), Row(name: "a=b; c")], [Row(value: String(repeating: "a", count: 16384))], [Row(value: "", encrypted: Data("v20unknown".utf8))]] {
            let badRoot = try root()
            _ = try database(badRoot, rows: badRows)
            rejects("bad stored cookie rejected") { _ = try reader(badRoot).discover() }
        }
        let corrupt = try root()
        _ = try database(corrupt, rows: [Row()])
        try FileManager.default.createDirectory(at: corrupt.appendingPathComponent("Profile 2"), withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: corrupt.appendingPathComponent("Profile 2/Cookies"))
        rejects("partial discovery failure not silently accepted") { _ = try reader(corrupt).discover() }
        check(try reader(corrupt).discover(profileID: "Default").count == 1, "pinned discovery ignores unrelated corrupt profile")

        let walRoot = try root()
        let walURL = try database(walRoot, rows: [Row()])
        var walDB: OpaquePointer?
        guard sqlite3_open(walURL.path, &walDB) == SQLITE_OK else { throw TestError.fixture("wal open") }
        defer { sqlite3_close(walDB) }
        try exec(walDB, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE cookies SET value='wal-committed'")
        check(try reader(walRoot).discover().first?.cookieHeader == "sessionKey=wal-committed", "committed WAL changes visible while writer open")
        try exec(walDB, "BEGIN IMMEDIATE; UPDATE cookies SET value='uncommitted'")
        check(try reader(walRoot).discover().first?.cookieHeader == "sessionKey=wal-committed", "uncommitted WAL changes excluded")
        try exec(walDB, "ROLLBACK")

        let lockRoot = try root()
        let lockURL = try database(lockRoot, rows: [Row()])
        var lockDB: OpaquePointer?
        guard sqlite3_open(lockURL.path, &lockDB) == SQLITE_OK else { throw TestError.fixture("lock open") }
        defer { sqlite3_close(lockDB) }
        try exec(lockDB, "BEGIN EXCLUSIVE")
        let start = Date()
        rejects("exclusive busy lock reported") { _ = try reader(lockRoot).discover() }
        check(Date().timeIntervalSince(start) < 2, "busy lock bounded to 2s including scheduling overhead; spec timeout 250ms")
        try exec(lockDB, "ROLLBACK")
        check(try reader(lockRoot).discover().count == 1, "lock recovery on next attempt")
        print("PASS: \(checks) checks; fuzz seed=0xC0FFEE budget=512; disposable SQLite WAL/lock and crypto fixtures")
    }
}
