import SwiftUI
import AVFoundation

@main
struct LumenApp: App {
    @State private var app = AppState()
    @State private var library = Library()

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(library)
                .preferredColorScheme(.dark)
                .tint(app.accent)
                .task {
                    if app.autoSync { await app.syncRemote() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

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
        .playbackHUD()
    }
}

struct FloatingTabBar: View {
    @Environment(AppState.self) private var app
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        icon(for: tab)
                            .frame(height: 22)
                        Text(tab == .profile ? "Il mio \(app.config.appName)" : tab.label)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(selection == tab ? .white : .white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if selection == tab {
                            Capsule().fill(.white.opacity(0.14))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .padding(.horizontal, 22)
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
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(app.accent)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: size * 0.62, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}
