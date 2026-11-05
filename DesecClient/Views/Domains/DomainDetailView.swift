import SwiftUI

struct DomainDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let domainName: String
    var onChanged: () async -> Void

    enum Tab: String, CaseIterable { case records = "Einträge", info = "Info & DNSSEC" }

    @State private var tab: Tab = .records
    @State private var domain: DesecDomain?
    @State private var rrsets: [RRset] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var typeFilter: String?
    @State private var editing: EditTarget?
    @State private var showBulk = false
    @State private var deleteRRset: RRset?
    @State private var showDeleteDomain = false
    @State private var shareItem: ShareItem?
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmBulkDelete = false
    @State private var rechecking = false

    struct EditTarget: Identifiable {
        let id = UUID()
        let rrset: RRset?
    }

    private var minTTL: Int { domain?.minimumTtl ?? 3600 }

    private var filtered: [RRset] {
        let s = search.lowercased()
        return rrsets
            .filter { typeFilter == nil || $0.type == typeFilter }
            .filter { s.isEmpty || $0.displayName.contains(s) || $0.type.lowercased() == s || $0.records.contains { $0.lowercased().contains(s) } }
            .sorted { ($0.subname, $0.type) < ($1.subname, $1.type) }
    }

    private var presentTypes: [String] { Array(Set(rrsets.map(\.type))).sorted() }

    var body: some View {
        List(selection: $selection) {
            Section {
                Picker("Ansicht", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if tab == .records { recordsSection } else { infoSections }
        }
        .environment(\.editMode, $editMode)
        .searchable(text: $search, prompt: "Name, Typ oder Wert")
        .refreshable { await load() }
        .overlay { if loading && rrsets.isEmpty { ProgressView() } }
        .navigationTitle(domainName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $editing) { target in
            RRsetEditorView(domain: domainName, original: target.rrset, minTTL: minTTL) { await load() }
        }
        .sheet(isPresented: $showBulk) {
            BulkEditorView(domain: domainName, minTTL: minTTL, existing: rrsets) { await load() }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .sheet(isPresented: $showDeleteDomain) {
            TypeToConfirmSheet(
                title: "Domain löschen",
                message: "„\(domainName)“ wird mit allen DNS-Einträgen sofort gelöscht. Das kann nicht rückgängig gemacht werden.",
                confirmText: domainName,
                buttonTitle: "Domain endgültig löschen"
            ) {
                await deleteDomain()
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteRRset != nil }, set: { if !$0 { deleteRRset = nil } }), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let r = deleteRRset { Task { await delete(r) } }
            }
        } message: {
            if let r = deleteRRset {
                Text(RecordTypes.critical.contains(r.type)
                     ? "Achtung: \(r.type)-Einträge sind kritisch für Delegation/DNSSEC. Löschen kann die Domain unerreichbar machen."
                     : r.records.joined(separator: "\n"))
            }
        }
        .confirmationDialog("\(selection.count) RRsets löschen?", isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("\(selection.count) RRsets löschen", role: .destructive) { Task { await bulkDelete() } }
        } message: {
            Text("Die Löschung erfolgt atomar in einem Schritt.")
        }
        .task { await load() }
        .errorAlert($error)
    }

    private var deleteTitle: String {
        guard let r = deleteRRset else { return "" }
        return "\(r.type)-Eintrag „\(r.displayName)“ löschen?"
    }

    // MARK: Einträge

    @ViewBuilder
    private var recordsSection: some View {
        if !presentTypes.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        filterChip(nil, label: "Alle")
                        ForEach(presentTypes, id: \.self) { filterChip($0, label: $0) }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
        }
        Section("\(filtered.count) RRsets") {
            ForEach(filtered) { rrset in
                RRsetRow(rrset: rrset)
                    .contentShape(Rectangle())
                    .onTapGesture { if editMode == .inactive { editing = EditTarget(rrset: rrset) } }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteRRset = rrset } label: { Label("Löschen", systemImage: "trash") }
                        Button { editing = EditTarget(rrset: rrset) } label: { Label("Bearbeiten", systemImage: "pencil") }
                            .tint(.orange)
                    }
                    .contextMenu {
                        Button { editing = EditTarget(rrset: rrset) } label: { Label("Bearbeiten", systemImage: "pencil") }
                        Button { Clipboard.copy(rrset.records.joined(separator: "\n")) } label: { Label("Werte kopieren", systemImage: "doc.on.doc") }
                        Button { Clipboard.copy(rrset.name ?? "\(rrset.displayName).\(domainName).") } label: { Label("Namen kopieren", systemImage: "textformat") }
                        Button(role: .destructive) { deleteRRset = rrset } label: { Label("Löschen", systemImage: "trash") }
                    }
                    .tag(rrset.id)
            }
        }
    }

    private func filterChip(_ type: String?, label: String) -> some View {
        Button {
            typeFilter = type
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(typeFilter == type ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Info

    @ViewBuilder
    private var infoSections: some View {
        if let domain {
            Section("Allgemein") {
                LabeledContent("Minimale TTL", value: "\(domain.minimumTtl ?? 0) s")
                LabeledContent("Angelegt", value: DesecDate.format(domain.created))
                LabeledContent("Veröffentlicht", value: DesecDate.format(domain.published))
                LabeledContent("Zuletzt geändert", value: DesecDate.format(domain.touched))
            }
            Section {
                if let s = domain.status {
                    LabeledContent("Delegation", value: s.nameserverText)
                    LabeledContent("DNSSEC", value: s.securityText)
                    if let ns = s.nameservers, !ns.isEmpty {
                        LabeledContent("Nameserver beim Parent", value: ns.joined(separator: "\n"))
                    }
                    if s.secureSince != nil { LabeledContent("Sicher seit", value: DesecDate.format(s.secureSince)) }
                    LabeledContent("Zuletzt geprüft", value: DesecDate.format(s.checked))
                } else {
                    Text("Noch kein Prüfergebnis.").foregroundStyle(.secondary)
                }
                Button {
                    Task { await recheck() }
                } label: {
                    HStack { Label("Delegation neu prüfen", systemImage: "arrow.clockwise"); if rechecking { Spacer(); ProgressView() } }
                }
                .disabled(rechecking)
            } header: {
                Text("Delegationsstatus")
            } footer: {
                Text("Eine Neuprüfung erfordert eine Anmeldung per E-Mail/Passwort (Login-Token).")
            }
            if let keys = domain.keys, !keys.isEmpty {
                Section {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        ForEach(key.ds, id: \.self) { ds in CopyRow(title: "DS", value: ds) }
                        CopyRow(title: (key.managed ?? true) ? "DNSKEY (von deSEC verwaltet)" : "DNSKEY (zusätzlich)", value: key.dnskey)
                    }
                    CopyRow(title: "Nameserver", value: "ns1.desec.io\nns2.desec.org", monospaced: true)
                } header: {
                    Text("DNSSEC")
                } footer: {
                    Text("Diese DS-Einträge beim Registrar hinterlegen. Tippen zum Kopieren.")
                }
            }
        } else if loading {
            Section { ProgressView() }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if editMode == .active {
                Button(role: .destructive) { confirmBulkDelete = true } label: { Image(systemName: "trash") }
                    .disabled(selection.isEmpty)
                Button("Fertig") { editMode = .inactive; selection.removeAll() }
            } else {
                Button { editing = EditTarget(rrset: nil) } label: { Image(systemName: "plus") }
                Menu {
                    Button { editing = EditTarget(rrset: nil) } label: { Label("Neuer Eintrag", systemImage: "plus") }
                    Button { showBulk = true } label: { Label("Mehrere Einträge (Bulk)", systemImage: "list.bullet.rectangle") }
                    Button { tab = .records; editMode = .active } label: { Label("Auswählen …", systemImage: "checkmark.circle") }
                    Divider()
                    Button { Task { await exportZone() } } label: { Label("Zonefile exportieren", systemImage: "square.and.arrow.up") }
                    Button { Clipboard.copy(domainName) } label: { Label("Domainnamen kopieren", systemImage: "doc.on.doc") }
                    Divider()
                    Button(role: .destructive) { showDeleteDomain = true } label: { Label("Domain löschen", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Aktionen

    private func load() async {
        guard let client = app.client else { return }
        loading = true; defer { loading = false }
        do {
            async let d = client.domain(domainName)
            async let r = client.rrsets(domain: domainName)
            domain = try await d
            rrsets = try await r
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ rrset: RRset) async {
        guard let client = app.client else { return }
        do {
            try await client.deleteRRset(domain: domainName, subname: rrset.subname, type: rrset.type)
            rrsets.removeAll { $0.id == rrset.id }
        } catch {
            self.error = error.localizedDescription
        }
        deleteRRset = nil
    }

    private func bulkDelete() async {
        guard let client = app.client else { return }
        let targets = rrsets.filter { selection.contains($0.id) }
            .map { RRsetWrite(subname: $0.subname, type: $0.type, ttl: nil, records: []) }
        do {
            try await client.bulk(domain: domainName, method: "PATCH", targets)
            selection.removeAll()
            editMode = .inactive
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func recheck() async {
        guard let client = app.client else { return }
        rechecking = true; defer { rechecking = false }
        do {
            var s = try await client.requestRecheck(domainName)
            if let requested = s.requested {
                // kurz warten, bis die Prüfung abgeschlossen ist
                for _ in 0..<6 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    s = try await client.status(domainName)
                    if let c = DesecDate.parse(s.checked), let r = DesecDate.parse(requested), c >= r { break }
                }
            }
            domain?.status = s
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func exportZone() async {
        guard let client = app.client else { return }
        do {
            let text = try await client.zonefile(domainName)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(domainName).zone")
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteDomain() async {
        guard let client = app.client else { return }
        do {
            try await client.deleteDomain(domainName)
            await onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RRsetRow: View {
    let rrset: RRset

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TypeBadge(type: rrset.type)
                Text(rrset.displayName).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if let ttl = rrset.ttl { Text("\(ttl) s").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(Array(rrset.records.prefix(4).enumerated()), id: \.offset) { _, rec in
                Text(rec).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            if rrset.records.count > 4 {
                Text("+ \(rrset.records.count - 4) weitere").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
