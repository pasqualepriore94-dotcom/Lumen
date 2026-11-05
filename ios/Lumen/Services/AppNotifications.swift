import SwiftUI
import Observation

/// Notifica mostrata nella sezione Notifiche dell'app (campanella in alto).
struct AppNotification: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case newContent, analysisDone, trophy, update, info, contentAdded }

    var id = UUID()
    var kind: Kind
    var title: String
    var body: String
    var icon: String
    var date = Date()
    var read = false
    /// Playlist con contenuti nuovi da analizzare (per `newContent`).
    var playlistId: UUID?
    /// Righe della finestra a comparsa (novità, contenuti aggiunti…), per riaprirla uguale.
    var items: [AnnouncementItem]?
    var subtitle: String?
}

/// Una riga della finestra a comparsa: icona e testo, oppure un titolo del catalogo con locandina.
struct AnnouncementItem: Codable, Hashable {
    var icon: String?
    var text: String
    var detail: String?
    var media: MediaItem?
}

@MainActor
@Observable
final class NotificationStore {
    static let shared = NotificationStore()

    private(set) var items: [AppNotification] = []
    var unread: Int { items.filter { !$0.read }.count }

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notifications.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let list = try? JSONDecoder().decode([AppNotification].self, from: data) {
            items = list
        }
    }

    func post(_ n: AppNotification) {
        // Una sola notifica non letta per playlist con novità: viene aggiornata invece di duplicarla.
        if n.kind == .newContent, let pid = n.playlistId {
            items.removeAll { $0.kind == .newContent && $0.playlistId == pid && !$0.read }
        }
        items.insert(n, at: 0)
        if items.count > 100 { items = Array(items.prefix(100)) }
        save()
    }

    func markAllRead() {
        for i in items.indices { items[i].read = true }
        save()
    }

    func markRead(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].read = true
        save()
    }

    func remove(_ ids: [UUID]) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func removeAll() { items = []; save() }

    private func save() {
        let list = items
        let url = Self.file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// Sezione Notifiche: avvisi dell'app (nuovi contenuti nelle playlist, analisi completate, trofei, aggiornamenti)
/// e le novità del catalogo.
struct NotificationsView: View {
    @Environment(AppState.self) private var app
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var store = NotificationStore.shared
    @State private var items: [MediaItem] = []

    var body: some View {
        NavigationStack {
            List {
                if !store.items.isEmpty {
                    Section {
                        ForEach(store.items) { n in row(n) }
                            .onDelete { idx in store.remove(idx.map { store.items[$0].id }) }
                    } header: {
                        Text("Per te")
                    }
                }
                if !items.isEmpty {
                    Section("Novità nel catalogo") {
                        ForEach(items) { item in
                            Button {
                                open { app.detailItem = item }
                            } label: {
                                HStack(spacing: 12) {
                                    ImageTile(url: item.bestWideImage, width: 110, height: 62)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.badge ?? "Novità").font(.caption.bold()).foregroundStyle(app.accent)
                                        Text(item.title).font(.subheadline.bold()).foregroundStyle(.white)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.items.isEmpty && items.isEmpty {
                    ContentUnavailableView("Nessuna notifica", systemImage: "bell.slash")
                }
            }
            .navigationTitle("Notifiche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.unread > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Segna come lette") { store.markAllRead() }.font(.footnote)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .task {
            let feed = try? await app.provider.home()
            items = (feed?.allItems ?? []).filter { $0.badge != nil }
        }
    }

    private func row(_ n: AppNotification) -> some View {
        Button { tap(n) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: n.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(app.accent)
                    .frame(width: 38, height: 38)
                    .liquidGlass(in: Circle(), tint: n.read ? nil : app.accent.opacity(0.3))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(n.title).font(.subheadline.weight(n.read ? .regular : .bold)).foregroundStyle(.white)
                        Spacer()
                        Text(n.date.formatted(.relative(presentation: .named).locale(Locale(identifier: "it_IT"))))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(n.body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if n.kind == .newContent, auth.isAdmin, n.playlistId != nil {
                        Text("Tocca per analizzare e scegliere cosa importare")
                            .font(.caption2.weight(.semibold)).foregroundStyle(app.accent)
                    }
                }
                if !n.read {
                    Circle().fill(app.accent).frame(width: 8, height: 8).padding(.top, 6)
                }
            }
        }
    }

    /// Riapre la notifica nella stessa finestra a comparsa di quando è arrivata.
    private func tap(_ n: AppNotification) {
        store.markRead(n.id)
        open { app.announcement = n }
    }

    private func open(_ action: @escaping () -> Void) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }
}


/// Azioni disponibili dalla finestra a comparsa di una notifica.
@MainActor
enum NotificationActions {
    static func actionTitle(_ n: AppNotification, isAdmin: Bool) -> String? {
        guard isAdmin else { return nil }
        switch n.kind {
        case .newContent where n.playlistId != nil: return "Analizza e importa le novità"
        case .analysisDone: return "Scegli cosa importare"
        default: return nil
        }
    }

    static func perform(_ n: AppNotification, app: AppState) {
        switch n.kind {
        case .newContent:
            guard let pid = n.playlistId else { return }
            let pending = PlaylistStore.shared.pendingNew(pid)
            let name = PlaylistStore.shared.playlists.first { $0.id == pid }?.name ?? "Playlist"
            if !pending.isEmpty {
                ImportJob.shared.startMedia(pending, name: "\(name) · novità", app: app)
                PlaylistStore.shared.clearPending(pid)
            }
            openImport(app)
        case .analysisDone:
            openImport(app)
        default:
            break
        }
    }

    private static func openImport(_ app: AppState) {
        app.showAdmin = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            ImportJob.shared.openRequested = true
        }
    }
}

/// Finestra a comparsa delle notifiche (stesso stile di "Cosa c'è di nuovo"): si apre quando arrivano
/// novità dell'app o nuovi contenuti, e di nuovo toccando la notifica nella sezione Notifiche.
struct AnnouncementSheet: View {
    @Environment(AppState.self) private var app
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let notification: AppNotification

    private var rows: [AnnouncementItem] {
        if let items = notification.items, !items.isEmpty { return items }
        // Notifiche senza righe: il testo, una riga per paragrafo/punto
        let lines = notification.body.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "• ", with: "")
        }.filter { !$0.isEmpty }
        return lines.map { AnnouncementItem(icon: notification.icon, text: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: notification.icon)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(app.accent)
                            .frame(width: 56, height: 56)
                            .liquidGlass(in: Circle(), tint: app.accent.opacity(0.35))
                            .padding(.bottom, 6)
                        Text(notification.title).font(.system(size: 28, weight: .heavy))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(notification.subtitle ?? notification.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.top, 30)
                    ForEach(rows, id: \.self) { row($0) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            if let action = NotificationActions.actionTitle(notification, isAdmin: auth.isAdmin) {
                Button {
                    let n = notification
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        NotificationActions.perform(n, app: app)
                    }
                } label: {
                    Text(action).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(GlassButtonStyle(tint: app.accent))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.top, 14)
            }
            Button { dismiss() } label: {
                Text("Continua").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(GlassButtonStyle(tint: NotificationActions.actionTitle(notification, isAdmin: auth.isAdmin) == nil ? app.accent : nil))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Text("Lo ritrovi tra le Notifiche").font(.caption).foregroundStyle(Theme.secondaryText).padding(.bottom, 8)
        }
        .background(AuroraBackground(accent: app.accent).opacity(0.5).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(_ item: AnnouncementItem) -> some View {
        if let media = item.media {
            Button {
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    app.detailItem = media
                }
            } label: {
                HStack(spacing: 14) {
                    ImageTile(url: media.bestPosterImage, width: 54, height: 80, corner: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.text).font(.body.weight(.semibold)).lineLimit(2)
                        if let d = item.detail { Text(d).font(.caption).foregroundStyle(Theme.secondaryText) }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: item.icon ?? notification.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(app.accent)
                    .frame(width: 42, height: 42)
                    .liquidGlass(in: Circle(), tint: app.accent.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(.body).fixedSize(horizontal: false, vertical: true)
                    if let d = item.detail { Text(d).font(.caption).foregroundStyle(Theme.secondaryText) }
                }
                .padding(.top, 9)
            }
        }
    }
}
