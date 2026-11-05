import Foundation
import SwiftUI
import UIKit

// MARK: - Datum

enum DesecDate {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    static func format(_ s: String?) -> String {
        guard let d = parse(s) else { return s ?? "–" }
        return display.string(from: d)
    }
}

// MARK: - Zeitdauer im deSEC-Format "[DD] [[HH:]MM:]ss"

enum DesecDuration {
    static func seconds(from s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var days = 0
        var timePart = s
        let parts = s.split(separator: " ")
        if parts.count == 2 {
            days = Int(parts[0]) ?? 0
            timePart = String(parts[1])
        }
        let comps = timePart.split(separator: ":").map { Double($0) ?? 0 }
        var secs = 0.0
        for c in comps { secs = secs * 60 + c }
        return days * 86400 + Int(secs)
    }

    static func string(fromSeconds total: Int) -> String {
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d %02d:%02d:%02d", d, h, m, s)
    }

    static func humanReadable(_ s: String?) -> String {
        guard let total = seconds(from: s) else { return "unbegrenzt" }
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        var out: [String] = []
        if d > 0 { out.append("\(d) T") }
        if h > 0 { out.append("\(h) Std") }
        if m > 0 { out.append("\(m) Min") }
        return out.isEmpty ? "\(total) s" : out.joined(separator: " ")
    }
}

// MARK: - Record-Typen

enum RecordTypes {
    static let supported = ["A", "AAAA", "AFSDB", "APL", "CAA", "CDNSKEY", "CDS", "CERT", "CNAME", "DHCID",
                            "DNAME", "DNSKEY", "DLV", "DS", "EUI48", "EUI64", "HINFO", "HTTPS", "KX", "L32",
                            "L64", "LOC", "LP", "MX", "NAPTR", "NID", "NS", "OPENPGPKEY", "PTR", "RP",
                            "SMIMEA", "SPF", "SRV", "SSHFP", "SVCB", "TLSA", "TXT", "URI"]

    static let common = ["A", "AAAA", "CNAME", "MX", "TXT", "NS", "SRV", "CAA", "HTTPS", "TLSA", "PTR"]

    /// Typen, deren Wert genau ein Hostname ist und mit Punkt enden muss.
    static let hostnameTypes: Set<String> = ["CNAME", "NS", "PTR", "DNAME"]

    /// Typen, bei denen eine Änderung die Erreichbarkeit der ganzen Zone gefährden kann.
    static let critical: Set<String> = ["NS", "DS", "DNSKEY", "CDS", "CDNSKEY"]

    static func placeholder(for type: String) -> String {
        switch type {
        case "A": return "192.0.2.1"
        case "AAAA": return "2001:db8::1"
        case "CNAME", "DNAME", "PTR", "NS": return "ziel.example.com."
        case "MX": return "10 mail.example.com."
        case "TXT", "SPF": return "\"v=spf1 -all\""
        case "SRV": return "10 5 443 server.example.com."
        case "CAA": return "0 issue \"letsencrypt.org\""
        case "TLSA", "SMIMEA": return "3 1 1 <sha256-hash>"
        case "HTTPS", "SVCB": return "1 . alpn=h2,h3"
        case "SSHFP": return "4 2 <fingerprint>"
        case "URI": return "10 1 \"https://example.com/\""
        case "DS", "CDS": return "12345 13 2 <digest>"
        case "DNSKEY", "CDNSKEY": return "257 3 13 <key>"
        case "LOC": return "52 31 0 N 13 24 0 E 34m"
        case "HINFO": return "\"CPU\" \"OS\""
        default: return "Wert im Zonefile-Format"
        }
    }

    static func hint(for type: String) -> String? {
        switch type {
        case "TXT", "SPF": return "Text wird automatisch in Anführungszeichen gesetzt, falls nötig."
        case "CNAME": return "Nur ein Wert erlaubt, nicht am Zonen-Apex (@). Ziel endet mit Punkt."
        case "MX", "SRV": return "Hostnamen müssen mit einem Punkt enden."
        case "NS": return "Achtung: NS-Einträge steuern die Delegation – nur ändern, wenn du weißt, was du tust."
        case "DNSKEY", "DS", "CDNSKEY", "CDS": return "Wird zusätzlich zu den automatisch verwalteten Schlüsseln veröffentlicht (Multi-Signer)."
        default: return nil
        }
    }

