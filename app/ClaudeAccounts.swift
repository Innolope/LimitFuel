import AppKit
import Combine
import Security
import LocalAuthentication

// MARK: - Credential storage

enum CredentialStoreError: Error, Equatable {
    case interactionRequired      // the Keychain must ask the user first
    case failure(OSStatus)
}

protocol CredentialStore: AnyObject {
    /// nil when no item exists. Never shows UI unless `allowInteraction`.
    func read(account: String, allowInteraction: Bool) throws -> String?
    /// Creates or replaces the item.
    func write(_ secret: String, account: String) throws
    /// A missing item is not an error.
    func delete(account: String) throws
}

/// Claude session cookies as generic passwords in the login (file-based) keychain.
/// The data protection keychain needs a provisioning-profile entitlement that
/// Developer ID builds do not carry. Items are encrypted at rest and their access
/// list trusts only the app that created them.
final class KeychainCredentialStore: CredentialStore {
    static let service = "com.innolope.limitfuel.claude-session"
    private let service: String
    private let keychain: SecKeychain?

    init(service: String = KeychainCredentialStore.service, keychain: SecKeychain? = nil) {
        self.service = service
        self.keychain = keychain
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // A specific keychain keeps tests away from the login keychain.
        if let keychain = keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    private static func error(_ status: OSStatus) -> CredentialStoreError {
        // A locked keychain, or an access list that no longer trusts this build
        // (ad-hoc rebuilds change the signature), needs the user to approve.
        [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status)
            ? .interactionRequired : .failure(status)
    }

    func read(account: String, allowInteraction: Bool) throws -> String? {
        try KeychainInteraction.perform(allowInteraction: allowInteraction) {
            let context = LAContext()
            context.interactionNotAllowed = !allowInteraction
            var query = query(account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = context
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Self.error(status) }
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.failure(errSecDecode)
            }
            return value
        }
    }

    func write(_ secret: String, account: String) throws {
        // Writes run in the background (hourly Chrome refresh) and never prompt.
        try KeychainInteraction.perform(allowInteraction: false) {
            let data = Data(secret.utf8)
            var status = SecItemUpdate(query(account) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                // The item belongs to an older build; replace it with one this build owns.
                let deleted = SecItemDelete(query(account) as CFDictionary)
                status = deleted == errSecSuccess ? errSecItemNotFound : deleted
            }
            if status == errSecItemNotFound {
                var item: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrLabel as String: "LimitFuel Claude session",
                    kSecValueData as String: data
                ]
                if let keychain = keychain { item[kSecUseKeychain as String] = keychain }
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw Self.error(status) }
        }
    }

    func delete(account: String) throws {
        try KeychainInteraction.perform(allowInteraction: false) {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
        }
    }
}

/// Process-wide store for acceptance builds, so no test touches the login keychain.
final class InMemoryCredentialStore: CredentialStore {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func read(account: String, allowInteraction: Bool) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    func write(_ secret: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = secret
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: account)
    }
}

enum ClaudeCredentials {
    #if ACCEPTANCE_TESTS
    static var standard: CredentialStore = InMemoryCredentialStore()
    #else
    static var standard: CredentialStore = KeychainCredentialStore()
    #endif
}

// MARK: - Session header

enum ClaudeSessionHeader {
    static func value(_ name: String, in header: String) -> String? {
        for part in header.split(separator: ";") {
            let field = part.trimmingCharacters(in: .whitespaces)
            if field.hasPrefix(name + "=") { return String(field.dropFirst(name.count + 1)) }
        }
        return nil
    }

    /// The fields that name a Claude login. Auxiliary cookies rotate without a new identity.
    static func identity(_ header: String) -> [String] {
        header.split(separator: ";").compactMap { part in
            let field = part.trimmingCharacters(in: .whitespaces)
            return field.hasPrefix("sessionKey=") || field.hasPrefix("lastActiveOrg=") ? field : nil
        }.sorted()
    }

