import Foundation

// MARK: - Auth / Tokens

/// Token-Objekt der deSEC-API (Login-Token und API-Token).
struct DesecToken: Codable, Identifiable, Hashable {
    let id: String
    var created: String?
    var lastUsed: String?
    var owner: String?
    var userOverride: String?
    /// `nil` = API-Token, `false` = Login-Token ohne 2FA-Step-up, `true` = Login-Token mit 2FA
    var mfa: Bool?
    var maxAge: String?
    var maxUnusedPeriod: String?
    var name: String
    var permCreateDomain: Bool
    var permDeleteDomain: Bool
    var permManageTokens: Bool
    var allowedSubnets: [String]
    var autoPolicy: Bool?
    var isValid: Bool?
    /// Nur einmalig bei Erstellung bzw. Login enthalten.
    var token: String?

    var isLoginToken: Bool { mfa != nil }
}

/// Schreibbare Felder eines Tokens (Erstellen / Ändern).
struct DesecTokenWrite: Encodable {
    var name: String
    var permCreateDomain: Bool
    var permDeleteDomain: Bool
    var permManageTokens: Bool
    var allowedSubnets: [String]
    var maxAge: String?
    var maxUnusedPeriod: String?
    var autoPolicy: Bool

    enum CodingKeys: String, CodingKey {
        case name, permCreateDomain, permDeleteDomain, permManageTokens
        case allowedSubnets, maxAge, maxUnusedPeriod, autoPolicy
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(permCreateDomain, forKey: .permCreateDomain)
        try c.encode(permDeleteDomain, forKey: .permDeleteDomain)
        try c.encode(permManageTokens, forKey: .permManageTokens)
        try c.encode(allowedSubnets, forKey: .allowedSubnets)
        // null bedeutet "keine Begrenzung" und muss explizit gesendet werden
        if let maxAge { try c.encode(maxAge, forKey: .maxAge) } else { try c.encodeNil(forKey: .maxAge) }
        if let maxUnusedPeriod { try c.encode(maxUnusedPeriod, forKey: .maxUnusedPeriod) } else { try c.encodeNil(forKey: .maxUnusedPeriod) }
        try c.encode(autoPolicy, forKey: .autoPolicy)
    }

    init(from token: DesecToken) {
        name = token.name
        permCreateDomain = token.permCreateDomain
        permDeleteDomain = token.permDeleteDomain
        permManageTokens = token.permManageTokens
        allowedSubnets = token.allowedSubnets
        maxAge = token.maxAge
        maxUnusedPeriod = token.maxUnusedPeriod
        autoPolicy = token.autoPolicy ?? false
    }

    init(name: String = "", permCreateDomain: Bool = false, permDeleteDomain: Bool = false,
         permManageTokens: Bool = false, allowedSubnets: [String] = ["0.0.0.0/0", "::/0"],
         maxAge: String? = nil, maxUnusedPeriod: String? = nil, autoPolicy: Bool = false) {
        self.name = name
        self.permCreateDomain = permCreateDomain
        self.permDeleteDomain = permDeleteDomain
        self.permManageTokens = permManageTokens
        self.allowedSubnets = allowedSubnets
        self.maxAge = maxAge
        self.maxUnusedPeriod = maxUnusedPeriod
        self.autoPolicy = autoPolicy
    }
}

/// RRset-Policy eines Tokens. `domain`/`subname`/`type` = nil steht für die Default-Policy.
struct TokenPolicy: Codable, Identifiable, Hashable {
    var id: String?
    var domain: String?
    var subname: String?
    var type: String?
    var permWrite: Bool

    var isDefault: Bool { domain == nil && subname == nil && type == nil }

    enum CodingKeys: String, CodingKey { case id, domain, subname, type, permWrite }

    init(id: String? = nil, domain: String? = nil, subname: String? = nil, type: String? = nil, permWrite: Bool = false) {
        self.id = id; self.domain = domain; self.subname = subname; self.type = type; self.permWrite = permWrite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        subname = try c.decodeIfPresent(String.self, forKey: .subname)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        permWrite = try c.decodeIfPresent(Bool.self, forKey: .permWrite) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Die API erwartet explizite nulls
        if let domain { try c.encode(domain, forKey: .domain) } else { try c.encodeNil(forKey: .domain) }
        if let subname { try c.encode(subname, forKey: .subname) } else { try c.encodeNil(forKey: .subname) }
        if let type { try c.encode(type, forKey: .type) } else { try c.encodeNil(forKey: .type) }
        try c.encode(permWrite, forKey: .permWrite)
    }

