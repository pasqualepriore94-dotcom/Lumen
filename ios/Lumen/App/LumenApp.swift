import SwiftUI
import CoreSpotlight
import AVFoundation

@main
struct LumenApp: App {
    @State private var app = AppState()
    @State private var library = Library()
    @State private var auth = AuthStore()
    @State private var updates = UpdateChecker()
    @State private var showSplash = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isRestoring && auth.isLoggedIn {
                    ZStack {
                        AuroraBackground(accent: app.accent)
                        LogoMark(size: 72)
                    }
                } else if auth.isLoggedIn {
                    RootView()
                        .transition(.opacity)
                } else {
                    LoginView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: auth.isLoggedIn)
            .overlay {
                if showSplash {
                    SplashView {
                        withAnimation(.easeOut(duration: 0.3)) { showSplash = false }
                        // Dopo un aggiornamento: "Cosa c'è di nuovo" (una volta per versione).
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(600))
                            if let n = WhatsNew.pending() { app.announcement = n }
                        }
                    }
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .environment(app)
            .environment(library)
            .environment(auth)
            .environment(updates)
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await updates.check() }
                    ImportJob.shared.resumeIfNeeded(app: app)
                    // Nuove uscite ed episodi dei titoli in "La mia lista" (al massimo ogni 3 ore).
                    WatchlistMonitor.shared.sync(list: library.myList, app: app)
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        await WatchlistMonitor.shared.checkIfNeeded()
                    }
                    // Nuovi contenuti nelle playlist da link → sezione Notifiche (dopo l'avvio, per non rallentarlo).
                    if auth.isAdmin {
                        Task {
                            try? await Task.sleep(for: .seconds(6))
                            await PlaylistStore.shared.checkForUpdates(app: app)
                            // Documentari già presenti nelle playlist ma non ancora nel catalogo.
                            while !LinkLibrary.shared.isLoaded { try? await Task.sleep(for: .seconds(1)) }
                            await PlaylistStore.shared.scanDocumentaries(app: app)
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .tint(app.accent)
            .onAppear {
                // Tocca un punto qualsiasi per chiudere la tastiera.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    KeyboardDismisser.shared.install()
                }
            }
            .task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        if app.autoSync { await app.syncRemote() }
                    }
                    group.addTask { @MainActor in
                        await auth.restore()
                    }
                    group.addTask { @MainActor in
                        await updates.check()
                    }
                    group.addTask { @MainActor in
                        // Contenuti collegati letti in anticipo, così schede e "Riproduci" sono subito pronti.
                        await LinkLibrary.shared.loadIfNeeded()
                    }
                }
            }
        }
        // Controllo periodico di "La mia lista" anche ad app chiusa (quando iOS lo consente).
        .backgroundTask(.appRefresh(WatchlistMonitor.refreshTaskId)) {
            await WatchlistMonitor.runBackgroundRefresh()
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(UpdateChecker.self) private var updates
    @Environment(AuthStore.self) private var auth

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            ZStack {
                HomeView()
                    .opacity(app.selectedTab == .home ? 1 : 0)
                    .allowsHitTesting(app.selectedTab == .home)
                ClipsView(isActive: app.selectedTab == .clips)
                    .opacity(app.selectedTab == .clips ? 1 : 0)
                    .allowsHitTesting(app.selectedTab == .clips)
                SearchView()
                    .opacity(app.selectedTab == .search ? 1 : 0)
                    .allowsHitTesting(app.selectedTab == .search)
                ProfileView()
                    .opacity(app.selectedTab == .profile ? 1 : 0)
                    .allowsHitTesting(app.selectedTab == .profile)
            }

            FloatingTabBar(selection: $app.selectedTab)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(item: $app.detailItem) { item in
            DetailView(item: item)
        }
        .sheet(isPresented: $app.showAdmin) {
            AdminView()
        }
        .sheet(isPresented: $app.showCatalog) {
            CatalogBrowserView()
        }
        .overlay(alignment: .top) {
            ImportJobBanner()
                .padding(.top, updates.showBanner ? 84 : 4)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: ImportJob.shared.unseen)
        }
        .overlay(alignment: .top) {
            UpdateBanner()
                .padding(.top, 4)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: updates.showBanner)
        }
        .overlay(alignment: .bottom) {
            AchievementToast().padding(.bottom, Theme.tabBarHeight + 12)
        }
        .fullScreenCover(isPresented: Binding(get: { auth.isLoggedIn && auth.mustChangePassword }, set: { _ in })) {
            ForcePasswordChangeView()
        }
        .onOpenURL { url in
            if let request = ApprovalRequest(url: url) { app.approvalRequest = request }
        }
        // Tocco su un titolo di Lumen nella ricerca Spotlight
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                IntentRouter.shared.send(.open(id))
            }
        }
        // Comandi di Siri e Comandi rapidi
        .onChange(of: IntentRouter.shared.token) { handleIntent() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            IntentRouter.shared.pullInbox()
        }
        .sheet(item: Binding(get: { app.approvalRequest }, set: { app.approvalRequest = $0 })) { ApprovalSheet(request: $0) }
        .sheet(item: Binding(get: { app.announcement }, set: { app.announcement = $0 })) { AnnouncementSheet(notification: $0) }
        .onChange(of: library.activitySignature) { AchievementTracker.shared.check(library) }
        .onChange(of: library.myList.map(\.id)) { WatchlistMonitor.shared.sync(list: library.myList, app: app) }
        .playbackHUD()
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                AchievementTracker.shared.check(library, announce: false)
            }
            KeyboardDismisser.shared.install()
            AppIconMemory.restoreIfNeeded()
            IntentRouter.shared.pullInbox()
            handleIntent()
            Task { @MainActor in
                // Titoli guardabili nella ricerca di iPhone (dopo l'avvio, solo se sono cambiati)
                try? await Task.sleep(for: .seconds(20))
                await LinkLibrary.shared.loadIfNeeded()
                await SpotlightIndexer.indexIfNeeded()
            }
        }
    }
}

