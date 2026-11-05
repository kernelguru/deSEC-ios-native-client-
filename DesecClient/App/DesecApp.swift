import SwiftUI

@main
struct DesecApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color(red: 0.85, green: 0.62, blue: 0.0))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.lockIfNeeded() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            if app.accounts.isEmpty {
                WelcomeView()
            } else {
                MainTabView()
                    .id(app.currentID)
            }
            if app.isLocked {
                LockView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: app.isLocked)
        .sheet(item: $app.reauthAccount) { account in
            ReauthView(account: account)
                .interactiveDismissDisabled()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            DomainsListView()
                .tabItem { Label("Domains", systemImage: "globe") }
            TokensListView()
                .tabItem { Label("Tokens", systemImage: "key.horizontal") }
            DynDNSView()
                .tabItem { Label("dynDNS", systemImage: "arrow.triangle.2.circlepath") }
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                AppBadge(size: 96)
                Text("Gesperrt").font(.title2.bold())
                Button {
                    Task { await app.unlock() }
                } label: {
                    Label("Entsperren", systemImage: "faceid")
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .task { await app.unlock() }
    }
}

/// Kleines App-Symbol für die Oberfläche (eigenes Design, gelber Hintergrund).
struct AppBadge: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.86, blue: 0.2), Color(red: 1, green: 0.72, blue: 0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "lock.shield.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(red: 0.13, green: 0.13, blue: 0.15))
                .padding(size * 0.22)
        }
        .frame(width: size, height: size)
    }
}
