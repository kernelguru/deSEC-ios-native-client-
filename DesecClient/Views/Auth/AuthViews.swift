import SwiftUI

// MARK: - Willkommen

struct WelcomeView: View {
    @State private var showAdd = false
    @State private var showRegister = false
    @State private var showReset = false
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                AppBadge(size: 110)
                VStack(spacing: 8) {
                    Text("deSEC Client").font(.largeTitle.bold())
                    Text("DNS-Verwaltung für deine deSEC-Konten – Domains, Records, Tokens und dynDNS.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                Spacer()
                VStack(spacing: 12) {
                    Button { showAdd = true } label: {
                        Text("Konto hinzufügen").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button { showRegister = true } label: {
                        Text("Neues deSEC-Konto registrieren").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    HStack {
                        Button("Passwort vergessen") { showReset = true }
                        Spacer()
                        Button("Bestätigungslink") { showConfirm = true }
                    }
                    .font(.footnote)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .sheet(isPresented: $showAdd) { AddAccountView() }
            .sheet(isPresented: $showRegister) { RegisterView() }
            .sheet(isPresented: $showReset) { PasswordResetRequestView() }
            .sheet(isPresented: $showConfirm) { ConfirmLinkView() }
        }
    }
}

// MARK: - Konto hinzufügen

struct AddAccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case login = "E-Mail & Passwort", token = "API-Token" }
    @State private var mode: Mode = .login
    @State private var label = ""
    @State private var token = ""
    @State private var savePassword = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Anmeldung", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Bezeichnung (optional)", text: $label)
                } footer: {
                    Text(mode == .login
                         ? "Login-Tokens laufen nach 1 Stunde Inaktivität ab. Mit gespeichertem Passwort genügt danach der 2FA-Code."
                         : "API-Tokens sind nicht an 2FA gebunden. Für vollen Zugriff braucht das Token die passenden Rechte (Tokens verwalten, Domains anlegen/löschen).")
                }

                if mode == .login {
                    LoginFlowSection(savePassword: $savePassword) { secret, email, password in
                        let acc = StoredAccount(label: label.isEmpty ? email : label, email: email, kind: .login, savePassword: savePassword)
                        app.addAccount(acc, token: secret, password: password)
                        dismiss()
                    }
                } else {
                    Section("API-Token") {
                        SecureField("Token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .fontDesign(.monospaced)
                        Button {
                            Task { await addToken() }
                        } label: {
                            HStack { Text("Token prüfen & hinzufügen"); if busy { Spacer(); ProgressView() } }
                        }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
            }
            .navigationTitle("Konto hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .errorAlert($error)
        }
    }

    private func addToken() async {
        busy = true; defer { busy = false }
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = DesecClient(token: secret)
        do {
            // Domain-Liste funktioniert mit jedem gültigen Token
            _ = try await c.domains()
            let email = try? await c.account().email
            let acc = StoredAccount(label: label.isEmpty ? (email ?? "API-Token") : label, email: email, kind: .apiToken)
            app.addAccount(acc, token: secret, password: nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Wiederverwendbarer Anmeldeablauf: E-Mail/Passwort → optional TOTP-Code.
struct LoginFlowSection: View {
    @Binding var savePassword: Bool
    var presetEmail: String = ""
    var presetPassword: String = ""
    var showSaveToggle = true
    var onSuccess: (_ token: String, _ email: String, _ password: String) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var pending: (token: String, factors: [TOTPFactor])?
    @State private var factorID: String = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState var codeFocused: Bool

    var body: some View {
        Group {
            if let pending {
                Section {
                    if pending.factors.count > 1 {
                        Picker("Faktor", selection: $factorID) {
                            ForEach(pending.factors) { f in Text(f.name?.isEmpty == false ? f.name! : "TOTP").tag(f.id) }
                        }
                    }
                    TextField("6-stelliger Code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit())
                        .focused($codeFocused)
                        .onChange(of: code) { _, new in
                            if new.count == 6, new.allSatisfy(\.isNumber) { Task { await verify() } }
                        }
                    Button {
                        Task { await verify() }
                    } label: {
                        HStack { Text("Bestätigen"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(code.count < 6 || busy)
                } header: {
                    Text("Zwei-Faktor-Authentifizierung")
                } footer: {
                    Text("Gib den Code aus deiner Authenticator-App ein.")
                }
                .onAppear { codeFocused = true }
            } else {
                Section("Anmeldedaten") {
                    TextField("E-Mail", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $password)
                        .textContentType(.password)
                    if showSaveToggle {
                        Toggle("Passwort im Schlüsselbund speichern", isOn: $savePassword)
                    }
                    Button {
                        Task { await login() }
                    } label: {
                        HStack { Text("Anmelden"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(email.isEmpty || password.isEmpty || busy)
                }
            }
        }
        .onAppear {
            if email.isEmpty { email = presetEmail }
            if password.isEmpty { password = presetPassword }
        }
        .errorAlert($error)
    }

    private func login() async {
        busy = true; defer { busy = false }
        do {
            switch try await AppModel.login(email: email.trimmingCharacters(in: .whitespaces), password: password) {
            case .done(let token):
                onSuccess(token, email, password)
            case .needsTOTP(let token, let factors):
                factorID = factors.first?.id ?? ""
                pending = (token, factors)
            }
        } catch DesecError.forbidden {
            error = "E-Mail oder Passwort falsch (oder Konto noch nicht aktiviert)."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        guard let pending, !busy,
              let factor = pending.factors.first(where: { $0.id == factorID }) ?? pending.factors.first else { return }
        busy = true; defer { busy = false }
        do {
            try await AppModel.verifyTOTP(token: pending.token, factor: factor, code: code)
            onSuccess(pending.token, email, password)
        } catch {
            code = ""
            self.error = "Code ungültig: \(error.localizedDescription)"
        }
    }
}

// MARK: - Erneute Anmeldung

struct ReauthView: View {
    @Environment(AppModel.self) private var app
    let account: StoredAccount
    @State private var save = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Die Sitzung für „\(account.label)“ ist abgelaufen.", systemImage: "clock.badge.exclamationmark")
                }
                LoginFlowSection(savePassword: $save,
                                 presetEmail: account.email ?? "",
                                 presetPassword: app.savedPassword(for: account) ?? "",
                                 showSaveToggle: false) { token, _, password in
                    app.updateToken(token, for: account, password: password)
                }
            }
            .navigationTitle("Erneut anmelden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Später") { app.reauthAccount = nil }
                }
            }
        }
    }
}

// MARK: - Captcha

struct CaptchaSection: View {
    @Binding var captcha: Captcha?
    @Binding var solution: String
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Section {
            HStack {
                Spacer()
                if let data = captcha?.imageData, let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().interpolation(.none).scaledToFit().frame(height: 80)
                } else if loading {
                    ProgressView().frame(height: 80)
                } else {
                    Text("Kein Captcha geladen").foregroundStyle(.secondary).frame(height: 80)
                }
                Spacer()
            }
            TextField("Lösung", text: $solution)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Neues Captcha") { Task { await load() } }
        } header: {
            Text("Captcha")
        } footer: {
            Text("Jedes Captcha ist nur einmal gültig. Bei falscher Lösung wird automatisch ein neues benötigt.")
        }
        .task { if captcha == nil { await load() } }
        .onChange(of: captcha?.id) { _, new in
            if new == nil && !loading { Task { await load() } }
        }
        .errorAlert($error)
    }

    func load() async {
        loading = true; defer { loading = false }
        solution = ""
        do { captcha = try await DesecClient(token: nil).captcha() }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Registrierung

struct RegisterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var domain = ""
    @State private var outreach = true
    @State private var captcha: Captcha?
    @State private var solution = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                if done {
                    Section {
                        Label("Registrierung abgeschickt. Bitte bestätige den Link in der E-Mail (12 Stunden gültig). Du kannst ihn auch hier unter „Bestätigungslink“ einfügen.",
                              systemImage: "envelope.badge")
                    }
                } else {
                    Section("Konto") {
                        TextField("E-Mail", text: $email)
                            .keyboardType(.emailAddress).textContentType(.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Passwort", text: $password).textContentType(.newPassword)
                        SecureField("Passwort wiederholen", text: $password2).textContentType(.newPassword)
                    }
                    Section {
                        TextField("z. B. meinname.dedyn.io (optional)", text: $domain)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Gelegentliche Infos von deSEC per E-Mail", isOn: $outreach)
                    } header: {
                        Text("Optional")
                    } footer: {
                        Text("Ist die Domain nicht verfügbar, wird das Konto nach der Bestätigung wieder gelöscht.")
                    }
                    CaptchaSection(captcha: $captcha, solution: $solution)
                    Section {
                        Button {
                            Task { await register() }
                        } label: {
                            HStack { Text("Registrieren"); if busy { Spacer(); ProgressView() } }
                        }
                        .disabled(!valid || busy)
                    } footer: {
                        if !password.isEmpty && password != password2 { Text("Passwörter stimmen nicht überein.").foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Registrieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(done ? "Fertig" : "Abbrechen") { dismiss() } } }
            .errorAlert($error)
        }
    }

    private var valid: Bool {
        email.contains("@") && password.count >= 8 && password == password2 && captcha != nil && !solution.isEmpty
    }

    private func register() async {
        guard let captcha else { return }
        busy = true; defer { busy = false }
        do {
            try await DesecClient(token: nil).register(
                email: email.trimmingCharacters(in: .whitespaces), password: password,
                captcha: CaptchaSolution(id: captcha.id, solution: solution),
                domain: domain.trimmingCharacters(in: .whitespaces).lowercased(), outreach: outreach)
            done = true
        } catch {
            self.error = error.localizedDescription
            self.captcha = nil
            self.solution = ""
        }
    }
}

// MARK: - Passwort zurücksetzen / ändern

struct PasswordResetRequestView: View {
    @Environment(\.dismiss) private var dismiss
    var presetEmail = ""
    @State private var email = ""
    @State private var captcha: Captcha?
    @State private var solution = ""
    @State private var busy = false
    @State private var done = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if done {
                    Section {
                        Label("Falls ein Konto existiert, wurde ein Link per E-Mail verschickt. Füge ihn unter „Bestätigungslink“ ein, um ein neues Passwort zu setzen.",
                              systemImage: "envelope.badge")
                    }
                } else {
                    Section {
                        TextField("E-Mail", text: $email)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } footer: {
                        Text("deSEC nutzt diesen Ablauf auch für Passwortänderungen.")
                    }
                    CaptchaSection(captcha: $captcha, solution: $solution)
                    Section {
                        Button {
                            Task { await send() }
                        } label: {
                            HStack { Text("Link anfordern"); if busy { Spacer(); ProgressView() } }
                        }
                        .disabled(!email.contains("@") || solution.isEmpty || busy)
                    }
                }
            }
            .navigationTitle("Passwort zurücksetzen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(done ? "Fertig" : "Abbrechen") { dismiss() } } }
            .onAppear { if email.isEmpty { email = presetEmail } }
            .errorAlert($error)
        }
    }

    private func send() async {
        guard let captcha else { return }
        busy = true; defer { busy = false }
        do {
            try await DesecClient(token: nil).requestPasswordReset(email: email, captcha: CaptchaSolution(id: captcha.id, solution: solution))
            done = true
        } catch {
            self.error = error.localizedDescription
            self.captcha = nil
        }
    }
}

// MARK: - Bestätigungslink einlösen

struct ConfirmLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var newPassword = ""
    @State private var newPassword2 = ""
    @State private var captcha: Captcha?
    @State private var solution = ""
    @State private var needsCaptcha = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?

    private var parsed: (ConfirmationAction, String)? {
        // erwartet …/v/<aktion>/<code>/ (API) oder …/confirm/<aktion>/<code> (Web-Frontend)
        let parts = link.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        for (i, p) in parts.enumerated() {
            if let action = ConfirmationAction(rawValue: p), i + 1 < parts.count {
                return (action, parts[i + 1])
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://desec.io/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button("Aus Zwischenablage einfügen") { link = UIPasteboard.general.string ?? "" }
                } header: {
                    Text("Link aus der E-Mail")
                } footer: {
                    if let p = parsed { Text("Erkannt: \(p.0.title)") }
                    else if !link.isEmpty { Text("Link nicht erkannt.").foregroundStyle(.red) }
                }

                if parsed?.0 == .resetPassword {
                    Section("Neues Passwort") {
                        SecureField("Neues Passwort", text: $newPassword).textContentType(.newPassword)
                        SecureField("Wiederholen", text: $newPassword2).textContentType(.newPassword)
                    }
                }
                if parsed?.0 == .activateAccount && needsCaptcha {
                    CaptchaSection(captcha: $captcha, solution: $solution)
                }

                if let result {
                    Section { Label(result, systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                }

                Section {
                    Button(role: parsed?.0.isCritical == true ? .destructive : nil) {
                        if parsed?.0.isCritical == true { confirmDelete = true } else { Task { await submit() } }
                    } label: {
                        HStack { Text(parsed?.0.title ?? "Bestätigen"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(parsed == nil || busy || (parsed?.0 == .resetPassword && (newPassword.isEmpty || newPassword != newPassword2)))
                }
            }
            .navigationTitle("Bestätigungslink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .confirmationDialog("Konto endgültig löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Konto unwiderruflich löschen", role: .destructive) { Task { await submit() } }
            } message: {
                Text("Das deSEC-Konto wird vollständig entfernt. Dies kann nicht rückgängig gemacht werden.")
            }
            .errorAlert($error)
        }
    }

    private func submit() async {
        guard let p = parsed else { return }
        let action = p.0, code = p.1
        busy = true; defer { busy = false }
        var payload: [String: Any] = [:]
        if action == .resetPassword { payload["new_password"] = newPassword }
        if action == .activateAccount, let captcha, !solution.isEmpty {
            payload["captcha"] = ["id": captcha.id, "solution": solution]
        }
        do {
            result = try await DesecClient(token: nil).confirm(action: action, code: code, payload: payload)
        } catch {
            if action == .activateAccount, error.localizedDescription.lowercased().contains("captcha") {
                needsCaptcha = true
            }
            self.error = error.localizedDescription
        }
    }
}