    static func sameSession(_ lhs: String, _ rhs: String) -> Bool {
        guard let key = value("sessionKey", in: lhs), !key.isEmpty else { return false }
        return key == value("sessionKey", in: rhs)
    }
}

enum ClaudeSignInCookies {
    static func header(from cookies: [HTTPCookie], now: Date = Date()) -> String? {
        var selected: [String: HTTPCookie] = [:]
        for cookie in cookies {
            let domain = cookie.domain.lowercased()
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard host == "claude.ai", cookie.expiresDate.map({ $0 >= now }) ?? true,
                  ChromeCookieReader.validPair(name: cookie.name, value: cookie.value) else { continue }
            if let previous = selected[cookie.name] {
                let length = cookie.path.unicodeScalars.count
                let previousLength = previous.path.unicodeScalars.count
                guard length > previousLength
                    || (length == previousLength && domain == "claude.ai"
                        && previous.domain.lowercased() != "claude.ai") else { continue }
            }
            selected[cookie.name] = cookie
        }
        let header = selected.keys.sorted().map { "\($0)=\(selected[$0]!.value)" }.joined(separator: "; ")
        return ChromeCookieReader.validateHeader(header) ? header : nil
    }
}

enum ClaudeSignInOutcome: Equatable {
    case added(String)
    case renewed(String)
    case alreadyAdded(String)
    case failed(String)
}

// MARK: - Account identity

struct ClaudeAccountIdentity: Equatable {
    let email: String
    let accountUUID: String
    let organizationName: String?

    static func parse(_ data: Data, organizationID: String?) -> ClaudeAccountIdentity? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email_address"] as? String,
              (3...320).contains(email.utf8.count), email.contains("@"),
              !email.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }),
              let uuid = json["uuid"] as? String, UUID(uuidString: uuid) != nil else { return nil }
        let memberships = json["memberships"] as? [[String: Any]] ?? []
        let organization = organizationID.flatMap(UUID.init(uuidString:))
        let name = memberships.lazy.compactMap { $0["organization"] as? [String: Any] }
            .first { org in organization != nil && (org["uuid"] as? String).flatMap(UUID.init(uuidString:)) == organization }
            .flatMap { $0["name"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let validName = name.flatMap { name in
            !name.isEmpty && name.count <= 100
                && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? name : nil
        }
        return ClaudeAccountIdentity(email: email, accountUUID: uuid, organizationName: validName)
    }
}

// MARK: - Account metadata and 1.0.x migration

enum ClaudeAccountStore {
    static let idsKey = "claude_account_ids"
    static let autoAddKey = "claude_accounts_auto_add"
    static let pendingDeletionsKey = "claude_credential_deletions"
    static let legacyCookieKey = "claude_session_cookie"
    static let fields = ["chrome_sync", "web_sign_in", "chrome_profile_id", "chrome_profile_name", "email",
                         "organization_name", "organization_id", "account_uuid", "last_notified_threshold",
                         "legacy_cookie_pending"]
    private static let legacyFlags = ["chrome_detection_enabled", "chrome_profile_id", "last_notified_threshold"]

    static func key(_ id: String, _ field: String) -> String { "claude_account.\(id).\(field)" }

