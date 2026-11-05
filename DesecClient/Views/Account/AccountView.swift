import SwiftUI

/// Kontoinformationen und Kontoaktionen des aktuell gewählten deSEC-Kontos.
struct AccountInfoView: View {
    @Environment(AppModel.self) private var app
    @State private var account: DesecAccount?
    @State private var loading = false
    @State private var error: String?
    @State private var showEmailChange = false
    @State private var showPasswordReset = false
    @State private var showDelete = false
    @State private var showConfirmLink = false
    @State private var info: String?

    var body: some View {
        Form {
            if let account {
                Section("deSEC-Konto") {
                    LabeledContent("E-Mail", value: account.email)
                    LabeledContent("Registriert", value: DesecDate.format(account.created))
                    if let used = account.domainsUnderManagement, let limit = account.limitDomains {
                        LabeledContent("Domains", value: "\(used) von \(limit)")
                        ProgressView(value: Double(used), total: Double(max(limit, 1)))
                    }
                    if let secure = account.secureDomains { LabeledContent("Sicher delegiert", value: "\(secure)") }
                    CopyRow(title: "Konto-ID", value: account.id)
                }
                Section {
                    Toggle("Infos von deSEC per E-Mail", isOn: Binding(
                        get: { account.outreachPreference },
                        set: { v in Task { await setOutreach(v) } }))
                } footer: {
                    Text("Über wichtige (breaking) Änderungen informiert deSEC unabhängig davon.")
                }
            } else if loading {
                Section { ProgressView() }
            }

            Section("Zugang") {
                Button { showEmailChange = true } label: { Label("E-Mail-Adresse ändern", systemImage: "envelope") }
                Button { showPasswordReset = true } label: { Label("Passwort ändern / zurücksetzen", systemImage: "key") }
                Button { showConfirmLink = true } label: { Label("Bestätigungslink einlösen", systemImage: "link") }
            }

            Section {
                Button(role: .destructive) { showDelete = true } label: { Label("deSEC-Konto löschen", systemImage: "person.crop.circle.badge.xmark") }
            } footer: {
                Text("Vorher müssen alle Domains gelöscht werden. Die Löschung wird per E-Mail bestätigt.")
            }

            if let info {
                Section { Label(info, systemImage: "envelope.badge").foregroundStyle(.green) }
            }
        }
        .navigationTitle("deSEC-Konto")
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showEmailChange) {
            CredentialActionView(mode: .changeEmail, email: account?.email ?? app.current?.email ?? "") { info = $0 }
        }
        .sheet(isPresented: $showDelete) {
            CredentialActionView(mode: .deleteAccount, email: account?.email ?? app.current?.email ?? "") { info = $0 }
        }
        .sheet(isPresented: $showPasswordReset) { PasswordResetRequestView(presetEmail: account?.email ?? app.current?.email ?? "") }
        .sheet(isPresented: $showConfirmLink) { ConfirmLinkView() }
        .errorAlert($error)
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true; defer { loading = false }
        do { account = try await client.account() }
        catch DesecError.forbidden {
            error = "Kontodaten erfordern ein Token mit „Tokens verwalten“ ohne Policies."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setOutreach(_ value: Bool) async {
        guard let client = app.client else { return }
        do { account = try await client.setOutreach(value) }
        catch { self.error = error.localizedDescription }
    }
}

/// E-Mail ändern oder Konto löschen – beides erfordert das Passwort.
struct CredentialActionView: View {
    enum Mode { case changeEmail, deleteAccount }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let email: String
    var onDone: (String) -> Void

    @State private var emailField = ""
    @State private var password = ""
    @State private var newEmail = ""
    @State private var confirmText = ""
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool {
        switch mode {
        case .changeEmail: return !password.isEmpty && newEmail.contains("@")
        case .deleteAccount: return !password.isEmpty && confirmText == "LÖSCHEN"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode == .deleteAccount {
                    Section {
                        Label("Das Konto wird nach Bestätigung per E-Mail unwiderruflich gelöscht. Es dürfen keine Domains mehr vorhanden sein.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section("Anmeldedaten") {
                    TextField("E-Mail", text: $emailField)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passwort", text: $password).textContentType(.password)
                }
                if mode == .changeEmail {
                    Section("Neue E-Mail-Adresse") {
                        TextField("neu@example.com", text: $newEmail)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } else {
                    Section("Zur Bestätigung „LÖSCHEN“ eingeben") {
                        TextField("LÖSCHEN", text: $confirmText).textInputAutocapitalization(.characters)
                    }
                }
                Section {
                    Button(role: mode == .deleteAccount ? .destructive : nil) {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text(mode == .changeEmail ? "Änderung anfordern" : "Löschung anfordern")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!valid || busy)
                }
            }
            .navigationTitle(mode == .changeEmail ? "E-Mail ändern" : "Konto löschen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .onAppear { if emailField.isEmpty { emailField = email } }
            .errorAlert($error)
        }
    }

    private func submit() async {
        busy = true; defer { busy = false }
        let c = DesecClient(token: nil)
        do {
            switch mode {
            case .changeEmail:
                try await c.requestEmailChange(email: emailField, password: password, newEmail: newEmail)
                onDone("Bestätigungslink an \(newEmail) gesendet (12 Stunden gültig).")
            case .deleteAccount:
                try await c.requestAccountDeletion(email: emailField, password: password)
                onDone("Bestätigungslink zur Kontolöschung wurde per E-Mail verschickt.")
            }
            dismiss()
        } catch DesecError.conflict {
            error = "Das Konto enthält noch Domains. Bitte zuerst alle Domains löschen."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