    var scopeDescription: String {
        if isDefault { return "Standard-Policy (alle übrigen RRsets)" }
        let d = domain ?? "jede Domain"
        let s = subname.map { $0.isEmpty ? "@" : $0 } ?? "jeder Name"
        let t = type ?? "jeder Typ"
        return "\(d) · \(s) · \(t)"
    }
}

/// 2FA-Faktor (TOTP) – Schnittstelle laut deSEC noch nicht final, daher tolerant dekodiert.
struct TOTPFactor: Decodable, Identifiable, Hashable {
    let id: String
    var name: String?
    var created: String?
    var lastUsed: String?

    enum CodingKeys: String, CodingKey { case id, name, created, lastUsed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        created = try? c.decodeIfPresent(String.self, forKey: .created)
        lastUsed = try? c.decodeIfPresent(String.self, forKey: .lastUsed)
    }
}

// MARK: - Account

struct DesecAccount: Codable, Hashable {
    var created: String?
    var email: String
    var id: String
    var limitDomains: Int?
    var outreachPreference: Bool
    var domainsUnderManagement: Int?
    var secureDomains: Int?
}

struct Captcha: Decodable {
    let id: String
    let challenge: String
    var kind: String?

    var imageData: Data? { Data(base64Encoded: challenge) }
}

struct CaptchaSolution: Encodable {
    let id: String
    let solution: String
}

// MARK: - Domains

struct DomainKey: Codable, Hashable {
    var dnskey: String
    var ds: [String]
    var flags: Int?
    var keytype: String?
    var managed: Bool?
}

struct DomainStatus: Codable, Hashable {
    var checked: String?
    var nameserverStatus: String?
    var nameservers: [String]?
    var secureSince: String?
    var securityStatus: String?
    var requested: String?

    var nameserverText: String {
        switch nameserverStatus {
        case "correctly_delegated": return "Korrekt an deSEC delegiert"
        case "multi_provider": return "An deSEC und andere Anbieter delegiert"
        case "other_provider": return "Nur an andere Nameserver delegiert"
        case "not_delegated": return "Nicht delegiert"
        case "error": return "Konnte nicht ermittelt werden"
        case nil: return "Noch nicht geprüft"
        default: return nameserverStatus ?? "–"
        }
    }

    var securityText: String {
        switch securityStatus {
        case "secure": return "DNSSEC aktiv (sicher delegiert)"
        case "insecure": return "Kein DS-Eintrag beim Parent"
        case "misconfigured": return "DNSSEC fehlerhaft (DS veraltet?)"
        case "error": return "Konnte nicht ermittelt werden"
        case nil: return "Nicht geprüft / nicht delegiert"
        default: return securityStatus ?? "–"
        }
    }
}

struct DesecDomain: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var created: String?
    var published: String?
    var touched: String?
    var minimumTtl: Int?
    var keys: [DomainKey]?
    var status: DomainStatus?
}

struct DomainCreate: Encodable {
    var name: String
    var zonefile: String?
}

// MARK: - RRsets

struct RRset: Codable, Identifiable, Hashable {
    var id: String { "\(subname)|\(type)" }
    var domain: String?
    var subname: String
    var name: String?
    var type: String
    var records: [String]
    var ttl: Int?
    var created: String?
    var touched: String?

    var displayName: String { subname.isEmpty ? "@" : subname }
}

/// Schreib-Objekt für RRsets. `ttl`/`records` = nil werden bei PATCH weggelassen,
/// `records: []` löscht das RRset.
struct RRsetWrite: Encodable, Hashable {
    var subname: String
    var type: String
    var ttl: Int?
    var records: [String]?
}

// MARK: - Bestätigungslinks

enum ConfirmationAction: String, CaseIterable, Identifiable {
    case activateAccount = "activate-account"
    case resetPassword = "reset-password"
    case changeEmail = "change-email"
    case deleteAccount = "delete-account"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activateAccount: return "Konto aktivieren"
        case .resetPassword: return "Passwort zurücksetzen"
        case .changeEmail: return "E-Mail-Änderung bestätigen"
        case .deleteAccount: return "Kontolöschung bestätigen"
        }
    }

    var isCritical: Bool { self == .deleteAccount }
}
