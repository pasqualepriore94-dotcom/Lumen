import SwiftUI

/// Gestione degli account: attivazione delle richieste, disattivazione, ruoli, reset password, eliminazione.
struct UsersAdminView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(AppState.self) private var app

    @State private var users: [AppUser] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var resetTarget: AppUser?
    @State private var resetPassword = ""
    @State private var deleteTarget: AppUser?

    private var pending: [AppUser] { users.filter { !$0.approved && $0.approvedAt == nil } }
    private var active: [AppUser] { users.filter(\.approved) }
    private var disabled: [AppUser] { users.filter { !$0.approved && $0.approvedAt != nil } }

    var body: some View {
        List {
            if !auth.hasServer {
                Section {
                    Text("Il server account non è configurato. Imposta l'URL della funzione lumen-auth dalla schermata di accesso (icona server) per gestire registrazioni e utenti.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { row($0) }
                } header: {
                    Text("In attesa di attivazione (\(pending.count))")
                }
            }
            Section("Attivi (\(active.count))") {
                ForEach(active) { row($0) }
            }
            if !disabled.isEmpty {
                Section("Disattivati") {
                    ForEach(disabled) { row($0) }
                }
            }
        }
        .overlay { if loading && users.isEmpty { ProgressView() } }
        .navigationTitle("Utenti")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .alert("Nuova password per \(resetTarget?.username ?? "")", isPresented: Binding(
            get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } })) {
            SecureField("Almeno 6 caratteri", text: $resetPassword)
            Button("Annulla", role: .cancel) { resetPassword = "" }
            Button("Imposta") {
                if let t = resetTarget { run("resetPassword", on: t, password: resetPassword) }
                resetPassword = ""
            }
        }
        .confirmationDialog("Eliminare \(deleteTarget?.username ?? "")?", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Elimina account", role: .destructive) {
                guard let t = deleteTarget else { return }
                Task {
                    do { try await auth.delete(t); await load() } catch { errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func row(_ u: AppUser) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(u.isAdmin ? app.accent : Color.white.opacity(0.15))
                .frame(width: 38, height: 38)
                .overlay(Text(u.username.prefix(1).uppercased()).font(.headline))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(u.username).font(.body.weight(.semibold))
                    if u.isAdmin {
                        Text("ADMIN").font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(app.accent.opacity(0.3), in: Capsule())
                    }
                    if u.id == auth.user?.id { Text("(tu)").font(.caption).foregroundStyle(.secondary) }
                }
                Text(u.email).font(.caption).foregroundStyle(.secondary)
                if let d = u.createdDate {
                    Text("Registrato il \(d.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !u.approved {
                Button("Attiva") { run("approve", on: u) }
                    .buttonStyle(GlassButtonStyle(tint: app.accent))
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
        .contextMenu { menu(u) }
        .swipeActions(edge: .trailing) {
            if u.id != auth.user?.id {
                Button(role: .destructive) { deleteTarget = u } label: { Label("Elimina", systemImage: "trash") }
                if u.approved {
                    Button { run("revoke", on: u) } label: { Label("Disattiva", systemImage: "pause.circle") }
                        .tint(.orange)
                }
            }
        }
        .swipeActions(edge: .leading) {
            if !u.approved {
                Button { run("approve", on: u) } label: { Label("Attiva", systemImage: "checkmark.circle") }
                    .tint(.green)
            }
        }
    }

    @ViewBuilder
    private func menu(_ u: AppUser) -> some View {
        if !u.approved {
            Button("Attiva", systemImage: "checkmark.circle") { run("approve", on: u) }
        }
        if u.id != auth.user?.id {
            if u.approved { Button("Disattiva", systemImage: "pause.circle") { run("revoke", on: u) } }
            if u.isAdmin {
                Button("Rendi utente normale", systemImage: "person") { run("makeUser", on: u) }
            } else {
                Button("Rendi amministratore", systemImage: "crown") { run("makeAdmin", on: u) }
            }
        }
        Button("Reimposta password", systemImage: "key") { resetTarget = u }
        if u.id != auth.user?.id {
            Button("Elimina", systemImage: "trash", role: .destructive) { deleteTarget = u }
        }
    }

    private func run(_ action: String, on user: AppUser, password: String? = nil) {
        Task {
            do {
                try await auth.perform(action, on: user, newPassword: password)
                errorMessage = nil
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard auth.hasServer else { return }
        loading = true
        defer { loading = false }
        do {
            users = try await auth.listUsers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
