import Foundation
import SQLite3
private func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
private func database(_ root: URL, cookies: [(String,String,Data)]) throws {
    let profile = root.appendingPathComponent("Default")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    var db: OpaquePointer?
    check(sqlite3_open(profile.appendingPathComponent("Cookies").path, &db) == SQLITE_OK, "open fixture")
    defer { sqlite3_close(db) }
    check(sqlite3_exec(db, "CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','23'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,top_frame_site_key TEXT);", nil, nil, nil) == SQLITE_OK, "schema")
    for (name,value,encrypted) in cookies {
        var statement: OpaquePointer?
        check(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES('.claude.ai',?,?,?,'/',0,'')", -1, &statement, nil) == SQLITE_OK, "prepare")
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        if encrypted.isEmpty { sqlite3_bind_zeroblob(statement, 3, 0) }
        else { _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) } }
        check(sqlite3_step(statement) == SQLITE_DONE, "insert")
        sqlite3_finalize(statement)
    }
}
@main struct ChromeAcceptance {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? FileManager.default.temporaryDirectory.path).appendingPathComponent("LimitFuel.Chrome.Spec.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try database(root, cookies: [("sessionKey","sk-ant-sid01-synthetic",Data()),("json","{\"hello\":\"world\"}",Data()),("quoted","\"test\"",Data()),("unicode","café",Data()),("future","",Data("v99unsupported".utf8)),("safe","abc123",Data())])
        var interactions: [Bool] = []
        let reader = ChromeCookieReader(root: root, passwordProvider: { interactions.append($0); return Data("synthetic-password".utf8) })
        let sessions = try reader.discover()
        check(sessions.count == 1, "valid session survives ordinary auxiliary cookies")
        check(sessions[0].cookieHeader.contains("sessionKey=sk-ant-sid01-synthetic"), "session retained")
        check(ChromeCookieReader.validateHeader(sessions[0].cookieHeader), "serialized header remains valid")
        check(!sessions[0].cookieHeader.contains("café") && !sessions[0].cookieHeader.contains("v99unsupported") && !sessions[0].cookieHeader.contains("\""), "unsafe auxiliary values excluded")
        check(!interactions.contains(true), "background never prompts")
        let emptyRoot = root.appendingPathComponent("no-session")
        try database(emptyRoot, cookies: [("ordinary","",Data("v10encrypted-aux".utf8))])
        var reads = 0
        let noSession = ChromeCookieReader(root: emptyRoot, passwordProvider: { _ in reads += 1; return Data() })
        let missing = try noSession.discover(allowInteraction: true)
        check(missing.isEmpty, "no session found")
        check(reads == 0, "no eligible session must not read Keychain even explicitly")
        let deniedRoot = root.appendingPathComponent("denied-auxiliary-key")
        let encryptedAuxiliary = Data("v10".utf8) + Data(repeating: 0, count: 16)
        try database(deniedRoot, cookies: [("sessionKey", "synthetic-valid-session", Data()),
            ("aux1", "", encryptedAuxiliary), ("aux2", "", encryptedAuxiliary), ("aux3", "", encryptedAuxiliary)])
        for interactive in [false, true] {
            var attempts: [Bool] = []
            let denied = ChromeCookieReader(root: deniedRoot, passwordProvider: {
                attempts.append($0); throw ChromeCookieError.keychain
            })
            let retained = try denied.discover(allowInteraction: interactive)
            check(retained.count == 1, "denied auxiliary key leaves plaintext authentication usable")
            check(attempts == [interactive], "a denied Keychain lookup is attempted once per detection")
        }
        print("Chrome acceptance passed")
    }
}
