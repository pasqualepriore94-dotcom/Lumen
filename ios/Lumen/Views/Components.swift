import SwiftUI
import UIKit

// MARK: - Colori

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

enum Theme {
    static let background = Color.black
    static let surface = Color(white: 0.11)
    static let surfaceHigh = Color(white: 0.18)
    static let secondaryText = Color.white.opacity(0.65)
    static let tabBarHeight: CGFloat = 96
}

// MARK: - Immagini (remote o incluse nell'app con lo schema bundle://nome)

struct RemoteImage: View {
    let url: URL?

    var body: some View {
        if let url, url.scheme == "bundle", let image = UIImage(named: url.host ?? url.lastPathComponent) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let url, let offline = ImageStore.cachedImage(for: url) {
            // Immagine salvata per l'uso offline
            Image(uiImage: offline).resizable().scaledToFill()
        } else if let url {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: placeholder
                default: placeholder.overlay(ProgressView().tint(.white.opacity(0.3)))
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        LinearGradient(colors: [Theme.surfaceHigh, Theme.surface], startPoint: .top, endPoint: .bottom)
    }
}

/// Rettangolo a dimensione fissa con immagine ritagliata.
struct ImageTile: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .overlay(RemoteImage(url: url))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - Logo

struct LogoMark: View {
    @Environment(AppState.self) private var app
    var size: CGFloat = 26

    var body: some View {
        let initial = String(app.config.appName.prefix(1)).uppercased()
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [app.accent, app.accent.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initial)
                .font(.system(size: size * 0.62, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Intestazione delle schede

struct TabHeader: View {
    @Environment(AppState.self) private var app
    let title: String
    var showsLogo = true
    @State private var showDownloads = false
    @State private var showNotifications = false

    var body: some View {
        HStack(spacing: 10) {
            if showsLogo { LogoMark() }
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Spacer()
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button { showDownloads = true } label: {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                    Button { showNotifications = true } label: {
                        Image(systemName: "bell").font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .overlay(alignment: .topTrailing) {
                                Circle().fill(app.accent).frame(width: 9, height: 9).offset(x: -8, y: 8)
                            }
                    }
                    .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .sheet(isPresented: $showDownloads) { DownloadsPlaceholder() }
        .sheet(isPresented: $showNotifications) { NotificationsView() }
    }
}

struct DownloadsPlaceholder: View {
    var body: some View { DownloadsView() }
}

struct NotificationsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MediaItem] = []

    var body: some View {
        NavigationStack {
            List(items) { item in
                Button {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        app.detailItem = item
                    }
                } label: {
                    HStack(spacing: 12) {
                        ImageTile(url: item.bestWideImage, width: 110, height: 62)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.badge ?? "Novità").font(.caption.bold()).foregroundStyle(app.accent)
                            Text(item.title).font(.subheadline.bold()).foregroundStyle(.white)
                        }
                    }
                }
                .listRowBackground(Color.black)
            }
            .listStyle(.plain)
            .overlay { if items.isEmpty { Text("Nessuna novità").foregroundStyle(.secondary) } }
            .navigationTitle("Notifiche")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .task {
            let feed = try? await app.provider.home()
            items = (feed?.allItems ?? []).filter { $0.badge != nil }
        }
    }
}

// MARK: - Badge

struct TopTenBadge: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: -3) {
            Text("TOP").font(.system(size: 7, weight: .heavy))
            Text("10").font(.system(size: 12, weight: .black))
        }
        .foregroundStyle(.white)
        .frame(width: 22, height: 26)
        .background(app.accent)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 3, topTrailingRadius: 6))
    }
}

struct PillBadge: View {
    @Environment(AppState.self) private var app
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(app.accent, in: RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Locandina

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 112
    var aspect: CGFloat = 2.0 / 3.0

    var body: some View {
        ZStack(alignment: .bottom) {
            ImageTile(url: item.bestPosterImage, width: width, height: width / aspect, corner: 6)
            if let badge = item.badge {
                PillBadge(text: badge).padding(.bottom, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.rank != nil { TopTenBadge() }
        }
        .frame(width: width, height: width / aspect)
        .contentShape(Rectangle())
        .accessibilityLabel(item.title)
    }
}

// MARK: - Sezione orizzontale

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct PrimaryButton: View {
    @Environment(AppState.self) private var app
    let title: String
    var icon: String = "play.fill"
    let action: () -> Void
    private var accent: Color { app.accent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(.white)
        }
        .buttonStyle(GlassButtonStyle(tint: accent))
    }
}

struct SecondaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(.white)
        }
        .buttonStyle(GlassButtonStyle())
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.secondaryText)
            Button(action: retry) {
                Text("Riprova").font(.subheadline.weight(.semibold)).padding(.horizontal, 22).padding(.vertical, 10)
            }
            .buttonStyle(GlassButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Indicatore mostrato mentre si prepara la riproduzione.
struct PlaybackHUD: ViewModifier {
    @Environment(AppState.self) private var app
    func body(content: Content) -> some View {
        content.overlay {
            if app.isPreparingPlayback {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().controlSize(.large).tint(.white)
                        .padding(28)
                        .liquidGlassCard(radius: 24)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.isPreparingPlayback)
    }
}

extension View {
    func playbackHUD() -> some View { modifier(PlaybackHUD()) }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
