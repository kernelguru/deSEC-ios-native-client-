import SwiftUI
import UIKit

/// Konto-Umschalter für die Navigationsleiste.
struct AccountSwitcher: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false

    var body: some View {
        Menu {
            ForEach(app.accounts) { acc in
                Button {
                    app.select(acc)
                } label: {
                    if acc.id == app.currentID {
                        Label(acc.label, systemImage: "checkmark")
                    } else {
                        Text(acc.label)
                    }
                }
            }
            Divider()
            Button { showAdd = true } label: { Label("Konto hinzufügen", systemImage: "plus") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                Text(app.current?.label ?? "Konto").lineLimit(1).font(.subheadline)
            }
        }
        .sheet(isPresented: $showAdd) { AddAccountView() }
    }
}

/// Bestätigung für kritische Aktionen: Name muss exakt eingetippt werden.
struct TypeToConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let confirmText: String
    let buttonTitle: String
    let action: () async -> Void
    @State private var input = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Section {
                    TextField(confirmText, text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                } header: {
                    Text("Zur Bestätigung „\(confirmText)“ eingeben")
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            busy = true
                            await action()
                            busy = false
                            dismiss()
                        }
                    } label: {
                        HStack { Text(buttonTitle).bold(); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces) != confirmText || busy)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Teilen-Dialog für Dateien (z. B. Zonefile-Export).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Farbiges Typ-Etikett für RRsets.
struct TypeBadge: View {
    let type: String

    var color: Color {
        switch type {
        case "A", "AAAA": return .blue
        case "CNAME", "DNAME": return .purple
        case "MX": return .orange
        case "TXT", "SPF": return .gray
        case "NS", "DS", "DNSKEY", "CDS", "CDNSKEY": return .red
        case "SRV", "URI": return .teal
        case "CAA", "TLSA", "SSHFP", "SMIMEA", "OPENPGPKEY": return .green
        case "HTTPS", "SVCB": return .indigo
        default: return .brown
        }
    }

    var body: some View {
        Text(type)
            .font(.caption.weight(.bold).monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(color)
    }
}

/// Zeile mit Wert und Kopieren-Knopf.
struct CopyRow: View {
    let title: String
    let value: String
    var monospaced = true

    var body: some View {
        Button {
            Clipboard.copy(value)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(value)
                        .font(monospaced ? .footnote.monospaced() : .body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "doc.on.doc").foregroundStyle(.tint)
                }
            }
        }
    }
}

/// Zustand für Ladeansichten.
struct LoadingOverlay: View {
    let loading: Bool
    var body: some View {
        if loading { ProgressView().controlSize(.large) }
    }
}
