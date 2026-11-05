import SwiftUI

/// Note di rilascio incluse nell'app (Resources/WhatsNew.json): alla prima apertura dopo un aggiornamento
/// compare il riepilogo "Cosa c'è di nuovo", che resta anche nella sezione Notifiche.
struct ReleaseNote: Codable, Identifiable {
    struct Item: Codable, Hashable {
        var icon: String
        var text: String
    }
    var version: String
    var title: String?
    var items: [Item]
    var id: String { version }
}

@MainActor
enum WhatsNew {
    private static let seenKey = "lumen.whatsnew.seen"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var notes: [ReleaseNote] {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ReleaseNote].self, from: data)) ?? []
    }

    /// Note da mostrare ora (una volta per versione), già registrate tra le notifiche.
    static func pending() -> AppNotification? {
        let version = currentVersion
        guard UserDefaults.standard.string(forKey: seenKey) != version,
              let note = notes.first(where: { $0.version == version }) ?? notes.first else { return nil }
        UserDefaults.standard.set(version, forKey: seenKey)
        let n = AppNotification(
            kind: .update,
            title: "Cosa c'è di nuovo",
            body: note.items.map { "• " + $0.text }.joined(separator: "\n"),
            icon: "sparkles",
            items: note.items.map { AnnouncementItem(icon: $0.icon, text: $0.text) },
            subtitle: "Lumen \(note.version)" + (note.title.map { " · \($0)" } ?? ""))
        NotificationStore.shared.post(n)
        return n
    }
}

struct WhatsNewSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let note: ReleaseNote

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cosa c'è di nuovo").font(.system(size: 30, weight: .heavy))
                        Text("Lumen \(note.version)" + (note.title.map { " · \($0)" } ?? ""))
                            .font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.top, 34)
                    ForEach(note.items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: item.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(app.accent)
                                .frame(width: 42, height: 42)
                                .liquidGlass(in: Circle(), tint: app.accent.opacity(0.3))
                            Text(item.text).font(.body).fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 9)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            Button { dismiss() } label: {
                Text("Continua").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(GlassButtonStyle(tint: app.accent))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Text("Lo ritrovi tra le Notifiche").font(.caption).foregroundStyle(Theme.secondaryText).padding(.bottom, 8)
        }
        .background(AuroraBackground(accent: app.accent).opacity(0.5).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }
}
