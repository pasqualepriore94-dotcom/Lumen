import SwiftUI
import Observation

/// Notifica mostrata nella sezione Notifiche dell'app (campanella in alto).
struct AppNotification: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case newContent, analysisDone, trophy, update, info }

    var id = UUID()
    var kind: Kind
    var title: String
    var body: String
    var icon: String
    var date = Date()
    var read = false
    /// Playlist con contenuti nuovi da analizzare (per `newContent`).
    var playlistId: UUID?
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

    private func tap(_ n: AppNotification) {
        store.markRead(n.id)
        switch n.kind {
        case .newContent:
            guard auth.isAdmin, let pid = n.playlistId else { return }
            let pending = PlaylistStore.shared.pendingNew(pid)
            let name = PlaylistStore.shared.playlists.first { $0.id == pid }?.name ?? "Playlist"
            open {
                if !pending.isEmpty {
                    ImportJob.shared.startMedia(pending, name: "\(name) · novità", app: app)
                    PlaylistStore.shared.clearPending(pid)
                }
                app.showAdmin = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    ImportJob.shared.openRequested = true
                }
            }
        case .analysisDone:
            guard auth.isAdmin else { return }
            open {
                app.showAdmin = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    ImportJob.shared.openRequested = true
                }
            }
        case .trophy, .update, .info:
            break
        }
    }

    private func open(_ action: @escaping () -> Void) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }
}
