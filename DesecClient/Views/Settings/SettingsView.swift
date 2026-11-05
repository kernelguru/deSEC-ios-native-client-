import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var renameTarget: StoredAccount?
    @State private var renameText = ""
    @State private var removeTarget: StoredAccount?

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                if let current = app.current {
                    Section("Aktuelles Konto") {
                        NavigationLink {
                            AccountInfoView()
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(current.label)
                                    Text(current.kind == .login ? "E-Mail & Passwort" : "API-Token")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "person.crop.circle.fill")
                            }
                        }
                    }
                }

                Section {
                    ForEach(app.accounts) { acc in
                        Button {
                            app.select(acc)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(acc.label).foregroundStyle(.primary)
                                    Text([acc.email, acc.kind == .login ? "Login" : "API-Token"].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if acc.id == app.currentID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { removeTarget = acc } label: { Label("Entfernen", systemImage: "trash") }
                            Button { renameText = acc.label; renameTarget = acc } label: { Label("Umbenennen", systemImage: "pencil") }
                                .tint(.orange)
                        }
                    }
                    Button { showAdd = true } label: { Label("Konto hinzufügen", systemImage: "plus") }
                } header: {
                    Text("Konten")
                } footer: {
                    Text("Wischen zum Umbenennen oder Entfernen. Zugangsdaten liegen nur im Schlüsselbund dieses Geräts.")
                }

                Section {
                    Toggle(isOn: $app.lockEnabled) {
                        Label("App mit Face ID / Code sperren", systemImage: "faceid")
                    }
                } header: {
                    Text("Sicherheit")
                } footer: {
                    Text("Die App wird beim Wechsel in den Hintergrund gesperrt.")
                }

                Section("Info") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Link(destination: URL(string: "https://desec.readthedocs.io/")!) {
                        Label("deSEC API-Dokumentation", systemImage: "book")
                    }
                    Link(destination: URL(string: "https://desec.io/")!) {
                        Label("desec.io", systemImage: "safari")
                    }
                    Text("Inoffizieller Client. deSEC ist ein Projekt des deSEC e.V.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .sheet(isPresented: $showAdd) { AddAccountView() }
            .alert("Konto umbenennen", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Bezeichnung", text: $renameText)
                Button("Speichern") { if let t = renameTarget { app.rename(t, to: renameText) } }
                Button("Abbrechen", role: .cancel) {}
            }
            .confirmationDialog("„\(removeTarget?.label ?? "")“ aus der App entfernen?",
                                isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
                                titleVisibility: .visible) {
                if removeTarget?.kind == .login {
                    Button("Abmelden & entfernen", role: .destructive) {
                        if let t = removeTarget { Task { await app.remove(t, serverLogout: true) } }
                    }
                } else {
                    Button("Entfernen", role: .destructive) {
                        if let t = removeTarget { Task { await app.remove(t, serverLogout: false) } }
                    }
                }
            } message: {
                Text(removeTarget?.kind == .login
                     ? "Die Login-Sitzung wird beendet und die Zugangsdaten werden vom Gerät gelöscht."
                     : "Das Token wird nur vom Gerät entfernt – bei deSEC bleibt es gültig.")
            }
        }
    }
}
