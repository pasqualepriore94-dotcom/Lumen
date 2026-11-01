import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @AppStorage("lumen.profileName") private var profileName = "Profilo"

    @State private var versionTaps = 0
    @State private var askPIN = false
    @State private var pinInput = ""
    @State private var wrongPIN = false
    @State private var editingName = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(spacing: 10) {
                    ProfileAvatar(size: 72)
                    Button { editingName = true } label: {
                        HStack(spacing: 6) {
                            Text(profileName).font(.title3.bold())
                            Image(systemName: "chevron.down").font(.caption.bold())
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                if !library.continueWatching.isEmpty {
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

                settings

                Text("\(app.config.appName) beta \(version)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { handleVersionTap() }
                    .accessibilityHidden(true)
            }
            .padding(.bottom, Theme.tabBarHeight + 30)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            TabHeader(title: "Il mio \(app.config.appName)", showsLogo: false)
                .background(Color.black)
        }
        .background(Color.black.ignoresSafeArea())
        .alert("Accesso riservato", isPresented: $askPIN) {
            SecureField("PIN", text: $pinInput).keyboardType(.numberPad)
            Button("Annulla", role: .cancel) { pinInput = "" }
            Button("Entra") { checkPIN() }
        } message: {
            Text("Inserisci il PIN amministratore.")
        }
        .alert("PIN errato", isPresented: $wrongPIN) {
            Button("OK", role: .cancel) {}
        }
        .alert("Nome profilo", isPresented: $editingName) {
            TextField("Nome", text: $profileName)
            Button("Fatto", role: .cancel) {}
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Impostazioni").padding(.bottom, 10)
            VStack(spacing: 0) {
                row(icon: "antenna.radiowaves.left.and.right", title: "Sorgente contenuti",
                    value: app.activeProviderConfig?.name ?? "Nessuna")
                Divider().overlay(.white.opacity(0.08))
                Button {
                    Task { await app.syncRemote() }
                } label: {
                    row(icon: "arrow.triangle.2.circlepath", title: "Aggiorna catalogo",
                        value: app.isSyncing ? "…" : nil)
                }
                .buttonStyle(.plain)
                Divider().overlay(.white.opacity(0.08))
                Button(role: .destructive) {
                    withAnimation { library.clearHistory() }
                } label: {
                    row(icon: "clock.arrow.circlepath", title: "Cancella cronologia visione", value: nil)
                }
                .buttonStyle(.plain)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    private func row(icon: String, title: String, value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(app.accent)
            Text(title)
            Spacer()
            if let value { Text(value).foregroundStyle(Theme.secondaryText).lineLimit(1) }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    /// Accesso nascosto: 7 tocchi sulla versione in fondo alla pagina.
    private func handleVersionTap() {
        versionTaps += 1
        if versionTaps >= 7 {
            versionTaps = 0
            pinInput = ""
            askPIN = true
        }
    }

    private func checkPIN() {
        if pinInput == app.adminPIN {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                app.showAdmin = true
            }
        } else {
            wrongPIN = true
        }
        pinInput = ""
    }
}
