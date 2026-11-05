import SwiftUI

// MARK: - Liste

struct TokensListView: View {
    @Environment(AppModel.self) private var app
    @State private var tokens: [DesecToken] = []
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var error: String?
    @State private var showCreate = false
    @State private var deleteTarget: DesecToken?
    @State private var showLoginTokens = false

    private var apiTokens: [DesecToken] { tokens.filter { !$0.isLoginToken }.sorted { $0.name.lowercased() < $1.name.lowercased() } }
    private var loginTokens: [DesecToken] { tokens.filter(\.isLoginToken).sorted { ($0.created ?? "") > ($1.created ?? "") } }

    var body: some View {
        NavigationStack {
            List {
                Section("API-Tokens") {
                    if apiTokens.isEmpty && loadedOnce { Text("Keine API-Tokens").foregroundStyle(.secondary) }
                    ForEach(apiTokens) { token in
                        NavigationLink(value: token) { TokenRow(token: token) }
                            .swipeActions { Button(role: .destructive) { deleteTarget = token } label: { Label("Löschen", systemImage: "trash") } }
                    }
                }
                Section {
                    DisclosureGroup("Login-Sitzungen (\(loginTokens.count))", isExpanded: $showLoginTokens) {
                        ForEach(loginTokens) { token in
                            NavigationLink(value: token) { TokenRow(token: token) }
                                .swipeActions { Button(role: .destructive) { deleteTarget = token } label: { Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right") } }
                        }
                    }
                } footer: {
                    Text("Login-Tokens entstehen durch Anmeldung mit Passwort (Web-Oberfläche oder diese App).")
                }
            }
            .overlay { if loading && tokens.isEmpty { ProgressView() } }
            .refreshable { await load() }
            .navigationTitle("Tokens")
            .navigationDestination(for: DesecToken.self) { token in
                TokenDetailView(token: token) { await load() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountSwitcher() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .sheet(isPresented: $showCreate) { CreateTokenView { await load() } }
            .confirmationDialog("Token „\(deleteTarget?.name.isEmpty == false ? deleteTarget!.name : "ohne Namen")“ löschen?",
                                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Token löschen", role: .destructive) {
                    if let t = deleteTarget { Task { await delete(t) } }
                }
            } message: {
                Text("Alle Clients, die dieses Token nutzen, verlieren sofort den Zugriff.")
            }
            .task(id: app.refreshTrigger) { await load() }
            .errorAlert($error)
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true; defer { loading = false; loadedOnce = true }
        do { tokens = try await client.tokens() }
        catch DesecError.forbidden {
            error = "Diesem Token fehlt die Berechtigung „Tokens verwalten“ (oder 2FA ist für die Sitzung noch nicht bestätigt)."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ token: DesecToken) async {
        guard let client = app.client else { return }
        do {
            try await client.deleteToken(id: token.id)
            tokens.removeAll { $0.id == token.id }
        } catch {
            self.error = error.localizedDescription
        }
        deleteTarget = nil
    }
}

struct TokenRow: View {
    let token: DesecToken

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(token.name.isEmpty ? "(ohne Namen)" : token.name).font(.body.weight(.medium))
                if token.isValid == false {
                    Text("abgelaufen").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.red.opacity(0.15), in: Capsule()).foregroundStyle(.red)
                }
                if token.mfa == true { Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).font(.caption) }
            }
            HStack(spacing: 10) {
                if token.permManageTokens { Label("Tokens", systemImage: "key").labelStyle(.titleAndIcon) }
                if token.permCreateDomain { Label("Anlegen", systemImage: "plus") }
                if token.permDeleteDomain { Label("Löschen", systemImage: "trash") }
                if token.autoPolicy == true { Label("Auto-Policy", systemImage: "wand.and.stars") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("Zuletzt genutzt: \(token.lastUsed == nil ? "nie" : DesecDate.format(token.lastUsed))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Formular (Erstellen / Bearbeiten)

struct TokenFormSections: View {
    @Binding var write: DesecTokenWrite
    @State private var subnetsText = ""

    var body: some View {
        Section("Name") {
            TextField("z. B. certbot oder Router", text: $write.name)
        }
        Section {
            Toggle("Tokens verwalten", isOn: $write.permManageTokens)
            Toggle("Domains anlegen", isOn: $write.permCreateDomain)
            Toggle("Domains löschen", isOn: $write.permDeleteDomain)
            Toggle("Automatische Policy für neue Domains", isOn: $write.autoPolicy)
        } header: {
            Text("Berechtigungen")
        } footer: {
            Text("Ohne Policies darf jedes Token alle DNS-Einträge schreiben. Ein Token mit „Tokens verwalten“ kann sich selbst weitere Rechte geben. Auto-Policy legt eine restriktive Standard-Policy an.")
        }
        Section {
            TextField("0.0.0.0/0, ::/0", text: $subnetsText, axis: .vertical)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: subnetsText) { _, new in
                    write.allowedSubnets = new.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
                        .map(String.init).filter { !$0.isEmpty }
                }
        } header: {
            Text("Erlaubte Netze")
        } footer: {
            Text("Kommagetrennte IPs oder Subnetze, von denen aus das Token genutzt werden darf.")
        }
        Section("Ablauf") {
            DurationEditor(title: "Maximales Alter", value: $write.maxAge)
            DurationEditor(title: "Maximale Inaktivität", value: $write.maxUnusedPeriod)
        }
        .onAppear { if subnetsText.isEmpty { subnetsText = write.allowedSubnets.joined(separator: ", ") } }
    }
}

/// Editor für Zeitdauern; nil = unbegrenzt.
struct DurationEditor: View {
    let title: String
    @Binding var value: String?

    private var enabled: Binding<Bool> {
        Binding(get: { value != nil }, set: { value = $0 ? DesecDuration.string(fromSeconds: 30 * 86400) : nil })
    }

    private var days: Binding<Int> {
        Binding(get: { (DesecDuration.seconds(from: value) ?? 0) / 86400 },
                set: { setTotal(days: $0, hours: hours.wrappedValue) })
    }

    private var hours: Binding<Int> {
        Binding(get: { ((DesecDuration.seconds(from: value) ?? 0) % 86400) / 3600 },
                set: { setTotal(days: days.wrappedValue, hours: $0) })
    }

    private func setTotal(days: Int, hours: Int) {
        value = DesecDuration.string(fromSeconds: max(days * 86400 + hours * 3600, 60))
    }

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: enabled)
            if value != nil {
                Stepper("\(days.wrappedValue) Tage", value: days, in: 0...3650)
                Stepper("\(hours.wrappedValue) Stunden", value: hours, in: 0...23)
            }
        }
    }
}

// MARK: - Erstellen

struct CreateTokenView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var onCreated: () async -> Void

    @State private var write = DesecTokenWrite()
    @State private var created: DesecToken?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let created, let secret = created.token {
                    TokenSecretView(token: created, secret: secret) { dismiss() }
                } else {
                    Form {
                        TokenFormSections(write: $write)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Erstellen") { Task { await create() } }.disabled(busy)
                        }
                    }
                }
            }
            .navigationTitle("Neues Token")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert($error)
        }
        .interactiveDismissDisabled(created != nil)
    }

    private func create() async {
        guard let client = app.client else { return }
        busy = true; defer { busy = false }
        do {
            created = try await client.createToken(write)
            await onCreated()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Zeigt das Token-Geheimnis genau einmal an.
struct TokenSecretView: View {
    @Environment(AppModel.self) private var app
    let token: DesecToken
    let secret: String
    var onDone: () -> Void
    @State private var addedAsAccount = false

    var body: some View {
        Form {
            Section {
                Label("Das Token wird nur jetzt angezeigt und kann später nicht erneut abgerufen werden.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Section("Token-Geheimnis") {
                Text(secret).font(.title3.monospaced()).textSelection(.enabled)
                Button { Clipboard.copy(secret) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                ShareLink(item: secret) { Label("Teilen", systemImage: "square.and.arrow.up") }
            }
            Section {
                Button {
                    let acc = StoredAccount(label: token.name.isEmpty ? "API-Token" : token.name, email: token.owner, kind: .apiToken)
                    app.addAccount(acc, token: secret, password: nil)
                    addedAsAccount = true
                } label: {
                    Label(addedAsAccount ? "Als Konto hinzugefügt" : "In dieser App als Konto verwenden", systemImage: "person.badge.plus")
                }
                .disabled(addedAsAccount)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Fertig") { onDone() } }
        }
    }
}

// MARK: - Detail / Bearbeiten / Policies

struct TokenDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var token: DesecToken
    var onChanged: () async -> Void

    @State private var write: DesecTokenWrite

    init(token: DesecToken, onChanged: @escaping () async -> Void) {
        _token = State(initialValue: token)
        _write = State(initialValue: DesecTokenWrite(from: token))
        self.onChanged = onChanged
    }
    @State private var policies: [TokenPolicy] = []
    @State private var editingPolicy: PolicyTarget?
    @State private var deletePolicy: TokenPolicy?
    @State private var confirmDeleteToken = false
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    struct PolicyTarget: Identifiable { let id = UUID(); let policy: TokenPolicy? }

    private var hasDefault: Bool { policies.contains(where: \.isDefault) }

    var body: some View {
        Form {
            Section("Informationen") {
                LabeledContent("Typ", value: token.isLoginToken ? (token.mfa == true ? "Login (2FA bestätigt)" : "Login") : "API-Token")
                LabeledContent("Gültig", value: token.isValid == false ? "Nein" : "Ja")
                LabeledContent("Erstellt", value: DesecDate.format(token.created))
                LabeledContent("Zuletzt genutzt", value: token.lastUsed == nil ? "nie" : DesecDate.format(token.lastUsed))
                LabeledContent("Max. Alter", value: DesecDuration.humanReadable(token.maxAge))
                LabeledContent("Max. Inaktivität", value: DesecDuration.humanReadable(token.maxUnusedPeriod))
                if let owner = token.owner { LabeledContent("Besitzer", value: owner) }
                if let o = token.userOverride { LabeledContent("Handelt für", value: o) }
                CopyRow(title: "Token-ID", value: token.id)
            }

            TokenFormSections(write: $write)

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack { Text(saved ? "Gespeichert ✓" : "Änderungen speichern"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy)
            }

            Section {
                if policies.isEmpty {
                    Text("Keine Policies – das Token darf alle RRsets schreiben.").foregroundStyle(.secondary)
                }
                ForEach(policies.sorted { $0.isDefault && !$1.isDefault }) { p in
                    Button { editingPolicy = PolicyTarget(policy: p) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.scopeDescription).foregroundStyle(.primary)
                                Text(p.permWrite ? "Schreiben erlaubt" : "Nur lesen").font(.caption)
                                    .foregroundStyle(p.permWrite ? Color.green : Color.orange)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions { Button(role: .destructive) { deletePolicy = p } label: { Label("Löschen", systemImage: "trash") } }
                }
                Button {
                    editingPolicy = PolicyTarget(policy: nil)
                } label: {
                    Label(hasDefault ? "Policy hinzufügen" : "Standard-Policy anlegen", systemImage: "plus.circle")
                }
            } header: {
                Text("RRset-Policies")
            } footer: {
                Text("Zuerst wird eine Standard-Policy benötigt. Spezifischere Policies (Domain › Subname › Typ) haben Vorrang. Lesen ist immer erlaubt.")
            }

            Section {
                Button(role: .destructive) { confirmDeleteToken = true } label: {
                    Label(token.isLoginToken ? "Sitzung beenden" : "Token löschen", systemImage: "trash")
                }
            }
        }
        .navigationTitle(token.name.isEmpty ? "Token" : token.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingPolicy) { target in
            PolicyEditorView(tokenID: token.id, original: target.policy, mustBeDefault: !hasDefault) { await loadPolicies() }
        }
        .confirmationDialog("Policy löschen?", isPresented: Binding(get: { deletePolicy != nil }, set: { if !$0 { deletePolicy = nil } }), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { if let p = deletePolicy { Task { await removePolicy(p) } } }
        } message: {
            Text(deletePolicy?.isDefault == true ? "Die Standard-Policy kann nur gelöscht werden, wenn keine anderen Policies existieren." : (deletePolicy?.scopeDescription ?? ""))
        }
        .confirmationDialog("Token löschen?", isPresented: $confirmDeleteToken, titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) { Task { await deleteToken() } }
        } message: {
            Text("Clients mit diesem Token verlieren sofort den Zugriff. Löschst du das Token dieser App-Sitzung, musst du dich neu anmelden.")
        }
        .task { await loadPolicies() }
        .errorAlert($error)
    }

    private func loadPolicies() async {
        guard let client = app.client else { return }
        do { policies = try await client.policies(tokenID: token.id) }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard let client = app.client else { return }
        busy = true; defer { busy = false }
        do {
            token = try await client.updateToken(id: token.id, write)
            write = DesecTokenWrite(from: token)
            saved = true
            await onChanged()
            await loadPolicies() // auto_policy kann eine Default-Policy anlegen
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removePolicy(_ p: TokenPolicy) async {
        guard let client = app.client, let id = p.id else { return }
        do {
            try await client.deletePolicy(tokenID: token.id, policyID: id)
            await loadPolicies()
        } catch {
            self.error = error.localizedDescription
        }
        deletePolicy = nil
    }

    private func deleteToken() async {
        guard let client = app.client else { return }
        do {
            try await client.deleteToken(id: token.id)
            await onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PolicyEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let tokenID: String
    let original: TokenPolicy?
    let mustBeDefault: Bool
    var onSaved: () async -> Void

    @State private var domain = ""
    @State private var anyDomain = true
    @State private var subname = ""
    @State private var anySubname = true
    @State private var type = "A"
    @State private var anyType = true
    @State private var permWrite = false
    @State private var domains: [String] = []
    @State private var busy = false
    @State private var error: String?

    private var isDefaultPolicy: Bool { mustBeDefault || original?.isDefault == true }

    var body: some View {
        NavigationStack {
            Form {
                if isDefaultPolicy {
                    Section {
                        Text("Standard-Policy: gilt für alle RRsets, für die keine spezifischere Policy existiert.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Geltungsbereich") {
                        Toggle("Alle Domains", isOn: $anyDomain)
                        if !anyDomain {
                            Picker("Domain", selection: $domain) {
                                ForEach(domains, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Toggle("Alle Subnames", isOn: $anySubname)
                        if !anySubname {
                            TextField("Subname (leer = Apex)", text: $subname)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Toggle("Alle Typen", isOn: $anyType)
                        if !anyType {
                            Picker("Typ", selection: $type) {
                                ForEach(RecordTypes.supported, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                }
                Section {
                    Toggle("Schreiben erlaubt", isOn: $permWrite)
                } footer: {
                    Text("Tipp: Für dynDNS mit IPv4 und IPv6 je eine Policy für A und AAAA anlegen.")
                }
            }
            .navigationTitle(original == nil ? "Neue Policy" : "Policy bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { Task { await save() } }
                        .disabled(busy || (!isDefaultPolicy && anyDomain && anySubname && anyType) || (!anyDomain && domain.isEmpty))
                }
            }
            .task { await setup() }
            .errorAlert($error)
        }
    }

    private func setup() async {
        if let p = original {
            anyDomain = p.domain == nil; domain = p.domain ?? ""
            anySubname = p.subname == nil; subname = p.subname ?? ""
            anyType = p.type == nil; type = p.type ?? "A"
            permWrite = p.permWrite
        }
        if let client = app.client, let list = try? await client.domains() {
            domains = list.map(\.name).sorted()
            if domain.isEmpty { domain = domains.first ?? "" }
        }
    }

    private func save() async {
        guard let client = app.client else { return }
        busy = true; defer { busy = false }
        var p = TokenPolicy(id: original?.id, permWrite: permWrite)
        if !isDefaultPolicy {
            p.domain = anyDomain ? nil : domain
            p.subname = anySubname ? nil : subname.lowercased()
            p.type = anyType ? nil : type
        }
        do {
            if original?.id != nil { _ = try await client.updatePolicy(tokenID: tokenID, p) }
            else { _ = try await client.createPolicy(tokenID: tokenID, p) }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
