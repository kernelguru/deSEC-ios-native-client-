import SwiftUI

/// Mehrere RRsets in einem atomaren Schritt anlegen, ändern oder löschen.
struct BulkEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let domain: String
    let minTTL: Int
    let existing: [RRset]
    var onSaved: () async -> Void

    @State private var text = ""
    @State private var parsed: [RRsetWrite] = []
    @State private var parseError: String?
    @State private var showReview = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Einträge (eine Zeile pro Wert)")
                } footer: {
                    Text("""
                    Format: <name> [ttl] <TYP> <wert>
                    www 3600 A 192.0.2.1
                    @ MX 10 mail.\(domain).
                    alt TXT DELETE   (löscht das RRset)
                    Gleiche Namen/Typen werden zu einem RRset zusammengefasst und ersetzen den bisherigen Inhalt.
                    """)
                }
                Section {
                    Button { loadExisting() } label: { Label("Bestehende Einträge laden", systemImage: "square.and.arrow.down") }
                    Button { text = UIPasteboard.general.string ?? text } label: { Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") }
                }
                if let parseError {
                    Section { Text(parseError).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Bulk-Bearbeitung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Prüfen") { review() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showReview) { reviewSheet }
            .errorAlert($error)
        }
    }

    private var reviewSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(parsed.count) RRsets werden atomar übernommen – entweder alle oder keiner.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(parsed, id: \.self) { w in
                    let old = existing.first { $0.subname == w.subname && $0.type == w.type }
                    Section {
                        if w.records?.isEmpty == true {
                            Label("RRset wird gelöscht", systemImage: "trash").foregroundStyle(.red)
                        } else {
                            let d = RecordDiff(old: old?.records ?? [], new: w.records ?? [], oldTTL: old?.ttl, newTTL: w.ttl)
                            if old == nil { Label("Neu", systemImage: "plus.circle").foregroundStyle(.green) }
                            if d.ttlChanged { Text("TTL \(d.oldTTL ?? 0) → \(d.newTTL ?? 0) s").font(.caption) }
                            ForEach(d.removed, id: \.self) { Text("− \($0)").foregroundStyle(.red) }
                            ForEach(d.added, id: \.self) { Text("+ \($0)").foregroundStyle(.green) }
                            ForEach(d.unchanged, id: \.self) { Text("  \($0)").foregroundStyle(.secondary) }
                        }
                    } header: {
                        HStack {
                            TypeBadge(type: w.type)
                            Text(w.subname.isEmpty ? "@" : w.subname)
                            if RecordTypes.critical.contains(w.type) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    .font(.callout.monospaced())
                }
            }
            .navigationTitle("Änderungen prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zurück") { showReview = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await apply() }
                    } label: {
                        if busy { ProgressView() } else { Text("Übernehmen").bold() }
                    }
                    .disabled(busy)
                }
            }
        }
    }

    private func loadExisting() {
        text = existing
            .sorted { ($0.subname, $0.type) < ($1.subname, $1.type) }
            .flatMap { r in r.records.map { "\(r.displayName) \(r.ttl ?? minTTL) \(r.type) \($0)" } }
            .joined(separator: "\n")
    }

    private func review() {
        do {
            parsed = try ZoneLineParser.parse(text, defaultTTL: max(minTTL, 3600))
            parseError = nil
            if let tooLow = parsed.first(where: { ($0.ttl ?? minTTL) < minTTL && $0.records?.isEmpty == false }) {
                parseError = "TTL für \(tooLow.subname.isEmpty ? "@" : tooLow.subname) \(tooLow.type) liegt unter dem Minimum von \(minTTL) s."
                return
            }
            showReview = !parsed.isEmpty
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func apply() async {
        guard let client = app.client else { return }
        busy = true; defer { busy = false }
        do {
            try await client.bulk(domain: domain, method: "PATCH", parsed)
            await onSaved()
            showReview = false
            dismiss()
        } catch {
            showReview = false
            self.error = error.localizedDescription
        }
    }
}
