import Foundation
import UIKit
import UserNotifications
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
    /// Guida TV (XMLTV) indicata nell'intestazione della playlist (url-tvg / x-tvg-url).
    var epgURL: String?

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
    func checkForUpdates(app: AppState, force: Bool = false) async {
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
                let oldList = PlaylistStore.parse(oldText, origin: origin)
                let oldIds = Set(oldList.map(\.id))
                // Anche per nome: se il fornitore cambia gli indirizzi (token), non sono contenuti nuovi.
                let oldNames = Set(oldList.map { $0.title.lowercased() + "|" + ($0.group ?? "") })
                let added = fresh.filter { !oldIds.contains($0.id) && !oldNames.contains($0.title.lowercased() + "|" + ($0.group ?? "")) }
                try? text.data(using: .utf8)?.write(to: PlaylistStore.textFile(id), options: .atomic)
                return (text, added, fresh.count, fresh.filter { !$0.isLive }.count, fresh.filter(\.isLive).count)
            }.value
            guard let diff, let i = playlists.firstIndex(where: { $0.id == id }) else { continue }
            playlists[i].lastChecked = Date()
            playlists[i].entries = diff.2
            playlists[i].vods = diff.3
            playlists[i].lives = diff.4
            if !diff.1.isEmpty { playlists[i].updatedAt = Date() }
            persist()
            guard !diff.1.isEmpty else { continue }
            // Nuovi episodi di serie già importate: subito disponibili (con etichetta Nuovo episodio).
            let auto = LinkLibrary.shared.autoLinkEpisodes(diff.1)
            for (sid, keys) in auto.bySeries {
                let title = LinkLibrary.shared.matchedItems[sid]?.title ?? "Una serie"
                let label = keys.count == 1 ? keys[0].uppercased().replacingOccurrences(of: "E", with: " E") : "\(keys.count) nuovi episodi"
                WatchlistMonitor.shared.notifyIfListed(sid, title: "Nuovo episodio pronto da guardare",
                                                       body: "\(title) · \(label). È già disponibile in Lumen.", icon: "play.tv.fill")
            }
            let added = diff.1.filter { !auto.used.contains($0.id) }
            if !auto.used.isEmpty {
                let n = auto.used.count
                NotificationStore.shared.post(AppNotification(kind: .info, title: "Episodi aggiunti in automatico",
                                                              body: "\(n == 1 ? "1 nuovo episodio" : "\(n) nuovi episodi") di serie già importate da \(playlists[i].name) sono pronti da guardare.",
                                                              icon: "play.tv.fill"))
            }
            guard !added.isEmpty else { continue }
            WatchlistMonitor.shared.playlistAdded(added, playlistName: playlists[i].name)
            // Le novità vengono abbinate al catalogo e aggiunte subito, senza chiedere.
            await autoImport(added, playlistName: playlists[i].name, app: app)
        }
    }

    /// Abbina le nuove voci al catalogo (riusando le ricerche già fatte) e le importa direttamente,
    /// poi mostra la finestra con i contenuti aggiunti (salvata anche tra le notifiche).
    private func autoImport(_ added: [LinkMedia], playlistName: String, app: AppState) async {
        let tmdb = app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }
        let mapper = LinkMapper()
        mapper.cache = ImportJob.shared.mapper.cache
        await mapper.prepare(added, tmdb: tmdb)
        ImportJob.shared.mapper.cache.merge(mapper.cache) { _, new in new }
        LinkLibrary.shared.applyMapping(movies: mapper.movies, series: mapper.series, lives: mapper.lives)

        let movies = mapper.movies.compactMap(\.match)
        let series = mapper.series.compactMap { s in s.match.map { (s, $0) } }
        var seen = Set<String>()
        var rows: [AnnouncementItem] = []
        for m in movies where seen.insert(m.id).inserted {
            rows.append(AnnouncementItem(text: m.title, detail: "Film" + (m.year.map { " · \($0)" } ?? ""), media: m))
        }
        for (proposal, item) in series where seen.insert(item.id).inserted {
            let n = proposal.episodes.count
            rows.append(AnnouncementItem(text: item.title, detail: "Serie TV · " + (n == 1 ? "1 episodio" : "\(n) episodi"), media: item))
        }
        let lives = mapper.lives.count
        let unmatched = mapper.movies.filter { $0.match == nil }.count + mapper.series.filter { $0.match == nil }.count
        if lives > 0 {
            rows.append(AnnouncementItem(icon: "dot.radiowaves.left.and.right", text: lives == 1 ? "1 nuova diretta" : "\(lives) nuove dirette",
                                         detail: "In Categorie → Dirette"))
        }
        if unmatched > 0 {
            rows.append(AnnouncementItem(icon: "questionmark.folder", text: "\(unmatched) voci senza scheda nel catalogo",
                                         detail: "In Amministrazione → Contenuti collegati da link"))
        }
        guard !rows.isEmpty else { return }
        let shown = Array(rows.prefix(40))
        let count = seen.count
        let n = AppNotification(
            kind: .contentAdded,
            title: count > 0 ? (count == 1 ? "1 nuovo titolo aggiunto" : "\(count) nuovi titoli aggiunti") : "Nuovi contenuti aggiunti",
            body: rows.prefix(12).map { "• " + $0.text }.joined(separator: "\n"),
            icon: "sparkles.tv",
            items: shown,
            subtitle: "Da \(playlistName)" + (rows.count > shown.count ? " · altri \(rows.count - shown.count) nel catalogo" : ""))
        NotificationStore.shared.post(n)
        if UIApplication.shared.applicationState == .active {
            if app.announcement == nil { app.announcement = n }
        } else {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = rows.prefix(4).map(\.text).joined(separator: ", ") + (rows.count > 4 ? "…" : "")
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
        if let epg = Self.epgURL(in: text) { p.epgURL = epg; EPGStore.shared.suggest(epg) }
        try? text.data(using: .utf8)?.write(to: Self.textFile(p.id))
        if let i = playlists.firstIndex(where: { $0.id == p.id }) { playlists[i] = p } else { playlists.insert(p, at: 0) }
        persist()
        return (p, media)
    }

    /// Indirizzo della guida TV nell'intestazione #EXTM3U (può contenerne più d'uno separati da virgola).
    nonisolated static func epgURL(in text: String) -> String? {
        guard let header = text.prefix(4000).split(whereSeparator: \.isNewline).first(where: { $0.contains("#EXTM3U") }) else { return nil }
        for key in ["url-tvg=\"", "x-tvg-url=\"", "tvg-url=\""] {
            if let r = header.range(of: key), let end = header[r.upperBound...].firstIndex(of: "\"") {
                let v = header[r.upperBound..<end].split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                if let v, v.lowercased().hasPrefix("http") { return v }
            }
        }
        return nil
    }

    /// Guida TV indicata in una delle playlist salvate (anche quelle caricate prima del supporto EPG).
    func detectEPGURL() -> String? {
        for p in playlists {
            if let e = p.epgURL { return e }
            if let h = try? FileHandle(forReadingFrom: Self.textFile(p.id)) {
                let d = h.readData(ofLength: 4000)
                try? h.close()
                if let t = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1), let e = Self.epgURL(in: t) { return e }
            }
        }
        return nil
    }

    /// Come `media(of:)` ma fuori dal thread principale (playlist anche da centinaia di migliaia di voci).
    func mediaAsync(of p: SavedPlaylist) async -> [LinkMedia] {
        let file = Self.textFile(p.id), origin = p.origin
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file), let text = PlaylistStore.decode(data) else { return [] }
            return PlaylistStore.parse(text, origin: origin)
        }.value
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
