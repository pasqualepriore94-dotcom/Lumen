import SwiftUI
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
                    SplashView { withAnimation(.easeOut(duration: 0.3)) { showSplash = false } }
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .environment(app)
            .environment(library)
            .environment(auth)
            .environment(updates)
            .onChange(of: scenePhase) {
                if scenePhase == .active { Task { await updates.check() } }
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
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(UpdateChecker.self) private var updates

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
            UpdateBanner()
                .padding(.top, 4)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: updates.showBanner)
        }
        .playbackHUD()
        .onAppear { KeyboardDismisser.shared.install() }
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