    static func ids(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: idsKey) ?? []
    }

    /// Idempotent at every step: a crash leaves either the plaintext or a pending
    /// account whose credential write is retried, never a second account.
    static func migrateLegacy(defaults: UserDefaults, credentials: CredentialStore) {
        let storedIDs = defaults.stringArray(forKey: idsKey)
        var ids = storedIDs ?? []
        let legacyChrome = defaults.object(forKey: "chrome_detection_enabled") as? Bool
        guard let cookie = defaults.string(forKey: legacyCookieKey), !cookie.isEmpty else {
            if storedIDs == nil {
                defaults.set(ids, forKey: idsKey)
                defaults.set(legacyChrome ?? true, forKey: autoAddKey)
            }
            defaults.removeObject(forKey: legacyCookieKey)
            legacyFlags.forEach { defaults.removeObject(forKey: $0) }
            return
        }
        if let pending = ids.first(where: { defaults.bool(forKey: key($0, "legacy_cookie_pending")) }) {
            finishLegacy(cookie, account: pending, defaults: defaults, credentials: credentials)
            return
        }
        let known = ids.contains { id in
            ((try? credentials.read(account: id, allowInteraction: false)) ?? nil)
                .map { ClaudeSessionHeader.sameSession($0, cookie) } ?? false
        }
        if known {
            defaults.removeObject(forKey: legacyCookieKey)
            legacyFlags.forEach { defaults.removeObject(forKey: $0) }
            return
        }
        let id = UUID().uuidString
        defaults.set(legacyChrome ?? false, forKey: key(id, "chrome_sync"))
        if let profile = defaults.string(forKey: "chrome_profile_id") {
            defaults.set(profile, forKey: key(id, "chrome_profile_id"))
        }
        if let threshold = defaults.object(forKey: "last_notified_threshold") as? Int {
            defaults.set(threshold, forKey: key(id, "last_notified_threshold"))
        }
        // Mark before writing: an interrupted write is retried, not duplicated.
        defaults.set(true, forKey: key(id, "legacy_cookie_pending"))
        ids.append(id)
        defaults.set(ids, forKey: idsKey)
        if storedIDs == nil { defaults.set(false, forKey: autoAddKey) }
        legacyFlags.forEach { defaults.removeObject(forKey: $0) }
        finishLegacy(cookie, account: id, defaults: defaults, credentials: credentials)
    }

    private static func finishLegacy(_ cookie: String, account: String, defaults: UserDefaults,
                                     credentials: CredentialStore) {
        // Only a successful write removes the plaintext; otherwise it stays usable.
        guard (try? credentials.write(cookie, account: account)) != nil else { return }
        defaults.removeObject(forKey: legacyCookieKey)
        defaults.removeObject(forKey: key(account, "legacy_cookie_pending"))
    }

    /// The first account, created when none exists.
    static func primaryAccountID(defaults: UserDefaults, credentials: CredentialStore) -> String {
        migrateLegacy(defaults: defaults, credentials: credentials)
        if let first = ids(defaults).first { return first }
        let id = UUID().uuidString
        defaults.set(defaults.object(forKey: autoAddKey) as? Bool ?? true, forKey: key(id, "chrome_sync"))
        defaults.set([id], forKey: idsKey)
        return id
    }

    static func create(_ id: String, defaults: UserDefaults, chromeProfile: ChromeProfile?) {
        defaults.set(chromeProfile != nil, forKey: key(id, "chrome_sync"))
        if let profile = chromeProfile {
            defaults.set(profile.id, forKey: key(id, "chrome_profile_id"))
            defaults.set(profile.name, forKey: key(id, "chrome_profile_name"))
        }
    }

    static func removeMetadata(_ id: String, defaults: UserDefaults) {
        fields.forEach { defaults.removeObject(forKey: key(id, $0)) }
        defaults.set(ids(defaults).filter { $0 != id }, forKey: idsKey)
    }

    static func deleteCredential(_ id: String, defaults: UserDefaults, credentials: CredentialStore) {
        guard (try? credentials.delete(account: id)) == nil else { return }
        let pending = defaults.stringArray(forKey: pendingDeletionsKey) ?? []
        if !pending.contains(id) { defaults.set(pending + [id], forKey: pendingDeletionsKey) }
    }

    static func retryDeletions(defaults: UserDefaults, credentials: CredentialStore) {
        guard let pending = defaults.stringArray(forKey: pendingDeletionsKey), !pending.isEmpty else { return }
        let remaining = pending.filter { (try? credentials.delete(account: $0)) == nil }
        if remaining.isEmpty { defaults.removeObject(forKey: pendingDeletionsKey) }
        else { defaults.set(remaining, forKey: pendingDeletionsKey) }
    }
}

