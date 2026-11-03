import Foundation
import Observation

/// Playlist M3U caricata dall'amministratore (da file o da link), salvata sul dispositivo.
struct SavedPlaylist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// "File" oppure l'indirizzo da cui è stata scaricata
    var origin: String
    var addedAt = Date()
    var updatedAt = Date()
    var entries = 0
    var vods = 0
    var lives = 0
    /// Ultimo controllo automatico dei nuovi contenuti (solo playlist da link).
    var lastChecked: Date?

    var isFromFile: Bool { !origin.lowercased().hasPrefix("http") }
}

/// Archivio delle playlist M3U: conserva il testo originale per poterle rianalizzare,
/// sfogliare, aggiornare o eliminare (anche insieme ai contenuti importati).
@MainActor
@Observable
final class PlaylistStore {
    static let shared = PlaylistStore()

    private(set) var playlists: [SavedPlaylist] = []

    private init() {
        if let data = try? Data(contentsOf: Self.indexFile),
           let list = try? JSONDecoder().decode([SavedPlaylist].self, from: data) {
            playlists = list
        }
    }

    nonisolated private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated private static var indexFile: URL { folder.appendingPathComponent("index.json") }
    nonisolated private static func textFile(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).m3u") }
    nonisolated private static func pendingFile(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString)-new.json") }

    /// Voci comparse nell'ultimo aggiornamento automatico e non ancora analizzate.
    func pendingNew(_ id: UUID) -> [LinkMedia] {
        guard let data = try? Data(contentsOf: Self.pendingFile(id)) else { return [] }
        return (try? JSONDecoder().decode([LinkMedia].self, from: data)) ?? []
    }

    @ObservationIgnored private var checking = false

