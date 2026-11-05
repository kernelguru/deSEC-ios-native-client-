import SwiftUI

/// Anlegen bzw. Bearbeiten eines RRsets mit Vorschau der Änderungen.
struct RRsetEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let domain: String
    let original: RRset?
    let minTTL: Int
    var onSaved: () async -> Void

    @State private var subname = ""
    @State private var type = "A"
    @State private var ttl = 3600
    @State private var records: [Entry] = [Entry()]

    struct Entry: Identifiable { let id = UUID(); var value = "" }
    @State private var autoNormalize = true
    @State private var busy = false
    @State private var error: String?
    @State private var showReview = false
    @State private var confirmDelete = false

    private var isNew: Bool { original == nil }

    private var cleanedRecords: [String] {
        records.map { autoNormalize ? RecordTypes.normalize($0.value, type: type) : $0.value.trimmingCharacters(in: .whitespaces) }
               .filter { !$0.isEmpty }
    }

    private var diff: RecordDiff {
        RecordDiff(old: original?.records ?? [], new: cleanedRecords, oldTTL: original?.ttl, newTTL: ttl)
    }

    private var validationMessage: String? {
        if cleanedRecords.isEmpty { return "Mindestens ein Wert ist nötig." }
        if ttl < minTTL { return "TTL muss mindestens \(minTTL) s betragen." }
        if ttl > 86400 { return "TTL darf höchstens 86400 s betragen." }
        if type == "CNAME" && cleanedRecords.count > 1 { return "CNAME erlaubt nur einen Wert." }
        if type == "CNAME" && subname.isEmpty { return "CNAME ist am Zonen-Apex nicht erlaubt." }
        if type == "SOA" { return "SOA wird automatisch verwaltet." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isNew {
                        HStack {
                            TextField("Subname (leer = @)", text: $subname)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text(".\(domain)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Picker("Typ", selection: $type) {
                            Section("Häufig") {
                                ForEach(RecordTypes.common, id: \.self) { Text($0).tag($0) }
                            }
                            Section("Alle") {
                                ForEach(RecordTypes.supported.filter { !RecordTypes.common.contains($0) }, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    } else {
                        LabeledContent("Name", value: original?.name ?? "\(subname.isEmpty ? "@" : subname).\(domain).")
                        LabeledContent("Typ") { TypeBadge(type: type) }
                    }
                    Stepper(value: $ttl, in: minTTL...86400, step: ttlStep) {
                        HStack {
                            Text("TTL")
                            Spacer()
                            TextField("TTL", value: $ttl, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("s").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Minimale TTL dieser Domain: \(minTTL) s")
                }

                Section {
                    ForEach($records) { $entry in
                        HStack {
                            TextField(RecordTypes.placeholder(for: type), text: $entry.value, axis: .vertical)
                                .font(.callout.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if records.count > 1 {
                                Button {
                                    let id = entry.id
                                    records.removeAll { $0.id == id }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button { records.append(Entry()) } label: { Label("Wert hinzufügen", systemImage: "plus.circle") }
                    Toggle("Werte automatisch korrigieren", isOn: $autoNormalize)
                } header: {
                    Text("Werte")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let hint = RecordTypes.hint(for: type) { Text(hint) }
                        if let msg = validationMessage { Text(msg).foregroundStyle(.red) }
                    }
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: { Label("RRset löschen", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle(isNew ? "Neuer Eintrag" : "Eintrag bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Anlegen" : "Prüfen") {
                        if isNew { Task { await save() } } else { showReview = true }
                    }
                    .disabled(validationMessage != nil || busy || (!isNew && diff.isEmpty))
                }
            }
            .sheet(isPresented: $showReview) {
                DiffReviewView(title: "\(type) \(subname.isEmpty ? "@" : subname)", diff: diff,
                               critical: RecordTypes.critical.contains(type) || (subname.isEmpty && type == "NS")) {
                    await save()
                }
            }
            .confirmationDialog("RRset löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { Task { await deleteRRset() } }
            } message: {
                Text(RecordTypes.critical.contains(type)
                     ? "Achtung: \(type)-Einträge sind kritisch. Löschen kann die Domain unerreichbar machen."
                     : "Alle \(original?.records.count ?? 0) Werte dieses RRsets werden entfernt.")
            }
            .onAppear(perform: setup)
            .errorAlert($error)
        }
    }

    private var ttlStep: Int { ttl >= 3600 ? 3600 : 60 }

    private func setup() {
        if let o = original {
            subname = o.subname
            type = o.type
            ttl = o.ttl ?? max(minTTL, 3600)
            records = o.records.isEmpty ? [Entry()] : o.records.map { Entry(value: $0) }
        } else {
            ttl = max(minTTL, 3600)
        }
    }

    private func save() async {
        guard let client = app.client else { return }
        busy = true; defer { busy = false }
        do {
            if isNew {
                _ = try await client.createRRset(domain: domain, RRsetWrite(
                    subname: subname.trimmingCharacters(in: .whitespaces).lowercased(),
                    type: type, ttl: ttl, records: cleanedRecords))
            } else {
                _ = try await client.updateRRset(domain: domain, subname: subname, type: type, ttl: ttl, records: cleanedRecords)
            }
            await onSaved()
            showReview = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteRRset() async {
        guard let client = app.client else { return }
        do {
            try await client.deleteRRset(domain: domain, subname: subname, type: type)
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Zeigt alte und neue Werte vor dem Speichern.
struct DiffReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let diff: RecordDiff
    var critical = false
    let onConfirm: () async -> Void
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                if critical {
                    Section {
                        Label("Kritischer Eintrag: Fehler können die Domain unerreichbar machen.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if diff.ttlChanged {
                    Section("TTL") {
                        HStack {
                            Text("\(diff.oldTTL ?? 0) s").strikethrough().foregroundStyle(.red)
                            Image(systemName: "arrow.right")
                            Text("\(diff.newTTL ?? 0) s").foregroundStyle(.green)
                        }
                    }
                }
                if !diff.removed.isEmpty {
                    Section("Entfernt") {
                        ForEach(diff.removed, id: \.self) { r in
                            Label(r, systemImage: "minus").font(.callout.monospaced()).foregroundStyle(.red)
                        }
                    }
                }
                if !diff.added.isEmpty {
                    Section("Hinzugefügt") {
                        ForEach(diff.added, id: \.self) { r in
                            Label(r, systemImage: "plus").font(.callout.monospaced()).foregroundStyle(.green)
                        }
                    }
                }
                if !diff.unchanged.isEmpty {
                    Section("Unverändert") {
                        ForEach(diff.unchanged, id: \.self) { r in
                            Text(r).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zurück") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { busy = true; await onConfirm(); busy = false }
                    } label: {
                        if busy { ProgressView() } else { Text("Speichern").bold() }
                    }
                    .disabled(busy)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