// MARK: - Accounts

/// Every tracked Claude account. Each account is one UsageManager with its own
/// session, usage, menu bar entry and alert history.
final class ClaudeAccounts: ObservableObject {
    @Published private(set) var accounts: [UsageManager] = [] {
        // The popup observes this object; each account's changes redraw it too.
        didSet { accountChanges = accounts.map { $0.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } } }
    }
    @Published private(set) var isDetectingChrome = false
    @Published private(set) var chromeMessage: String?
    @Published private(set) var chromeChoices: [ChromeProfile] = []
    /// Called after an account is added or removed, so the menu bar and polls follow.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let credentials: CredentialStore
    private let chromeReader: ChromeCookieReader
    private let apiSession: URLSession
    private weak var delegate: AppDelegate?
    private let chromeQueue = DispatchQueue(label: "com.innolope.limitfuel.chrome-accounts", qos: .userInitiated)
    // Discovered Chrome sessions stay in memory until the user adds one.
    private var discovered: [String: ChromeSession] = [:]
    private var detectionRevision = UUID()
    private var accountChanges: [AnyCancellable] = []

    init(defaults: UserDefaults = .standard, credentials: CredentialStore = ClaudeCredentials.standard,
         chromeReader: ChromeCookieReader = ChromeCookieReader(), apiSession: URLSession? = nil,
         delegate: AppDelegate? = nil) {
        self.defaults = defaults
        self.credentials = credentials
        self.chromeReader = chromeReader
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        self.apiSession = apiSession ?? URLSession(configuration: config, delegate: ClaudeSessionDelegate(), delegateQueue: nil)
        self.delegate = delegate
        ClaudeAccountStore.migrateLegacy(defaults: defaults, credentials: credentials)
        ClaudeAccountStore.retryDeletions(defaults: defaults, credentials: credentials)
        accounts = ClaudeAccountStore.ids(defaults).map(makeAccount)
        updateAlertNaming()
    }

    private var autoAddAllowed: Bool {
        defaults.object(forKey: ClaudeAccountStore.autoAddKey) as? Bool ?? true
    }

    private func makeAccount(_ id: String) -> UsageManager {
        let account = UsageManager(statusItem: nil, delegate: delegate, defaults: defaults,
                                   chromeReader: chromeReader, apiSession: apiSession,
                                   accountID: id, credentials: credentials)
        account.onUsageFetched = { [weak account] in account?.fetchIdentityIfNeeded() }
        account.onIdentityResolved = { [weak self, weak account] in
            guard let self = self, let account = account else { return }
            self.removeDuplicates(of: account)
        }
        return account
    }

    private func updateAlertNaming() {
        accounts.forEach { $0.namesAccountInAlerts = accounts.count > 1 }
    }

    private func isTracked(_ cookie: String) -> Bool {
        accounts.contains { ClaudeSessionHeader.sameSession($0.sessionHeader, cookie) }
    }

    func fetchAll() {
        accounts.forEach { $0.fetchUsage() }
    }

    /// Hourly: refresh each Chrome-synced account from its own profile, and look for
    /// a first account while none has been set up.
    func refreshChromeAccounts() {
        accounts.filter(\.chromeDetectionEnabled).forEach { $0.detectChromeSession() }
        if accounts.isEmpty && autoAddAllowed { detectChromeSessions(interactive: false) }
    }

    func refreshChromeAccountsIfDue() {
        accounts.forEach { $0.detectChromeSessionIfDue() }
        if accounts.isEmpty && autoAddAllowed { detectChromeSessions(interactive: false) }
    }

    @discardableResult
    func addManualCookie(_ header: String) -> Bool {
        let cookie = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChromeCookieReader.validateHeader(cookie) else {
            chromeMessage = "Paste a valid full Cookie header containing sessionKey."
            return false
        }
        guard !isTracked(cookie) else {
            chromeMessage = "This Claude session is already added."
            return false
        }
        guard add(cookie, chromeProfile: nil) else { return false }
        chromeMessage = nil
        return true
    }

    func completeSignIn(_ header: String, completion: @escaping (ClaudeSignInOutcome) -> Void) {
        guard ChromeCookieReader.validateHeader(header) else {
            completion(.failed("claude.ai did not return a session. Sign in again."))
            return
        }
        if let account = accounts.first(where: { ClaudeSessionHeader.sameSession($0.sessionHeader, header) }) {
            chromeMessage = nil
            completion(.alreadyAdded(account.accountLabel))
            return
        }
        guard let request = UsageManager.accountRequest(cookie: header) else {
            completion(.failed("LimitFuel could not confirm the account with claude.ai. Check your connection and try again."))
            return
        }
        let organization = ClaudeSessionHeader.value("lastActiveOrg", in: header)
        apiSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode
                guard error == nil, status == 200, let data = data,
                      let identity = ClaudeAccountIdentity.parse(data, organizationID: organization) else {
                    completion(.failed(status == 401 || status == 403
                        ? "claude.ai rejected this sign-in. Sign in again."
                        : "LimitFuel could not confirm the account with claude.ai. Check your connection and try again."))
                    return
                }
                let account = self.accounts.first {
                    guard $0.claudeAccountUUID.flatMap(UUID.init(uuidString:)) == UUID(uuidString: identity.accountUUID) else { return false }
                    guard let existing = $0.organizationID, let organization = organization else { return true }
                    guard let existingUUID = UUID(uuidString: existing),
                          let organizationUUID = UUID(uuidString: organization) else { return false }
                    return existingUUID == organizationUUID
                }
                let saved: Bool
                if let account = account {
                    saved = account.adoptSignIn(header, identity: identity, organizationID: organization)
                } else {
                    saved = self.add(header, chromeProfile: nil, identity: identity, organizationID: organization)
                }
                guard saved else {
                    completion(.failed("LimitFuel could not save this session to the Keychain. Try again."))
                    return
                }
                self.chromeMessage = nil
                completion(account == nil ? .added(identity.email) : .renewed(identity.email))
            }
        }.resume()
    }

    /// Reads every Chrome profile. Only an explicit Detect may prompt for Chrome Safe
    /// Storage, and a background check adds nothing once any account exists.
    func detectChromeSessions(interactive: Bool) {
        guard !isDetectingChrome, interactive || (accounts.isEmpty && autoAddAllowed) else { return }
        isDetectingChrome = true
        chromeMessage = nil
        chromeChoices = []
        let revision = UUID()
        detectionRevision = revision
        let reader = chromeReader
        chromeQueue.async { [weak self] in
            let result = Result { try reader.discover(allowInteraction: interactive) }
            DispatchQueue.main.async {
                guard let self = self, self.detectionRevision == revision else { return }
                self.isDetectingChrome = false
                switch result {
                case .failure(let error):
                    self.chromeMessage = error.localizedDescription
                    if let code = ChromeCookieError.diagnosticCode(for: error, interactive: interactive) {
                        AppDiagnostics.shared.recordFailure(provider: .claude, code: code)
                    }
                case .success(let sessions):
                    self.offer(sessions, interactive: interactive)
                }
            }
        }
    }

    // Chrome keeps one claude.ai sign-in per profile. A pinned profile signed in to another
    // Claude account holds a session no account uses, so it is offered like any other.
    private func offer(_ sessions: [ChromeSession], interactive: Bool) {
        var fresh: [ChromeSession] = []
        for session in sessions where !isTracked(session.cookieHeader)
            && !fresh.contains(where: { ClaudeSessionHeader.sameSession($0.cookieHeader, session.cookieHeader) }) {
            fresh.append(session)
        }
        discovered = Dictionary(fresh.map { ($0.profile.id, $0) }, uniquingKeysWith: { first, _ in first })
        if fresh.count == 1, interactive || accounts.isEmpty {
            addChromeSession(fresh[0])
        } else if fresh.count > 1 {
            chromeChoices = fresh.map(\.profile)
            chromeMessage = "Choose the Chrome profiles to add."
        } else if sessions.isEmpty {
            chromeMessage = "No signed-in Claude session found in Chrome. Sign in to Claude here, or sign in in Chrome and detect again."
        } else if interactive {
            chromeMessage = "Every Claude account signed in to Chrome is already added. Chrome keeps one claude.ai sign-in per profile: sign in to another account in a different Chrome profile, or add a manual cookie."
        }
    }

    func addChromeProfile(_ profileID: String) {
        guard let session = discovered[profileID] else { return }
        addChromeSession(session)
    }

    private func addChromeSession(_ session: ChromeSession) {
        let profile = session.profile
        discovered.removeValue(forKey: profile.id)
        chromeChoices.removeAll { $0.id == profile.id }
        guard !isTracked(session.cookieHeader) else { return }
        guard add(session.cookieHeader, chromeProfile: profile) else { return }
        chromeMessage = chromeChoices.isEmpty ? nil : "Added \(profile.name). Choose more profiles to add."
    }

    /// The credential is written first; without it nothing is persisted.
    private func add(_ cookie: String, chromeProfile: ChromeProfile?, identity: ClaudeAccountIdentity? = nil,
                     organizationID: String? = nil) -> Bool {
        let id = UUID().uuidString
        do {
            try credentials.write(cookie, account: id)
        } catch {
            chromeMessage = "LimitFuel could not save this session to the Keychain. Try again."
            return false
        }
        ClaudeAccountStore.create(id, defaults: defaults, chromeProfile: chromeProfile)
        if let identity = identity {
            defaults.set(true, forKey: ClaudeAccountStore.key(id, "web_sign_in"))
            defaults.set(identity.email, forKey: ClaudeAccountStore.key(id, "email"))
            defaults.set(identity.accountUUID, forKey: ClaudeAccountStore.key(id, "account_uuid"))
            defaults.set(identity.organizationName, forKey: ClaudeAccountStore.key(id, "organization_name"))
            defaults.set(organizationID, forKey: ClaudeAccountStore.key(id, "organization_id"))
        }
        defaults.set(ClaudeAccountStore.ids(defaults) + [id], forKey: ClaudeAccountStore.idsKey)
        defaults.set(false, forKey: ClaudeAccountStore.autoAddKey)
        let account = makeAccount(id)
        accounts.append(account)
        updateAlertNaming()
        onChange?()
        account.fetchUsage()
        return true
    }

    func remove(_ account: UsageManager) {
        guard let index = accounts.firstIndex(where: { $0 === account }) else { return }
        account.disconnect()
        ClaudeAccountStore.deleteCredential(account.accountID, defaults: defaults, credentials: credentials)
        ClaudeAccountStore.removeMetadata(account.accountID, defaults: defaults)
        defaults.set(false, forKey: ClaudeAccountStore.autoAddKey)
        accounts.remove(at: index)
        updateAlertNaming()
        onChange?()
    }

    /// Two Chrome profiles, or a re-signed profile, can carry one Claude account.
    /// The account listed first stays, whichever identity resolves first.
    private func removeDuplicates(of account: UsageManager) {
        guard let uuid = account.claudeAccountUUID else { return }
        let organization = account.organizationID.flatMap(UUID.init(uuidString:))
        let matches = accounts.filter {
            $0.claudeAccountUUID == uuid && $0.organizationID.flatMap(UUID.init(uuidString:)) == organization
        }
        guard let survivor = matches.first, matches.count > 1 else { return }
        matches.dropFirst().forEach(remove)
        chromeMessage = "\(survivor.accountLabel) is already added."
    }
}
