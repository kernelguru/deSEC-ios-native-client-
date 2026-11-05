import Foundation
import LocalAuthentication
import Observation

enum AccountKind: String, Codable {
    case apiToken      // dauerhaftes API-Token (nicht von 2FA betroffen)
    case login         // E-Mail + Passwort (+ 2FA), Login-Token läuft nach 1 h Inaktivität ab
}

struct StoredAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var email: String?
    var kind: AccountKind
    var savePassword: Bool = false

    var tokenKey: String { "token.\(id.uuidString)" }
    var passwordKey: String { "password.\(id.uuidString)" }
}

/// Ergebnis eines Passwort-Logins.
enum LoginOutcome {
    case done(token: String)
    case needsTOTP(token: String, factors: [TOTPFactor])
}

@MainActor
@Observable
final class AppModel {
    private(set) var accounts: [StoredAccount] = []
    var currentID: UUID? {
        didSet { UserDefaults.standard.set(currentID?.uuidString, forKey: "currentAccount") }
    }
    /// Konto, für das eine erneute Anmeldung nötig ist (zeigt Login-Sheet).
    var reauthAccount: StoredAccount?
    /// Inkrementiert nach Kontowechsel/Anmeldung, damit Views neu laden.
    var refreshTrigger = 0

    var lockEnabled: Bool {
        didSet { UserDefaults.standard.set(lockEnabled, forKey: "lockEnabled") }
    }
    var isLocked: Bool

    @ObservationIgnored private var clients: [UUID: DesecClient] = [:]

    init() {
        let lock = UserDefaults.standard.bool(forKey: "lockEnabled")
        lockEnabled = lock
        isLocked = lock
        if let data = UserDefaults.standard.data(forKey: "accounts"),
           let list = try? JSONDecoder().decode([StoredAccount].self, from: data) {
            accounts = list
        }
        if let s = UserDefaults.standard.string(forKey: "currentAccount"), let id = UUID(uuidString: s),
           accounts.contains(where: { $0.id == id }) {
            currentID = id
        } else {
            currentID = accounts.first?.id
        }
    }

    var current: StoredAccount? { accounts.first { $0.id == currentID } }

    var client: DesecClient? {
        guard let current else { return nil }
        return client(for: current)
    }

    func client(for account: StoredAccount) -> DesecClient {
        if let c = clients[account.id] { return c }
        let c = DesecClient(token: Keychain.get(account.tokenKey))
        c.onUnauthorized = { [weak self] in self?.handleUnauthorized(account.id) }
        clients[account.id] = c
        return c
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: "accounts")
        }
    }

    // MARK: - Konten verwalten

    func addAccount(_ account: StoredAccount, token: String, password: String?) {
        Keychain.set(token, for: account.tokenKey)
        Keychain.set(account.savePassword ? password : nil, for: account.passwordKey)
        accounts.append(account)
        persist()
        currentID = account.id
        refreshTrigger += 1
    }

    func rename(_ account: StoredAccount, to label: String) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].label = label
        persist()
    }

    func remove(_ account: StoredAccount, serverLogout: Bool) async {
        if serverLogout, account.kind == .login {
            try? await client(for: account).logout()
        }
        Keychain.set(nil, for: account.tokenKey)
        Keychain.set(nil, for: account.passwordKey)
        clients[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        persist()
        if currentID == account.id { currentID = accounts.first?.id }
        refreshTrigger += 1
    }

    func select(_ account: StoredAccount) {
        currentID = account.id
        refreshTrigger += 1
    }

    func savedPassword(for account: StoredAccount) -> String? { Keychain.get(account.passwordKey) }

    /// Speichert nach erneuter Anmeldung das neue Login-Token.
    func updateToken(_ token: String, for account: StoredAccount, password: String?) {
        Keychain.set(token, for: account.tokenKey)
        if account.savePassword, let password { Keychain.set(password, for: account.passwordKey) }
        client(for: account).token = token
        if reauthAccount?.id == account.id { reauthAccount = nil }
        refreshTrigger += 1
    }

    private func handleUnauthorized(_ id: UUID) {
        guard let acc = accounts.first(where: { $0.id == id }), acc.kind == .login, reauthAccount == nil else { return }
        reauthAccount = acc
    }

    // MARK: - Login-Ablauf (inkl. 2FA-Step-up)

    static func login(email: String, password: String) async throws -> LoginOutcome {
        let anon = DesecClient(token: nil)
        let token = try await anon.login(email: email, password: password)
        guard let secret = token.token else { throw DesecError.invalidResponse }
        // Bei aktivierter 2FA hat das Login-Token mfa == false, bis ein TOTP-Code bestätigt ist.
        if token.mfa == false {
            let authed = DesecClient(token: secret)
            let factors = (try? await authed.totpFactors()) ?? []
            if !factors.isEmpty { return .needsTOTP(token: secret, factors: factors) }
        }
        return .done(token: secret)
    }

    static func verifyTOTP(token: String, factor: TOTPFactor, code: String) async throws {
        let c = DesecClient(token: token)
        try await c.verifyTOTP(factorID: factor.id, code: code.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - App-Sperre

    func unlock() async {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            isLocked = false
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "deSEC Client entsperren")
            if ok { isLocked = false }
        } catch {
            // bleibt gesperrt
        }
    }

    func lockIfNeeded() {
        if lockEnabled { isLocked = true }
    }
}
