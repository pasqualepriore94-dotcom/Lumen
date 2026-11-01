import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var app
    @Environment(AuthStore.self) private var auth

    private enum Mode: String, CaseIterable { case login = "Accedi", register = "Registrati" }
    private enum Field: Hashable { case username, email, password, confirm }

    @State private var mode: Mode = .login
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showServer = false
    @FocusState private var focus: Field?

    var body: some View {
        ZStack {
            AuroraBackground(accent: app.accent)

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 40)
                    VStack(spacing: 14) {
                        LogoMark(size: 72)
                            .shadow(color: app.accent.opacity(0.6), radius: 30)
                        Text(app.config.appName)
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                        Text(mode == .login ? "Bentornato. Accedi per continuare." : "Crea il tuo account: l'amministratore lo attiverà.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }

                    card
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topTrailing) {
            Button { showServer = true } label: {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
            .padding(.trailing, 18)
            .padding(.top, 6)
            .accessibilityLabel("Server account")
        }
        .sheet(isPresented: $showServer) { ServerSettingsSheet() }
        .animation(.snappy(duration: 0.3), value: mode)
    }

    private var card: some View {
        VStack(spacing: 16) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Button {
                            mode = m
                            errorMessage = nil
                            successMessage = nil
                        } label: {
                            Text(m.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(GlassButtonStyle(tint: mode == m ? app.accent : nil))
                    }
                }
            }

            GlassField(icon: "person", placeholder: mode == .login ? "Username o email" : "Username", text: $username)
                .textContentType(.username)
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { focus = mode == .login ? .password : .email }

            if mode == .register {
                GlassField(icon: "envelope", placeholder: "Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            GlassField(icon: "lock", placeholder: "Password", text: $password, secure: true)
                .textContentType(mode == .login ? .password : .newPassword)
                .focused($focus, equals: .password)
                .submitLabel(mode == .login ? .go : .next)
                .onSubmit { if mode == .login { submit() } else { focus = .confirm } }

            if mode == .register {
                GlassField(icon: "lock.rotation", placeholder: "Conferma password", text: $confirm, secure: true)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .confirm)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let successMessage {
                Label(successMessage, systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.5, green: 0.95, blue: 0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(.white) }
                    Text(mode == .login ? "Accedi" : "Invia richiesta")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
            }
            .buttonStyle(GlassButtonStyle(tint: app.accent))
            .disabled(busy || !canSubmit)
            .opacity(canSubmit ? 1 : 0.6)

            if mode == .register {
                Text("Dopo la registrazione l'amministratore riceve un'email con il link di attivazione. Potrai accedere appena il tuo account sarà attivo.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            } else if !auth.hasServer {
                Text("Server account non configurato: è attivo solo l'accesso amministratore.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .liquidGlassCard(radius: 30)
    }

    private var canSubmit: Bool {
        let base = !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        return mode == .login ? base : base && !email.isEmpty && !confirm.isEmpty
    }

    private func submit() {
        guard canSubmit, !busy else { return }
        errorMessage = nil
        successMessage = nil
        if mode == .register {
            guard password == confirm else { errorMessage = "Le due password non coincidono."; return }
            guard password.count >= 6 else { errorMessage = "La password deve avere almeno 6 caratteri."; return }
        }
        focus = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                if mode == .login {
                    try await auth.login(username: username, password: password)
                } else {
                    successMessage = try await auth.register(username: username, email: email, password: password)
                    password = ""
                    confirm = ""
                    mode = .login
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct GlassField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.white.opacity(0.7))
            Group {
                if secure && !reveal {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.5)))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.5)))
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if secure {
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .liquidGlassCapsule()
    }
}

struct ServerSettingsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://xxxx.supabase.co/functions/v1/lumen-auth", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                } header: {
                    Text("Indirizzo del server account")
                } footer: {
                    Text("È l'URL della funzione lumen-auth su Supabase (vedi README). Lascia vuoto per usare solo l'account amministratore locale.")
                }
            }
            .navigationTitle("Server account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        auth.serverURL = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { draft = auth.serverURL }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}