    /// Normalisiert einen eingegebenen Wert (Anführungszeichen, abschließender Punkt).
    static func normalize(_ value: String, type: String) -> String {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return v }
        if type == "TXT" || type == "SPF" {
            if !v.hasPrefix("\"") {
                v = "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
        } else if hostnameTypes.contains(type), !v.contains(" "), !v.hasSuffix(".") {
            v += "."
        }
        return v
    }
}

// MARK: - Diff

struct RecordDiff {
    var added: [String]
    var removed: [String]
    var unchanged: [String]
    var oldTTL: Int?
    var newTTL: Int?

    init(old: [String], new: [String], oldTTL: Int?, newTTL: Int?) {
        let o = Set(old), n = Set(new)
        added = new.filter { !o.contains($0) }
        removed = old.filter { !n.contains($0) }
        unchanged = new.filter { o.contains($0) }
        self.oldTTL = oldTTL
        self.newTTL = newTTL
    }

    var ttlChanged: Bool { oldTTL != nil && oldTTL != newTTL }
    var isEmpty: Bool { added.isEmpty && removed.isEmpty && !ttlChanged }
}

// MARK: - Zone-Zeilen-Parser für den Bulk-Editor

enum ZoneLineParser {
    struct ParseError: LocalizedError {
        let line: Int; let text: String
        var errorDescription: String? { "Zeile \(line): \(text)" }
    }

    /// Format pro Zeile: `<subname|@> <ttl> <TYP> <wert...>`
    /// Zeilen mit gleichem Namen und Typ werden zu einem RRset zusammengefasst.
    /// `<subname> <TYP> DELETE` löscht ein RRset.
    static func parse(_ text: String, defaultTTL: Int) throws -> [RRsetWrite] {
        var order: [String] = []
        var sets: [String: RRsetWrite] = [:]
        for (idx, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 3 else { throw ParseError(line: idx + 1, text: "Zu wenige Felder") }
            let name = tokens.removeFirst()
            let subname = (name == "@") ? "" : name.lowercased()
            var ttl: Int? = nil
            if let t = Int(tokens[0]) { ttl = t; tokens.removeFirst() }
            if tokens.first?.uppercased() == "IN" { tokens.removeFirst() }
            guard !tokens.isEmpty else { throw ParseError(line: idx + 1, text: "Typ fehlt") }
            let type = tokens.removeFirst().uppercased()
            guard RecordTypes.supported.contains(type) else { throw ParseError(line: idx + 1, text: "Typ \(type) nicht unterstützt") }
            let key = "\(subname)|\(type)"
            let value = tokens.joined(separator: " ")
            if value.uppercased() == "DELETE" {
                sets[key] = RRsetWrite(subname: subname, type: type, ttl: nil, records: [])
                if !order.contains(key) { order.append(key) }
                continue
            }
            guard !value.isEmpty else { throw ParseError(line: idx + 1, text: "Wert fehlt") }
            let normalized = RecordTypes.normalize(value, type: type)
            if var existing = sets[key] {
                existing.records = (existing.records ?? []) + [normalized]
                if let ttl { existing.ttl = ttl }
                sets[key] = existing
            } else {
                sets[key] = RRsetWrite(subname: subname, type: type, ttl: ttl ?? defaultTTL, records: [normalized])
                order.append(key)
            }
        }
        return order.compactMap { sets[$0] }
    }
}

// MARK: - UI-Hilfen

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Fehler", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

enum Clipboard {
    static func copy(_ s: String) {
        UIPasteboard.general.string = s
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

extension Color {
    static let desecYellow = Color(red: 1.0, green: 0.80, blue: 0.0)
}