    /// All'avvio: riscarica le playlist da link (al massimo ogni 6 ore), trova le voci nuove
    /// e lo segnala nella sezione Notifiche dell'app.
    func checkForUpdates(force: Bool = false) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        for p in playlists where !p.isFromFile {
            if !force, let last = p.lastChecked, Date().timeIntervalSince(last) < 6 * 3600 { continue }
            guard let url = URL(string: p.origin) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 180)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Lumen", forHTTPHeaderField: "User-Agent")
            guard let pair = try? await URLSession.shared.download(for: request),
                  let http = pair.1 as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { continue }
            let tmp = pair.0, id = p.id, origin = p.origin
            // Confronto fuori dal thread principale (playlist anche da decine di migliaia di voci).
            let diff: (String, [LinkMedia], Int, Int, Int)? = await Task.detached(priority: .utility) {
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let data = try? Data(contentsOf: tmp), let text = PlaylistStore.decode(data),
                      text.contains("#EXTINF") else { return nil }
                let fresh = PlaylistStore.parse(text, origin: origin)
                let oldText = (try? Data(contentsOf: PlaylistStore.textFile(id))).flatMap { PlaylistStore.decode($0) } ?? ""
                let old = Set(PlaylistStore.parse(oldText, origin: origin).map(\.id))
                let added = fresh.filter { !old.contains($0.id) }
                try? text.data(using: .utf8)?.write(to: PlaylistStore.textFile(id), options: .atomic)
                if !added.isEmpty {
                    // Somma alle novità già in attesa
                    var pending = (try? Data(contentsOf: PlaylistStore.pendingFile(id)))
                        .flatMap { try? JSONDecoder().decode([LinkMedia].self, from: $0) } ?? []
                    let known = Set(pending.map(\.id))
                    pending += added.filter { !known.contains($0.id) }
                    if let out = try? JSONEncoder().encode(pending) { try? out.write(to: PlaylistStore.pendingFile(id), options: .atomic) }
                }
                return (text, added, fresh.count, fresh.filter { !$0.isLive }.count, fresh.filter(\.isLive).count)
            }.value
            guard let diff, let i = playlists.firstIndex(where: { $0.id == id }) else { continue }
            playlists[i].lastChecked = Date()
            playlists[i].entries = diff.2
            playlists[i].vods = diff.3
            playlists[i].lives = diff.4
            if !diff.1.isEmpty { playlists[i].updatedAt = Date() }
            persist()
            let added = diff.1
            guard !added.isEmpty else { continue }
            WatchlistMonitor.shared.playlistAdded(added, playlistName: playlists[i].name)
            let vods = added.filter { !$0.isLive }
            let episodes = vods.filter { ParsedTitle.parse($0.title).isEpisode }.count
            let movies = vods.count - episodes
            let lives = added.count - vods.count
            var parts: [String] = []
            if movies > 0 { parts.append(movies == 1 ? "1 film" : "\(movies) film") }
            if episodes > 0 { parts.append(episodes == 1 ? "1 episodio" : "\(episodes) episodi") }
            if lives > 0 { parts.append(lives == 1 ? "1 diretta" : "\(lives) dirette") }
            NotificationStore.shared.post(AppNotification(
                kind: .newContent,
                title: "Nuovi contenuti in \(playlists[i].name)",
                body: parts.joined(separator: ", ") + ".",
                icon: "sparkles.tv",
                playlistId: id))
        }
    }

    /// Le novità sono state passate all'analisi: non sono più in attesa.
    func clearPending(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.pendingFile(id))
    }

    /// Decodifica il contenuto di un file M3U (UTF-8, con ripiego su Latin-1).
    nonisolated static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Salva (o aggiorna, se esiste già una playlist con la stessa origine e nome) e restituisce le voci trovate.
    @discardableResult
    func save(name: String, origin: String, text: String) -> (SavedPlaylist, [LinkMedia]) {
        let media = Self.parse(text, origin: origin)
        var p = playlists.first { $0.origin == origin && $0.name == name } ?? SavedPlaylist(name: name, origin: origin)
        p.updatedAt = Date()
        p.entries = media.count
        p.vods = media.filter { !$0.isLive }.count
        p.lives = media.filter(\.isLive).count
        try? text.data(using: .utf8)?.write(to: Self.textFile(p.id))
        if let i = playlists.firstIndex(where: { $0.id == p.id }) { playlists[i] = p } else { playlists.insert(p, at: 0) }
        persist()
        return (p, media)
    }

    func media(of p: SavedPlaylist) -> [LinkMedia] {
        guard let data = try? Data(contentsOf: Self.textFile(p.id)), let text = Self.decode(data) else { return [] }
        return Self.parse(text, origin: p.origin)
    }

    func rename(_ p: SavedPlaylist, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = playlists.firstIndex(where: { $0.id == p.id }) else { return }
        playlists[i].name = n
        persist()
    }

    /// Elimina la playlist; se `withContent` rimuove anche film, episodi e dirette importati da essa.
    func delete(_ p: SavedPlaylist, withContent: Bool, library: LinkLibrary = .shared) {
        if withContent { library.removeLinks(Set(media(of: p).map(\.id))) }
        try? FileManager.default.removeItem(at: Self.textFile(p.id))
        try? FileManager.default.removeItem(at: Self.pendingFile(p.id))
        playlists.removeAll { $0.id == p.id }
        persist()
    }

    /// Riscarica una playlist presa da link.
    func refresh(_ p: SavedPlaylist) async -> (SavedPlaylist, [LinkMedia])? {
        guard !p.isFromFile, let url = URL(string: p.origin) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Lumen", forHTTPHeaderField: "User-Agent")
        guard let pair = try? await URLSession.shared.data(for: request),
              let text = Self.decode(pair.0), text.contains("#EXTINF") || text.hasPrefix("#EXTM3U") else { return nil }
        return save(name: p.name, origin: p.origin, text: text)
    }

    nonisolated static func parse(_ text: String, origin: String) -> [LinkMedia] {
        let base = URL(string: origin).flatMap { $0.host != nil ? $0 : nil } ?? URL(string: "https://localhost/")!
        if case .media(let list) = LinkResolver.parsePlaylist(text, base: base) {
            return list.map { var m = $0; m.source = origin.hasPrefix("http") ? "Playlist" : "File M3U"; return m }
        }
        return []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: Self.indexFile) }
    }
}