extension RootView {
    func handleIntent() {
        guard let action = IntentRouter.shared.pending else { return }
        switch action {
        case .ask:
            app.detailItem = nil
            app.selectedTab = .search   // la richiesta la legge la schermata Cerca
        case .resume:
            IntentRouter.shared.pending = nil
            if let last = library.continueWatching.first {
                app.selectedTab = .home
                app.detailItem = last.item
            } else {
                app.selectedTab = .home
            }
        case .open(let id):
            IntentRouter.shared.pending = nil
            Task { @MainActor in
                await LinkLibrary.shared.loadIfNeeded()
                if let item = LinkLibrary.shared.matchedItems[id] { app.detailItem = item }
            }
        }
    }
}

struct FloatingTabBar: View {
    @Environment(AppState.self) private var app
    @Binding var selection: AppTab
    @Namespace private var selectionNS

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = tab }
                        app.scrollToTop(tab)
                    } label: {
                        VStack(spacing: 3) {
                            icon(for: tab)
                                .frame(height: 22)
                            Text(tab == .profile ? "Il mio \(app.config.appName)" : tab.label)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(selection == tab ? .white : .white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(.white.opacity(0.16))
                                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.6))
                                    .matchedGeometryEffect(id: "pill", in: selectionNS)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .liquidGlassCapsule(interactive: true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func icon(for tab: AppTab) -> some View {
        if tab == .profile {
            ProfileAvatar(size: 22)
        } else {
            Image(systemName: selection == tab ? tab.selectedIcon : tab.icon)
                .font(.system(size: 18, weight: .medium))
        }
    }
}

struct ProfileAvatar: View {
    @Environment(AppState.self) private var app
    @Environment(AuthStore.self) private var auth
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: [app.accent, app.accent.opacity(0.6)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Text(String(auth.user?.username.prefix(1) ?? "?").uppercased())
                    .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 0.6))
    }
}


/// Conferma dell'attivazione (o del rifiuto) di un account, aperta dal link nell'email.
struct ApprovalSheet: View {
    @Environment(AppState.self) private var app
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let request: ApprovalRequest
    @State private var working = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(failed || request.invalid ? .orange : (request.action == "reject" ? .red : app.accent))
                .padding(.top, 28)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if result == nil && !request.invalid {
                Button {
                    confirm()
                } label: {
                    HStack {
                        if working { ProgressView().tint(.white) }
                        Text(request.action == "reject" ? "Rifiuta registrazione" : "Attiva account").bold()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(GlassButtonStyle(tint: request.action == "reject" ? .red : app.accent))
                .foregroundStyle(.white)
                .disabled(working)
                .padding(.horizontal, 24)
            }
            Button(result == nil && !request.invalid ? "Annulla" : "Chiudi") { dismiss() }
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private var who: String { request.username.isEmpty ? "questo utente" : request.username }

    private var icon: String {
        if request.invalid || failed { return "exclamationmark.triangle.fill" }
        if result != nil { return request.action == "reject" ? "person.fill.xmark" : "checkmark.seal.fill" }
        return request.action == "reject" ? "person.fill.xmark" : "person.badge.plus"
    }

    private var title: String {
        if request.invalid { return "Link non valido" }
        if let result { return failed ? "Operazione non riuscita" : result }
        return request.action == "reject" ? "Rifiutare la registrazione?" : "Attivare l'account?"
    }

    private var message: String {
        if request.invalid { return "Questo link è già stato usato oppure non è corretto." }
        if let result, failed { return result + "\nPuoi gestire l'utente anche da Amministrazione → Utenti." }
        if result != nil { return "" }
        let mail = request.email.isEmpty ? "" : " (\(request.email))"
        return request.action == "reject"
            ? "La registrazione di \(who)\(mail) verrà eliminata."
            : "\(who)\(mail) potrà accedere a Lumen."
    }

    private func confirm() {
        working = true
        Task {
            do {
                let name = try await auth.confirmApproval(token: request.token, reject: request.action == "reject")
                result = request.action == "reject" ? "Registrazione di \(name) rifiutata" : "\(name) ora può accedere"
                failed = false
            } catch {
                result = error.localizedDescription
                failed = true
            }
            working = false
        }
    }
}


/// Prima di continuare va cambiata la password predefinita (es. admin/admin) o troppo corta.
struct ForcePasswordChangeView: View {
    @Environment(AppState.self) private var app
    @Environment(AuthStore.self) private var auth
    @State private var old = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password attuale", text: $old)
                    SecureField("Nuova password (almeno 8 caratteri)", text: $new1)
                    SecureField("Ripeti la nuova password", text: $new2)
                } footer: {
                    Text("Per sicurezza la password attuale va sostituita: è quella predefinita o è troppo corta. Usa almeno 8 caratteri, meglio con lettere, numeri e simboli.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack { if working { ProgressView() }; Text("Cambia password").bold() }
                    }
                    .disabled(working || old.isEmpty || new1.count < 8 || new1 != new2)
                    Button("Esci dall'account", role: .destructive) { auth.signOut() }
                }
            }
            .navigationTitle("Cambia password")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            try await auth.changePassword(old: old, new: new1)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
