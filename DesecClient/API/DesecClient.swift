import Foundation

enum DesecError: LocalizedError {
    case unauthorized(String)
    case forbidden(String)
    case notFound(String)
    case conflict(String)
    case rateLimited(Int)
    case http(Int, String)
    case invalidResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let m): return "Nicht angemeldet oder Token abgelaufen. \(m)"
        case .forbidden(let m): return "Keine Berechtigung: \(m)"
        case .notFound(let m): return "Nicht gefunden: \(m)"
        case .conflict(let m): return "Konflikt: \(m)"
        case .rateLimited(let s): return "Zu viele Anfragen – bitte in \(s) Sekunden erneut versuchen."
        case .http(let code, let m): return "Fehler \(code): \(m)"
        case .invalidResponse: return "Ungültige Antwort vom Server."
        case .decoding(let m): return "Antwort konnte nicht gelesen werden: \(m)"
        }
    }
}

/// HTTP-Client für die deSEC-API v1.
@MainActor
final class DesecClient {
    static let apiBase = URL(string: "https://desec.io/api/v1/")!

    var token: String?
    /// Wird bei HTTP 401 aufgerufen (z. B. um eine erneute Anmeldung anzustoßen).
    var onUnauthorized: (@MainActor () -> Void)?

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(token: String?) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "deSEC-iOS-Client/1.0", "Accept": "application/json"]
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - Low level

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: Self.apiBase, resolvingAgainstBaseURL: false)!
        comps.path = "/api/v1/" + path
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    private func makeRequest(_ url: URL, method: String, body: Data?, auth: Bool, contentType: String = "application/json") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if auth, let token {
            req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Führt die Anfrage aus und wiederholt sie bei Rate-Limiting (429) bis zu 3 Mal.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DesecError.invalidResponse }
            if http.statusCode == 429 {
                let wait = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                if attempt < 3 && wait <= 15 {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(max(wait, 1)) * 1_000_000_000)
                    continue
                }
                throw DesecError.rateLimited(wait)
            }
            return (data, http)
        }
    }

    private func check(_ data: Data, _ http: HTTPURLResponse) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = Self.errorMessage(from: data)
        switch http.statusCode {
        case 401:
            onUnauthorized?()
            throw DesecError.unauthorized(message)
        case 403: throw DesecError.forbidden(message)
        case 404: throw DesecError.notFound(message)
        case 409: throw DesecError.conflict(message)
        default: throw DesecError.http(http.statusCode, message)
        }
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, auth: Bool = true) async throws -> Data {
        let req = makeRequest(url(path, query: query), method: method, body: body, auth: auth)
        let (data, http) = try await perform(req)
        try check(data, http)
        return data
    }

    func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw DesecError.decoding(String(describing: error)) }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try decode(T.self, from: try await send("GET", path, query: query))
    }

    /// Lädt eine Liste und folgt bei mehr als 500 Einträgen der Cursor-Pagination (Link-Header).
    func getAll<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> [T] {
        let firstReq = makeRequest(url(path, query: query), method: "GET", body: nil, auth: true)
        let (data, http) = try await perform(firstReq)
        if http.statusCode == 400, let link = http.value(forHTTPHeaderField: "Link"),
           let first = Self.links(link)["first"] {
            return try await paginate(from: first)
        }
        try check(data, http)
        return try decode([T].self, from: data)
    }

    private func paginate<T: Decodable>(from start: URL) async throws -> [T] {
        var result: [T] = []
        var next: URL? = start
        var guardCount = 0
        while let current = next, guardCount < 200 {
            guardCount += 1
            let (data, http) = try await perform(makeRequest(current, method: "GET", body: nil, auth: true))
            try check(data, http)
            result += try decode([T].self, from: data)
            next = http.value(forHTTPHeaderField: "Link").flatMap { Self.links($0)["next"] }
        }
        return result
    }

    static func links(_ header: String) -> [String: URL] {
        var out: [String: URL] = [:]
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = pieces.first, first.hasPrefix("<"), first.hasSuffix(">") else { continue }
            let urlString = String(first.dropFirst().dropLast())
            for p in pieces.dropFirst() where p.hasPrefix("rel=") {
                let rel = p.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let u = URL(string: urlString) { out[rel] = u }
            }
        }
        return out
    }

    /// Wandelt die Fehlerstruktur von Django REST Framework in lesbaren Text.
    static func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "Keine Details." }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data, encoding: .utf8)?.prefix(300).description ?? "Unbekannter Fehler"
        }
        return flatten(json, prefix: nil).joined(separator: "\n")
    }

    private static func flatten(_ value: Any, prefix: String?) -> [String] {
        if let s = value as? String { return [prefix.map { "\($0): \(s)" } ?? s] }
        if let dict = value as? [String: Any] {
            if let detail = dict["detail"] as? String { return [prefix.map { "\($0): \(detail)" } ?? detail] }
            return dict.sorted { $0.key < $1.key }.flatMap { key, v -> [String] in
                let label: String? = key == "non_field_errors" ? prefix : [prefix, key].compactMap { $0 }.joined(separator: " › ")
                return flatten(v, prefix: label)
            }
        }
        if let arr = value as? [Any] {
            // Bulk-Fehler: Liste mit einem Objekt pro Eintrag, leere Objekte = ok
            if arr.contains(where: { $0 is [String: Any] }) {
                return arr.enumerated().flatMap { idx, v -> [String] in
                    if let d = v as? [String: Any], d.isEmpty { return [] }
                    return flatten(v, prefix: [prefix, "Eintrag \(idx + 1)"].compactMap { $0 }.joined(separator: " › "))
                }
            }
            return arr.flatMap { flatten($0, prefix: prefix) }
        }
        return [prefix.map { "\($0): \(value)" } ?? "\(value)"]
    }

    // MARK: - Auth

    func login(email: String, password: String) async throws -> DesecToken {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        return try decode(DesecToken.self, from: try await send("POST", "auth/login/", body: body, auth: false))
    }

    func logout() async throws {
        try await send("POST", "auth/logout/")
    }

    func totpFactors() async throws -> [TOTPFactor] {
        try await get("auth/totp/")
    }

    func verifyTOTP(factorID: String, code: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        try await send("POST", "auth/totp/\(factorID)/verify/", body: body)
    }

    func captcha() async throws -> Captcha {
        let body = try JSONSerialization.data(withJSONObject: ["kind": "image"])
        return try decode(Captcha.self, from: try await send("POST", "captcha/", body: body, auth: false))
    }

    func register(email: String, password: String, captcha: CaptchaSolution, domain: String?, outreach: Bool) async throws {
        struct Payload: Encodable {
            let email: String; let password: String; let captcha: CaptchaSolution
            let domain: String?; let outreachPreference: Bool
        }
        let p = Payload(email: email, password: password, captcha: captcha,
                        domain: (domain?.isEmpty ?? true) ? nil : domain, outreachPreference: outreach)
        try await send("POST", "auth/", body: try encode(p), auth: false)
    }

    // MARK: - Account

    func account() async throws -> DesecAccount { try await get("auth/account/") }

    func setOutreach(_ value: Bool) async throws -> DesecAccount {
        let body = try JSONSerialization.data(withJSONObject: ["outreach_preference": value])
        return try decode(DesecAccount.self, from: try await send("PATCH", "auth/account/", body: body))
    }

    func requestEmailChange(email: String, password: String, newEmail: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password, "new_email": newEmail])
        try await send("POST", "auth/account/change-email/", body: body, auth: false)
    }

    func requestPasswordReset(email: String, captcha: CaptchaSolution) async throws {
        struct Payload: Encodable { let email: String; let captcha: CaptchaSolution }
        try await send("POST", "auth/account/reset-password/", body: try encode(Payload(email: email, captcha: captcha)), auth: false)
    }

    func requestAccountDeletion(email: String, password: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        try await send("POST", "auth/account/delete/", body: body, auth: false)
    }

    /// Bestätigt einen per E-Mail erhaltenen Link (`/v/<aktion>/<code>/`).
    func confirm(action: ConfirmationAction, code: String, payload: [String: Any] = [:]) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await send("POST", "v/\(action.rawValue)/\(code)/", body: body, auth: false)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = obj["detail"] as? String { return detail }
        return "Erfolgreich bestätigt."
    }

    // MARK: - Tokens

    func tokens() async throws -> [DesecToken] { try await getAll("auth/tokens/") }

    func createToken(_ write: DesecTokenWrite) async throws -> DesecToken {
        try decode(DesecToken.self, from: try await send("POST", "auth/tokens/", body: try encode(write)))
    }

    func updateToken(id: String, _ write: DesecTokenWrite) async throws -> DesecToken {
        try decode(DesecToken.self, from: try await send("PATCH", "auth/tokens/\(id)/", body: try encode(write)))
    }

    func deleteToken(id: String) async throws {
        try await send("DELETE", "auth/tokens/\(id)/")
    }

    func policies(tokenID: String) async throws -> [TokenPolicy] {
        try await getAll("auth/tokens/\(tokenID)/policies/rrsets/")
    }

    func createPolicy(tokenID: String, _ policy: TokenPolicy) async throws -> TokenPolicy {
        try decode(TokenPolicy.self, from: try await send("POST", "auth/tokens/\(tokenID)/policies/rrsets/", body: try encode(policy)))
    }

    func updatePolicy(tokenID: String, _ policy: TokenPolicy) async throws -> TokenPolicy {
        guard let pid = policy.id else { throw DesecError.invalidResponse }
        return try decode(TokenPolicy.self, from: try await send("PUT", "auth/tokens/\(tokenID)/policies/rrsets/\(pid)/", body: try encode(policy)))
    }

    func deletePolicy(tokenID: String, policyID: String) async throws {
        try await send("DELETE", "auth/tokens/\(tokenID)/policies/rrsets/\(policyID)/")
    }

    // MARK: - Domains

    func domains(ownsQName: String? = nil) async throws -> [DesecDomain] {
        let q = ownsQName.map { [URLQueryItem(name: "owns_qname", value: $0)] } ?? []
        return try await getAll("domains/", query: q)
    }

    func domain(_ name: String) async throws -> DesecDomain { try await get("domains/\(name)/") }

    func createDomain(name: String, zonefile: String?) async throws -> DesecDomain {
        let body = try encode(DomainCreate(name: name, zonefile: (zonefile?.isEmpty ?? true) ? nil : zonefile))
        return try decode(DesecDomain.self, from: try await send("POST", "domains/", body: body))
    }

    func deleteDomain(_ name: String) async throws {
        try await send("DELETE", "domains/\(name)/")
    }

    func zonefile(_ name: String) async throws -> String {
        let data = try await send("GET", "domains/\(name)/zonefile/")
        return String(data: data, encoding: .utf8) ?? ""
    }

    func status(_ name: String) async throws -> DomainStatus { try await get("domains/\(name)/status/") }

    func requestRecheck(_ name: String) async throws -> DomainStatus {
        try decode(DomainStatus.self, from: try await send("POST", "domains/\(name)/status/"))
    }

    // MARK: - RRsets

    func rrsets(domain: String, type: String? = nil, subname: String? = nil) async throws -> [RRset] {
        var q: [URLQueryItem] = []
        if let type { q.append(.init(name: "type", value: type)) }
        if let subname { q.append(.init(name: "subname", value: subname)) }
        return try await getAll("domains/\(domain)/rrsets/", query: q)
    }

    private func rrsetPath(_ domain: String, _ subname: String, _ type: String) -> String {
        "domains/\(domain)/rrsets/\(subname.isEmpty ? "@" : subname)/\(type)/"
    }

    func createRRset(domain: String, _ rrset: RRsetWrite) async throws -> RRset {
        try decode(RRset.self, from: try await send("POST", "domains/\(domain)/rrsets/", body: try encode(rrset)))
    }

    /// Ändert TTL und Records. Leere Records löschen das RRset (Antwort 204, dann `nil`).
    func updateRRset(domain: String, subname: String, type: String, ttl: Int?, records: [String]) async throws -> RRset? {
        var payload: [String: Any] = ["records": records]
        if let ttl { payload["ttl"] = ttl }
        let data = try await send("PATCH", rrsetPath(domain, subname, type), body: try JSONSerialization.data(withJSONObject: payload))
        return data.isEmpty ? nil : try decode(RRset.self, from: data)
    }

    func deleteRRset(domain: String, subname: String, type: String) async throws {
        try await send("DELETE", rrsetPath(domain, subname, type))
    }

    /// Atomare Bulk-Operation (POST = nur neue, PATCH/PUT = anlegen/ändern/löschen).
    @discardableResult
    func bulk(domain: String, method: String, _ rrsets: [RRsetWrite]) async throws -> [RRset] {
        let data = try await send(method, "domains/\(domain)/rrsets/", body: try encode(rrsets))
        if data.isEmpty { return [] }
        return (try? decode([RRset].self, from: data)) ?? []
    }

    // MARK: - dynDNS

    func dynDNSUpdate(hostnames: String, ipv4: String?, ipv6: String?, token overrideToken: String?) async throws -> String {
        var comps = URLComponents(string: "https://update.dedyn.io/")!
        var q = [URLQueryItem(name: "hostname", value: hostnames)]
        if let ipv4 { q.append(.init(name: "myipv4", value: ipv4)) }
        if let ipv6 { q.append(.init(name: "myipv6", value: ipv6)) }
        comps.queryItems = q
        var req = URLRequest(url: comps.url!)
        if let t = overrideToken ?? token { req.setValue("Token \(t)", forHTTPHeaderField: "Authorization") }
        let (data, http) = try await perform(req)
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (200..<300).contains(http.statusCode) else { throw DesecError.http(http.statusCode, text.isEmpty ? "Update fehlgeschlagen" : text) }
        return text
    }

    func publicIP(v6: Bool) async throws -> String {
        let url = URL(string: v6 ? "https://checkipv6.dedyn.io/" : "https://checkipv4.dedyn.io/")!
        let (data, _) = try await session.data(from: url)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
