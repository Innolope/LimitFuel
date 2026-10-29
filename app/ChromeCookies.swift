import Foundation
import Security
import LocalAuthentication
import CommonCrypto
import SQLite3

enum RefreshSchedule {
    static let usageInterval: TimeInterval = 60
    static let cookieInterval: TimeInterval = 3600
    static let updateInterval: TimeInterval = 3 * 3600
    static let fastUsageInterval: TimeInterval = 12

    static func nextPollDelay(interval: TimeInterval, lastStartedAt: Date?,
                              now: Date = Date()) -> TimeInterval {
        guard let started = lastStartedAt else { return interval }
        // Anchor cadence to request starts; slow or overlapping requests must not spin.
        return max(1, started.addingTimeInterval(interval).timeIntervalSince(now))
    }

    static func pollingInterval(usedPercent: Double?, windowDurationMins: Int?,
                                resetsAt: Date?, now: Date = Date()) -> TimeInterval {
        guard let percent = usedPercent, percent.isFinite, percent > 90,
              windowDurationMins == 300,
              resetsAt == nil || resetsAt! > now else { return usageInterval }
        return fastUsageInterval
    }
}

struct ChromeProfile: Equatable, Identifiable {
    let id: String
    let name: String
}

struct ChromeSession {
    let profile: ChromeProfile
    let cookieHeader: String
}

enum ChromeCookieError: LocalizedError {
    case unavailable, database, keychain, encryption, invalidCookie, profile

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Chrome profiles are unavailable. Open Claude in Chrome and sign in, then detect again."
        case .database: return "Chrome cookie storage could not be read completely. Quit Chrome and try detecting again, or use a manual cookie."
        case .keychain: return "Chrome Safe Storage is locked or access was denied. Click Detect Chrome Session to allow Keychain access, or use a manual cookie."
        case .encryption: return "Chrome cookies use an unsupported or damaged encryption format. Sign in again in Chrome, or use a manual cookie."
        case .invalidCookie: return "Chrome returned an invalid, ambiguous or oversized session cookie. Sign in again, or use a manual cookie."
        case .profile: return "The selected Chrome profile is unavailable. Detect Chrome Session again to choose a profile."
        }
    }

    /// Background rechecks cannot prompt, so a locked or denied Safe Storage key is expected
    /// there and says nothing about the Claude connection, which keeps using the stored cookie.
    static func diagnosticCode(for error: Error, interactive: Bool) -> DiagnosticErrorCode? {
        switch error as? ChromeCookieError {
        case .keychain: return interactive ? .signIn : nil
        case .invalidCookie, .encryption: return .invalidData
        case .unavailable, .profile: return .unavailable
        default: return .protocolFailure
        }
    }
}

