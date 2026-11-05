import SwiftUI

struct DynDNSView: View {
    @Environment(AppModel.self) private var app

    enum IPMode: String, CaseIterable, Identifiable {
        case detect = "Erkennen", manual = "Manuell", preserve = "Beibehalten", remove = "Entfernen"
        var id: String { rawValue }
    }

    @AppStorage("dyndns.hostnames") private var hostnames = ""
    @State private var v4Mode: IPMode = .detect
    @State private var v6Mode: IPMode = .preserve
    @State private var v4 = ""
    @State private var v6 = ""
    @State private var useCustomToken = false
    @State private var customToken = ""
    @State private var detectedV4: String?
    @State private var detectedV6: String?
    @State private var domains: [String] = []
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("home.example.dedyn.io", text: $hostnames, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !domains.isEmpty {
                        Menu {
                            ForEach(domains, id: \.self) { d in
                                Button(d) { append(d) }
                            }
                        } label: {
                            Label("Domain einfügen", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Hostname(s)")
                } footer: {
                    Text("Mehrere Namen kommagetrennt – alle müssen zur selben Domain gehören. Das Update ist atomar, neue Einträge haben 60 s TTL.")
                }

                ipSection(title: "IPv4 (A)", mode: $v4Mode, value: $v4, detected: detectedV4, placeholder: "203.0.113.10")
                ipSection(title: "IPv6 (AAAA)", mode: $v6Mode, value: $v6, detected: detectedV6, placeholder: "2001:db8::10")

                Section {
                    Toggle("Anderes Token verwenden", isOn: $useCustomToken)
                    if useCustomToken {
                        SecureField("Token", text: $customToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().fontDesign(.monospaced)
                    }
                } header: {
                    Text("Authentifizierung")
                } footer: {
                    Text(useCustomToken ? "Ideal: ein Token mit Policies nur für A/AAAA dieses Hosts." : "Es wird das Token des aktuellen Kontos genutzt.")
                }

                Section {
                    Button {
                        Task { await update() }
                    } label: {
                        HStack { Label("IP-Update senden", systemImage: "paperplane.fill"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(hostnames.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    if let result {
                        Label("Antwort: \(result)", systemImage: result == "good" ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(result == "good" ? Color.green : Color.primary)
                    }
                }
            }
            .navigationTitle("dynDNS")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountSwitcher() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await detect() } } label: { Image(systemName: "network") }
                }
            }
            .task(id: app.refreshTrigger) {
                await detect()
                if let c = app.client, let list = try? await c.domains() { domains = list.map(\.name).sorted() }
            }
            .errorAlert($error)
        }
    }

    @ViewBuilder
    private func ipSection(title: String, mode: Binding<IPMode>, value: Binding<String>, detected: String?, placeholder: String) -> some View {
        Section {
            Picker("Modus", selection: mode) {
                ForEach(IPMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch mode.wrappedValue {
            case .detect:
                LabeledContent("Erkannt", value: detected ?? "–")
            case .manual:
                TextField(placeholder, text: value)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
            case .preserve:
                Text("Bestehender Eintrag bleibt unverändert.").foregroundStyle(.secondary)
            case .remove:
                Text("Eintrag wird aus dem DNS entfernt.").foregroundStyle(.red)
            }
        } header: {
            Text(title)
        }
    }

    private func append(_ domain: String) {
        let trimmed = hostnames.trimmingCharacters(in: .whitespaces)
        hostnames = trimmed.isEmpty ? domain : trimmed + "," + domain
    }

    private func param(_ mode: IPMode, manual: String, detected: String?) -> String? {
        switch mode {
        case .detect: return detected ?? "preserve"
        case .manual: return manual.trimmingCharacters(in: .whitespaces)
        case .preserve: return "preserve"
        case .remove: return ""
        }
    }

    private func detect() async {
        guard let c = app.client else { return }
        detectedV4 = try? await c.publicIP(v6: false)
        detectedV6 = try? await c.publicIP(v6: true)
        if detectedV4?.isEmpty == true { detectedV4 = nil }
        if detectedV6?.isEmpty == true { detectedV6 = nil }
    }

    private func update() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        result = nil
        let names = hostnames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
        do {
            result = try await c.dynDNSUpdate(
                hostnames: names,
                ipv4: param(v4Mode, manual: v4, detected: detectedV4),
                ipv6: param(v6Mode, manual: v6, detected: detectedV6),
                token: useCustomToken ? customToken.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
