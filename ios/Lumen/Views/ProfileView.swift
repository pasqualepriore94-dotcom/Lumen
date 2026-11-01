import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(AuthStore.self) private var auth

    @State private var showPassword = false
    @State private var confirmLogout = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if !library.continueWatching.isEmpty && app.provider.capabilities.streams {
                    ContinueWatchingRow(entries: library.continueWatching)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "La mia lista")
                    if library.myList.isEmpty {
                        Text("Tocca + su un titolo per aggiungerlo qui.")
                            .font(.subheadline).foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 16)
                    } else {
                        PosterRow(items: library.myList, layout: .poster)
                    }
                }

                if auth.isAdmin { adminCard }
                settings

                Text("\(app.config.appName) beta \(version)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, Theme.tabBarHeight + 30)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            TabHeader(title: "Il mio \(app.config.appName)", showsLogo: false)
                .background {
                    LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                }
        }
        .background {
            ZStack {
                Color.black
                LinearGradient(colors: [app.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPassword) { ChangePasswordSheet() }
        .confirmationDialog("Vuoi uscire dall'account?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Esci", role: .destructive) { auth.signOut() }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ProfileAvatar(size: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(auth.user?.username ?? "").font(.title2.bold())
                    if auth.isAdmin {
                        Text("ADMIN")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .liquidGlassCapsule(tint: app.accent)
                    }
                }
                Text(auth.user?.email ?? "").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(18)
        .liquidGlassCard(radius: 28)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var adminCard: some View {
        Button { app.showAdmin = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .liquidGlass(in: Circle(), tint: app.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Amministrazione").font(.headline)
                    Text("Utenti, sorgenti, aspetto dell'app").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .buttonStyle(GlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))))
        .padding(.horizontal, 16)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Impostazioni")
            VStack(spacing: 0) {
                row(icon: "film.stack", title: "Sorgente contenuti", value: app.activeProviderConfig?.name ?? "Nessuna")
                divider
                Button { Task { await app.syncRemote() } } label: {
                    row(icon: "arrow.triangle.2.circlepath", title: "Aggiorna catalogo", value: app.isSyncing ? "…" : nil)
                }
                .buttonStyle(.plain)
                divider
                Button { showPassword = true } label: {
                    row(icon: "key.fill", title: "Cambia password", value: nil)
                }
                .buttonStyle(.plain)
                divider
                Button { withAnimation { library.clearHistory() } } label: {
                    row(icon: "clock.arrow.circlepath", title: "Cancella cronologia visione", value: nil)
                }
                .buttonStyle(.plain)
                divider
                Button { confirmLogout = true } label: {
                    row(icon: "rectangle.portrait.and.arrow.right", title: "Esci", value: nil, destructive: true)
                }
                .buttonStyle(.plain)
            }
            .liquidGlassCard(radius: 24)
            .padding(.horizontal, 16)
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 52)
    }

    private func row(icon: String, title: String, value: String?, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(destructive ? .red : app.accent)
            Text(title).foregroundStyle(destructive ? .red : .white)
            Spacer()
            if let value { Text(value).foregroundStyle(Theme.secondaryText).lineLimit(1) }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(height: 50)
        .contentShape(Rectangle())
    }
}

struct ChangePasswordSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password attuale", text: $old)
                    SecureField("Nuova password", text: $new)
                    SecureField("Ripeti la nuova password", text: $confirm)
                } footer: {
                    Text(auth.hasServer ? "Almeno 6 caratteri." : "Senza server account la password vale solo su questo dispositivo.")
                }
                if let message {
                    Section { Text(message).font(.footnote) }
                }
            }
            .navigationTitle("Cambia password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { save() }.disabled(busy || old.isEmpty || new.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard new == confirm else { message = "Le nuove password non coincidono."; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await auth.changePassword(old: old, new: new)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
