import SwiftUI
import UniformTypeIdentifiers

struct DomainsListView: View {
    @Environment(AppModel.self) private var app
    @State private var domains: [DesecDomain] = []
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var error: String?
    @State private var search = ""
    @State private var showCreate = false
    @State private var showFinder = false
    @State private var deleteTarget: DesecDomain?

    private var filtered: [DesecDomain] {
        let s = search.lowercased().trimmingCharacters(in: .whitespaces)
        let list = domains.sorted { $0.name < $1.name }
        return s.isEmpty ? list : list.filter { $0.name.contains(s) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { domain in
                    NavigationLink(value: domain.name) {
                        DomainRow(domain: domain)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteTarget = domain } label: { Label("Löschen", systemImage: "trash") }
                    }
                }
            }
            .overlay {
                if loading && domains.isEmpty { ProgressView() }
                else if loadedOnce && domains.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Domains", systemImage: "globe")
                    } description: {
                        Text("Lege deine erste Domain an, z. B. name.dedyn.io.")
                    } actions: {
                        Button("Domain anlegen") { showCreate = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .searchable(text: $search, prompt: "Domains durchsuchen")
            .refreshable { await load() }
            .navigationTitle("Domains")
            .navigationDestination(for: String.self) { name in
                DomainDetailView(domainName: name) { await load() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountSwitcher() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showCreate = true } label: { Label("Domain anlegen", systemImage: "plus") }
                        Button { showFinder = true } label: { Label("Zuständige Domain finden", systemImage: "magnifyingglass") }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateDomainView { await load() }
            }
            .sheet(isPresented: $showFinder) { ResponsibleDomainView() }
            .sheet(item: $deleteTarget) { domain in
                TypeToConfirmSheet(
                    title: "Domain löschen",
                    message: "„\(domain.name)“ wird mit allen DNS-Einträgen sofort gelöscht. Das kann nicht rückgängig gemacht werden.",
                    confirmText: domain.name,
                    buttonTitle: "Domain endgültig löschen"
                ) {
                    await delete(domain)
                }
            }
            .task(id: app.refreshTrigger) { await load() }
            .errorAlert($error)
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true; defer { loading = false; loadedOnce = true }
        do { domains = try await client.domains() }
        catch { self.error = error.localizedDescription }
    }

    private func delete(_ domain: DesecDomain) async {
        guard let client = app.client else { return }
        do {
            try await client.deleteDomain(domain.name)
            domains.removeAll { $0.name == domain.name }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DomainRow: View {
    let domain: DesecDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(domain.name).font(.body.weight(.medium))
            HStack(spacing: 8) {
                if let s = domain.status {
                    Image(systemName: s.securityStatus == "secure" ? "lock.fill" : (s.securityStatus == "misconfigured" ? "exclamationmark.lock.fill" : "lock.open"))
                        .foregroundStyle(s.securityStatus == "secure" ? Color.green : (s.securityStatus == "misconfigured" ? Color.red : Color.secondary))
                }
                Text("Geändert: \(DesecDate.format(domain.touched ?? domain.published))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Domain anlegen

struct CreateDomainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var onCreated: () async -> Void

    @State private var name = ""
    @State private var zonefile = ""
    @State private var importZone = false
    @State private var showImporter = false
    @State private var busy = false
    @State private var error: String?
    @State private var created: DesecDomain?

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    Section {
                        Label("„\(created.name)“ wurde angelegt.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if let keys = created.keys, !keys.isEmpty {
                        Section {
                            ForEach(keys.flatMap(\.ds), id: \.self) { ds in CopyRow(title: "DS", value: ds) }
                        } header: {
                            Text("DS-Einträge für den Registrar")
                        } footer: {
                            Text("Hinterlege diese DS-Einträge bei deinem Registrar, um DNSSEC zu aktivieren. Nameserver: ns1.desec.io und ns2.desec.org.")
                        }
                    }
                } else {
                    Section {
                        TextField("example.com oder name.dedyn.io", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("Domainname")
                    } footer: {
                        Text("Unter dedyn.io ist eine Domain pro Konto möglich. IDNs bitte in Punycode (xn--…).")
                    }
                    Section {
                        Toggle("Zonefile importieren", isOn: $importZone)
                        if importZone {
                            TextEditor(text: $zonefile)
                                .font(.footnote.monospaced())
                                .frame(minHeight: 160)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button { showImporter = true } label: { Label("Datei wählen …", systemImage: "doc") }
                        }
                    } footer: {
                        if importZone {
                            Text("NS am Apex, DNSKEY, RRSIG usw. werden ignoriert. Bei Fehlern wird die Domain nicht angelegt.")
                        }
                    }
                    Section {
                        Button {
                            Task { await create() }
                        } label: {
                            HStack { Text("Anlegen"); if busy { Spacer(); ProgressView() } }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
            }
            .navigationTitle("Neue Domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(created == nil ? "Abbrechen" : "Fertig") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text, .data]) { result in
                if case .success(let url) = result {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    zonefile = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                }
            }
            .errorAlert($error)
        }
    }

    private func create() async {
        guard let client = app.client else { return }
        busy = true; defer { busy = false }
        do {
            created = try await client.createDomain(
                name: name.trimmingCharacters(in: .whitespaces).lowercased(),
                zonefile: importZone ? zonefile : nil)
            await onCreated()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Zuständige Domain finden (owns_qname)

struct ResponsibleDomainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var qname = ""
    @State private var result: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("_acme-challenge.www.example.com", text: $qname)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        Task { await find() }
                    } label: {
                        HStack { Text("Suchen"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(qname.isEmpty || busy)
                } footer: {
                    Text("Ermittelt, welche deiner Domains für einen DNS-Namen zuständig ist – und welcher Subname dort zu verwenden ist.")
                }
                if let result {
                    Section("Ergebnis") { Text(result).textSelection(.enabled) }
                }
            }
            .navigationTitle("Zuständige Domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .errorAlert($error)
        }
    }

    private func find() async {
        guard let client = app.client else { return }
        busy = true; defer { busy = false }
        let q = qname.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        do {
            if let d = try await client.domains(ownsQName: q).first {
                var sub = q == d.name ? "" : String(q.dropLast(d.name.count + 1))
                if sub.isEmpty { sub = "@" }
                result = "Domain: \(d.name)\nSubname: \(sub)"
            } else {
                result = "Keine deiner Domains ist für diesen Namen zuständig."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