/// Reads only Claude's cookies. No shell commands, browser scripting or writes to Chrome.
struct ChromeCookieReader {
    private static let keychainLock = NSLock()
    let root: URL
    let passwordProvider: (Bool) throws -> Data

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome"),
         passwordProvider: @escaping (Bool) throws -> Data = ChromeCookieReader.chromePassword) {
        self.root = root
        self.passwordProvider = passwordProvider
    }

    static func chromePassword(allowInteraction: Bool) throws -> Data {
        // Chrome uses the file-based keychain, whose prompt flag is process-global.
        // LAContext alone cannot suppress its UI (Chromium FB16959400 workaround).
        keychainLock.lock()
        defer { keychainLock.unlock() }
        var previousInteraction: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowInteraction) == errSecSuccess else {
            throw ChromeCookieError.keychain
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let password = item as? Data, !password.isEmpty else {
            throw ChromeCookieError.keychain
        }
        return password
    }

    func discover(profileID: String? = nil, allowInteraction: Bool = false,
                  now: Date = Date()) throws -> [ChromeSession] {
        let fm = FileManager.default
        func validID(_ id: String) -> Bool {
            id == "Default" || (id.hasPrefix("Profile ") && !id.dropFirst(8).isEmpty
                && id.dropFirst(8).allSatisfy { $0.isASCII && $0.isNumber })
        }
        let directories: [URL]
        if let id = profileID {
            guard validID(id) else { throw ChromeCookieError.profile }
            directories = [root.appendingPathComponent(id, isDirectory: true)]
        } else {
            do {
                directories = try fm.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey]).filter { validID($0.lastPathComponent) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                if (error as NSError).code == NSFileReadNoSuchFileError { return [] }
                throw ChromeCookieError.unavailable
            }
        }
        var names: [String: String] = [:]
        let state = root.appendingPathComponent("Local State")
        if let size = try? state.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 4 * 1024 * 1024,
           let data = try? Data(contentsOf: state),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = json["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: [String: Any]] {
            for (id, info) in cache { names[id] = (info["name"] as? String).map { String($0.prefix(100)) } }
        }
        var password: Result<Data, Error>?
        var sessions: [ChromeSession] = []
        for directory in directories {
            guard directory.resolvingSymlinksInPath().deletingLastPathComponent().path
                    == root.resolvingSymlinksInPath().path,
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw ChromeCookieError.profile
            }
            let paths = [directory.appendingPathComponent("Network/Cookies"),
                         directory.appendingPathComponent("Cookies")]
            guard let database = paths.first(where: { fm.fileExists(atPath: $0.path) }) else {
                if profileID != nil { throw ChromeCookieError.profile }
                continue // A newly created Chrome profile may have no cookie database yet.
            }
            guard database.resolvingSymlinksInPath().path.hasPrefix(
                directory.resolvingSymlinksInPath().path + "/") else { throw ChromeCookieError.profile }
            if let header = try read(database, now: now, password: {
                if let existing = password { return try existing.get() }
                let loaded = Result {
                    let value = try passwordProvider(allowInteraction)
                    guard !value.isEmpty else { throw ChromeCookieError.keychain }
                    return value
                }
                password = loaded
                return try loaded.get()
            }) {
                let id = directory.lastPathComponent
                sessions.append(ChromeSession(profile: ChromeProfile(id: id, name: names[id] ?? id),
                                              cookieHeader: header))
            }
        }
        return sessions
    }

    private func read(_ url: URL, now: Date, password: () throws -> Data) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db = database { sqlite3_close(db) }
            throw ChromeCookieError.database
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        // A read transaction observes WAL commits consistently without copying secret files.
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ChromeCookieError.database }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let result = statement else { throw ChromeCookieError.database }
            return result
        }
        let metadata = try prepare("SELECT value FROM meta WHERE key='version'")
        defer { sqlite3_finalize(metadata) }
        guard sqlite3_step(metadata) == SQLITE_ROW, let rawVersion = sqlite3_column_text(metadata, 0),
              let version = Int(String(cString: rawVersion)), version > 0 else { throw ChromeCookieError.database }
        // Older Chrome versions did not store partition keys.
        let columns = try prepare("PRAGMA table_info(cookies)")
        defer { sqlite3_finalize(columns) }
        var hasPartitionKey = false
        var columnStatus = sqlite3_step(columns)
        while columnStatus == SQLITE_ROW {
            if let name = sqlite3_column_text(columns, 1), String(cString: name) == "top_frame_site_key" {
                hasPartitionKey = true
            }
            columnStatus = sqlite3_step(columns)
        }
        guard columnStatus == SQLITE_DONE else { throw ChromeCookieError.database }
        let partitionFilter = hasPartitionKey ? "AND top_frame_site_key=''" : ""
        let statement = try prepare("""
            SELECT host_key,name,value,encrypted_value FROM cookies
            WHERE host_key IN ('claude.ai','.claude.ai')
              AND path IN ('/','/api','/api/')
              AND (expires_utc=0 OR expires_utc>?) \(partitionFilter)
            ORDER BY CASE WHEN name='sessionKey' THEN 0 ELSE 1 END,
                     length(path) DESC,length(host_key) ASC,name ASC LIMIT 129
            """)
        defer { sqlite3_finalize(statement) }
        let chromeNow = (now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        sqlite3_bind_double(statement, 1, chromeNow)
        // Do not request Chrome's encryption key for a profile that has no
        // eligible session. The probe shares this read transaction and filters.
        let sessionProbe = try prepare("""
            SELECT 1 FROM cookies WHERE name='sessionKey'
              AND host_key IN ('claude.ai','.claude.ai')
              AND path IN ('/','/api','/api/')
              AND (expires_utc=0 OR expires_utc>?) \(partitionFilter) LIMIT 1
            """)
        defer { sqlite3_finalize(sessionProbe) }
        sqlite3_bind_double(sessionProbe, 1, chromeNow)
        let sessionStatus = sqlite3_step(sessionProbe)
        if sessionStatus == SQLITE_DONE { return nil }
        guard sessionStatus == SQLITE_ROW else { throw ChromeCookieError.database }
        var values: [String: String] = [:]
        var count = 0
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            count += 1
            guard count <= 128, let hostBytes = sqlite3_column_text(statement, 0),
                  let nameBytes = sqlite3_column_text(statement, 1) else { throw ChromeCookieError.invalidCookie }
            let host = String(cString: hostBytes)
            let nameLength = Int(sqlite3_column_bytes(statement, 1))
            guard nameLength <= 1024,
                  let name = String(data: Data(bytes: nameBytes, count: nameLength), encoding: .utf8),
                  Self.validPair(name: name, value: "") else {
                throw ChromeCookieError.invalidCookie
            }
            // Always advance, including when an unrelated cookie is skipped.
            defer { status = sqlite3_step(statement) }
            do {
                let value: String
                let byteCount = Int(sqlite3_column_bytes(statement, 3))
                guard byteCount <= 32768 else { throw ChromeCookieError.invalidCookie }
                if byteCount > 0, let bytes = sqlite3_column_blob(statement, 3) {
                    let encrypted = Data(bytes: bytes, count: byteCount)
                    guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8),
                          (encrypted.count - 3) % kCCBlockSizeAES128 == 0 else { throw ChromeCookieError.encryption }
                    value = try Self.decrypt(encrypted, host: host,
                                             version: version, password: password())
                } else if let bytes = sqlite3_column_text(statement, 2) {
                    guard sqlite3_column_bytes(statement, 2) <= 16384 else { throw ChromeCookieError.invalidCookie }
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
                    guard let text = String(data: data, encoding: .utf8) else { throw ChromeCookieError.invalidCookie }
                    value = text
                } else { throw ChromeCookieError.invalidCookie }
                // Validate each SQLite component before joining; a semicolon must never
                // become an extra header field after serialization.
                guard Self.validPair(name: name, value: value) else { throw ChromeCookieError.invalidCookie }
                guard name != "sessionKey" || !value.isEmpty else { throw ChromeCookieError.invalidCookie }
                if name == "sessionKey", let old = values[name], old != value { throw ChromeCookieError.invalidCookie }
                if values[name] == nil { values[name] = value }
            } catch {
                // JSON, quoted, Unicode and newer encrypted auxiliary cookies
                // are common. Never serialize them into the header; authentication
                // cookie failures (including denied Keychain access) still fail visibly.
                if name == "sessionKey" { throw error }
            }
        }
        guard status == SQLITE_DONE else { throw ChromeCookieError.database }
        guard values["sessionKey"] != nil else { return nil }
        let header = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
        guard Self.validateHeader(header) else { throw ChromeCookieError.invalidCookie }
        return header
    }

    static func validateHeader(_ header: String) -> Bool {
        guard !header.isEmpty, header.utf8.count <= 16384,
              header.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return false }
        var names = Set<String>()
        var hasSession = false
        let parts = header.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count <= 128 else { return false }
        for part in parts {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1,
                                                                      omittingEmptySubsequences: false)
            guard pair.count == 2, Self.validPair(name: String(pair[0]), value: String(pair[1])),
                  names.insert(String(pair[0])).inserted else { return false }
            if pair[0] == "sessionKey" { hasSession = !pair[1].isEmpty }
        }
        return hasSession
    }

    private static func validPair(name: String, value: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy {
            $0 > 32 && $0 < 127 && !Array("()<>@,;:\\\"/[]?={} ".utf8).contains($0)
        } && value.utf8.allSatisfy {
            $0 > 32 && $0 < 127 && $0 != 34 && $0 != 44 && $0 != 59 && $0 != 92
        }
    }

    static func decrypt(_ encrypted: Data, host: String, version: Int, password: Data) throws -> String {
        guard encrypted.count > 3, encrypted.count <= 32768,
              encrypted.prefix(3) == Data("v10".utf8), !password.isEmpty,
              (encrypted.count - 3) % kCCBlockSizeAES128 == 0 else { throw ChromeCookieError.encryption }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                bytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { throw ChromeCookieError.encryption }
        let cipher = Array(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var plaintext = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let result = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, cipher, cipher.count,
            &plaintext, plaintext.count, &written)
        guard result == kCCSuccess else { throw ChromeCookieError.encryption }
        var decoded = Data(plaintext.prefix(written))
        if version >= 24 {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let hostBytes = Array(host.utf8)
            _ = CC_SHA256(hostBytes, CC_LONG(hostBytes.count), &digest)
            guard decoded.count >= digest.count, decoded.prefix(digest.count) == Data(digest) else {
                throw ChromeCookieError.encryption
            }
            decoded.removeFirst(digest.count)
        }
        guard let value = String(data: decoded, encoding: .utf8) else { throw ChromeCookieError.encryption }
        return value
    }
}

/// Do not forward credentials through an unexpected provider redirect.
final class ClaudeSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
