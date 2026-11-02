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

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var indexFile: URL { folder.appendingPathComponent("index.json") }
    private static func textFile(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).m3u") }

    /// Decodifica il contenuto di un file M3U (UTF-8, con ripiego su Latin-1).
    static func decode(_ data: Data) -> String? {
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

    static func parse(_ text: String, origin: String) -> [LinkMedia] {
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
