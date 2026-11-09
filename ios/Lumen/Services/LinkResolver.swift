import Foundation
import Observation
import CryptoKit

/// Contenuto video trovato a partire da un link.
struct LinkMedia: Codable, Identifiable, Hashable {
    var id: String { url.absoluteString }
    var title: String
    var url: URL
    var poster: URL?
    var isLive: Bool = false
    var source: String
    /// Categoria della playlist (group-title), es. "Film" o "Serie TV".
    var group: String? = nil
    /// Identificativo del canale per la guida TV (tvg-id).
    var tvgId: String? = nil

    var asItem: MediaItem {
        MediaItem(id: "link-" + SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined(),
                  title: title, kind: .movie,
                  poster: poster, backdrop: poster, overview: "Aggiunto da link · \(url.host ?? "")")
    }
}

enum LinkResult {
    case media([LinkMedia])
    case provider(baseURL: String, titles: Int)
    case nothing(String)
}

/// Analizza un link e trova i video riproducibili. Funziona con:
/// - link diretti a video (MP4, MOV, M4V) e flussi HLS (.m3u8)
/// - playlist M3U con più voci
/// - API nel formato Lumen (docs/API.md), proposte come nuova sorgente
/// - pagine web che pubblicano il video in modo aperto (og:video, tag <video>/<source>, schema.org VideoObject)
/// Non aggira protezioni né estrae flussi da player chiusi di siti di streaming.
enum LinkResolver {
    private static let videoExtensions = ["mp4", "m4v", "mov"]
    private static let hlsExtensions = ["m3u8"]
    private static let playlistExtensions = ["m3u"]

    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    static func resolve(_ input: String) async -> LinkResult {
        guard let url = normalize(input) else { return .nothing("Il link non è valido.") }
        let ext = url.pathExtension.lowercased()

        if videoExtensions.contains(ext) {
            return .media([LinkMedia(title: prettyTitle(url), url: url, source: "Video diretto")])
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Lumen", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            guard let http, (200..<400).contains(http.statusCode) else {
                return .nothing("Il server ha risposto con errore \(http?.statusCode ?? 0).")
            }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let finalURL = http.url ?? url

            if type.hasPrefix("video/") {
                return .media([LinkMedia(title: prettyTitle(finalURL), url: finalURL, source: "Video diretto")])
            }
            let text = String(decoding: data.prefix(3_000_000), as: UTF8.self)

            if hlsExtensions.contains(ext) || playlistExtensions.contains(ext) || type.contains("mpegurl") || text.hasPrefix("#EXTM3U") {
                return parsePlaylist(text, base: finalURL)
            }
            if type.contains("json") || text.first == "{" || text.first == "[" {
                if let result = await detectProvider(data: data, url: finalURL) { return result }
            }
            if type.contains("html") || text.lowercased().contains("<html") {
                let found = parseHTML(text, base: finalURL)
                if !found.isEmpty { return .media(found) }
                return .nothing("Nella pagina non c'è un video pubblicato in modo aperto. Prova con il link diretto al file video o alla playlist.")
            }
            return .nothing("Il link non contiene un formato riconosciuto (video MP4/MOV, HLS, playlist M3U o API Lumen).")
        } catch {
            return .nothing("Impossibile aprire il link: \(error.localizedDescription)")
        }
    }

    // MARK: Playlist

    static func parsePlaylist(_ text: String, base: URL) -> LinkResult {
        // Flusso HLS singolo (varianti o segmenti) → si riproduce così com'è.
        if text.contains("#EXT-X-STREAM-INF") || text.contains("#EXT-X-TARGETDURATION") {
            return .media([LinkMedia(title: prettyTitle(base), url: base, source: "Flusso HLS")])
        }
        // Playlist M3U con più voci
        var items: [LinkMedia] = []
        var pendingTitle: String?
        var pendingLogo: URL?
        var pendingGroup: String?
        var pendingDuration: Int?
        var pendingTvg: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                // "#EXTINF:-1 ..." = diretta, "#EXTINF:5400 ..." = durata in secondi (on demand)
                let head = line.dropFirst("#EXTINF:".count).prefix { $0 == "-" || $0.isNumber }
                pendingDuration = Int(head)
                pendingTitle = line.components(separatedBy: ",").dropFirst().joined(separator: ",")
                    .trimmingCharacters(in: .whitespaces)
                if let r = line.range(of: "tvg-logo=\""), let end = line[r.upperBound...].firstIndex(of: "\"") {
                    pendingLogo = URL(string: String(line[r.upperBound..<end]))
                }
                if let r = line.range(of: "group-title=\""), let end = line[r.upperBound...].firstIndex(of: "\"") {
                    pendingGroup = String(line[r.upperBound..<end])
                }
                if let r = line.range(of: "tvg-id=\""), let end = line[r.upperBound...].firstIndex(of: "\"") {
                    let v = String(line[r.upperBound..<end])
                    pendingTvg = v.isEmpty ? nil : v
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let u = URL(string: line, relativeTo: base)?.absoluteURL {
                let title = (pendingTitle?.isEmpty == false ? pendingTitle! : prettyTitle(u))
                let isVOD = classifyVOD(url: u, title: title, group: pendingGroup, duration: pendingDuration)
                items.append(LinkMedia(title: title, url: u, poster: pendingLogo,
                                       isLive: !isVOD, source: "Playlist", group: pendingGroup, tvgId: isVOD ? nil : pendingTvg))
                pendingTvg = nil
                pendingTitle = nil
                pendingLogo = nil
                pendingGroup = nil
                pendingDuration = nil
            }
        }
        return items.isEmpty ? .nothing("La playlist è vuota.") : .media(items)
    }

    /// Riconosce se una voce è on demand (film/episodio) o una diretta, combinando più indizi.
    static func classifyVOD(url: URL, title: String, group: String?, duration: Int?) -> Bool {
        let path = url.path.lowercased()
        let ext = url.pathExtension.lowercased()
        let g = (group ?? "").lowercased()
        var score = 0
        // percorso e formato del file
        if ["mp4", "mkv", "m4v", "mov", "avi", "webm"].contains(ext) { score += 3 }
        if path.contains("/movie/") || path.contains("/movies/") || path.contains("/series/") || path.contains("/vod/") { score += 3 }
        if path.contains("/live/") || ext == "ts" { score -= 3 }
        // durata dichiarata nella playlist
        if let duration { score += duration > 0 ? 2 : -1 }
        // categoria
        let vodWords = ["film", "movie", "cinema", "serie", "series", "vod", "stagione", "season", "anime", "documentar"]
        let liveWords = ["live", "diretta", "tv", "canali", "channel", "sport", "news", "radio", "24/7", "rai", "mediaset", "sky"]
        if vodWords.contains(where: { g.contains($0) }) { score += 2 }
        if liveWords.contains(where: { g.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) { score -= 2 }
        // nome: episodio (S01E02) o anno tra parentesi fanno pensare a un contenuto on demand
        let parsed = ParsedTitle.parse(title)
        if parsed.isEpisode { score += 3 }
        if parsed.year != nil { score += 1 }
        let upper = title.uppercased()
        if upper.contains(" HD") && !parsed.isEpisode && parsed.year == nil && score <= 0 { score -= 1 }
        return score > 0
    }

    // MARK: API Lumen

    private static func detectProvider(data: Data, url: URL) async -> LinkResult? {
        if let feed = try? JSONDecoder().decode(HomeFeed.self, from: data), !feed.sections.isEmpty {
            var base = url.absoluteString
            if base.hasSuffix("/home") { base.removeLast(5) }
            return .provider(baseURL: base, titles: feed.allItems.count)
        }
        // Forse è l'indirizzo base: prova /home
        let home = url.appendingPathComponent("home")
        if let (d, r) = try? await URLSession.shared.data(from: home),
           (r as? HTTPURLResponse)?.statusCode == 200,
           let feed = try? JSONDecoder().decode(HomeFeed.self, from: d), !feed.sections.isEmpty {
            return .provider(baseURL: url.absoluteString, titles: feed.allItems.count)
        }
        return nil
    }

    // MARK: Pagine web (solo metadati aperti)

    static func parseHTML(_ html: String, base: URL) -> [LinkMedia] {
        let title = meta(html, "og:title") ?? tagContent(html, "title") ?? prettyTitle(base)
        let image = (meta(html, "og:image") ?? meta(html, "twitter:image")).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        var urls: [String] = []
        for key in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"] {
            if let v = meta(html, key) { urls.append(v) }
        }
        urls += attributeValues(html, tag: "video", attribute: "src")
        urls += attributeValues(html, tag: "source", attribute: "src")
        urls += jsonLDContentURLs(html)

        var seen = Set<String>()
        return urls.compactMap { raw -> LinkMedia? in
            let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&")
            guard let u = URL(string: cleaned, relativeTo: base)?.absoluteURL else { return nil }
            let e = u.pathExtension.lowercased()
            guard videoExtensions.contains(e) || hlsExtensions.contains(e) || u.absoluteString.contains(".m3u8"),
                  !seen.contains(u.absoluteString) else { return nil }
            seen.insert(u.absoluteString)
            return LinkMedia(title: title, url: u, poster: image, source: base.host ?? "Pagina web")
        }
    }

    private static func meta(_ html: String, _ property: String) -> String? {
        let pattern = "<meta[^>]+(?:property|name)=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*content=[\"']([^\"']+)[\"']"
            + "|<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"']"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
        for i in 1...2 {
            if let r = Range(m.range(at: i), in: html) { return String(html[r]) }
        }
        return nil
    }

    private static func tagContent(_ html: String, _ tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)[^>]*>([^<]+)</\(tag)>", options: [.caseInsensitive]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attributeValues(_ html: String, tag: String, attribute: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)[^>]+\(attribute)=[\"']([^\"']+)[\"']", options: [.caseInsensitive])
        else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private static func jsonLDContentURLs(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\"contentUrl\"\\s*:\\s*\"([^\"]+)\"", options: [])
        else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]).replacingOccurrences(of: "\\/", with: "/") }
        }
    }

    static func prettyTitle(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return name.isEmpty || name == "/" ? (url.host ?? "Video") : name.capitalized
    }
}

/// Titolo e numerazione ricavati dal nome di un contenuto della playlist.
struct ParsedTitle: Hashable, Codable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    var isEpisode: Bool { season != nil && episode != nil }

    static func parse(_ raw: String) -> ParsedTitle {
        var t = raw
        // prefissi tipo "IT: ", "|IT| ", "[ITA] "
        t = t.replacingOccurrences(of: #"^\s*(\|[^|]{1,6}\||\[[^\]]{1,8}\]|[A-Z]{2,3}\s*[:\-])\s*"#, with: "",
                                   options: .regularExpression)
        var season: Int?, episode: Int?
        if let r = t.range(of: #"[Ss](\d{1,2})\s*[Ee](\d{1,3})"#, options: .regularExpression) {
            let code = t[r]
            let nums = code.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 2 { season = nums[0]; episode = nums[1] }
            t = String(t[..<r.lowerBound])
        } else if let r = t.range(of: #"\b(\d{1,2})x(\d{1,3})\b"#, options: .regularExpression) {
            let nums = t[r].split(separator: "x").compactMap { Int($0) }
            if nums.count == 2 { season = nums[0]; episode = nums[1] }
            t = String(t[..<r.lowerBound])
        }
        var year: Int?
        if let r = t.range(of: #"[\(\[]?\b(19[0-9]{2}|20[0-9]{2})\b[\)\]]?"#, options: .regularExpression) {
            year = Int(t[r].filter(\.isNumber))
            t.removeSubrange(r)
        }
        // etichette di qualità/lingua e parentesi residue
        t = t.replacingOccurrences(of: #"(?i)\b(4k|uhd|fhd|hd|sd|hdr|1080p|720p|2160p|ita|eng|sub|multi|dual|h264|h265|x264|x265|web[- ]?dl|bluray)\b"#,
                                   with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\[\(][^\]\)]*[\]\)]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–|:"))
        return ParsedTitle(title: t, year: year, season: season, episode: episode)
    }
}

/// Contenuti aggiunti da link, salvati sul dispositivo e mostrati in Home.
/// I contenuti on demand vengono anche abbinati per nome ai titoli del catalogo TMDB,
/// così nella scheda del titolo compare "Riproduci".
@MainActor
@Observable
final class LinkLibrary {
    static let shared = LinkLibrary()

    private(set) var items: [LinkMedia] = []
    @ObservationIgnored private var liveCache: (count: Int, lives: Int) = (-1, 0)
    /// Numero di dirette importate. Ricalcolato solo quando l'elenco cambia (prima un osservatore
    /// sulla proprietà, che con @Observable non veniva eseguito: il contatore restava a 0 e la voce
    /// Dirette spariva da Categorie).
    var liveCount: Int {
        let list = items
        if liveCache.count != list.count { liveCache = (list.count, list.reduce(0) { $0 + ($1.isLive ? 1 : 0) }) }
        return liveCache.lives
    }
    /// id TMDB ("movie-123") → video
    private(set) var movieLinks: [String: LinkMedia] = [:]
    /// id TMDB della serie ("tv-456") → "s1e2" → video
    private(set) var episodeLinks: [String: [String: LinkMedia]] = [:]
    /// titoli abbinati, per la riga "Pronti da guardare"
    private(set) var matchedItems: [String: MediaItem] = [:]

    var isMatching = false
    var matchDone = 0
    var matchTotal = 0
    var matchFound = 0
    @ObservationIgnored private var cancelMatching = false

    private let key = "lumen.linkLibrary"
    private let matchKey = "lumen.linkMatches"

    private struct Matches: Codable, Sendable {
        var movies: [String: LinkMedia]
        var episodes: [String: [String: LinkMedia]]
        var items: [String: MediaItem]
    }

    /// true quando i contenuti collegati sono stati letti dal disco (lettura in background all'avvio).
    private(set) var isLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private init() {
        loadTask = Task { [weak self] in await self?.loadFromDisk() }
    }

    /// Legge elenco e abbinamenti fuori dal thread principale: con decine di migliaia di titoli
    /// la lettura sincrona rallentava l'apertura delle schede e la comparsa di "Riproduci".
    func loadIfNeeded() async { await loadTask?.value }

    private func loadFromDisk() async {
        let itemsURL = Self.itemsFile, matchesURL = Self.matchesFile, legacyKey = key
        let loaded: ([LinkMedia]?, Matches?) = await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            let items = (try? Data(contentsOf: itemsURL)).flatMap { try? decoder.decode([LinkMedia].self, from: $0) }
            let matches = (try? Data(contentsOf: matchesURL)).flatMap { try? decoder.decode(Matches.self, from: $0) }
            return (items, matches)
        }.value
        // Eventuali modifiche fatte nel frattempo hanno la precedenza.
        if let list = loaded.0 {
            let known = Set(items.map(\.id))
            items += list.filter { !known.contains($0.id) }
        } else if let data = UserDefaults.standard.data(forKey: legacyKey),
                  let saved = try? JSONDecoder().decode([LinkMedia].self, from: data) {
            items += saved
            save()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        if let m = loaded.1 {
            movieLinks = m.movies.merging(movieLinks) { _, new in new }
            episodeLinks = m.episodes.merging(episodeLinks) { old, new in old.merging(new) { _, n in n } }
            matchedItems = m.items.merging(matchedItems) { _, new in new }
        }
        isLoaded = true
        // Corsi e documentari non abbinati: riconosciuti in background, dopo che la Home è comparsa.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await self?.purgeAdultContent()
            await self?.autoAddCourses()
            await self?.autoAddDocumentaries()
        }
    }

    nonisolated private static var matchesFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("link-matches.json")
    }

    func contains(_ m: LinkMedia) -> Bool { items.contains { $0.id == m.id } }

    func add(_ list: [LinkMedia]) {
        let known = Set(items.map(\.id))
        items.insert(contentsOf: list.filter { !known.contains($0.id) }, at: 0)
        save()
    }

    func remove(_ m: LinkMedia) {
        items.removeAll { $0.id == m.id }
        movieLinks = movieLinks.filter { $0.value.id != m.id }
        for (k, v) in episodeLinks { episodeLinks[k] = v.filter { $0.value.id != m.id } }
        episodeLinks = episodeLinks.filter { !$0.value.isEmpty }
        matchedItems = matchedItems.filter { movieLinks[$0.key] != nil || episodeLinks[$0.key] != nil }
        save()
        saveMatches()
    }

    /// Rimuove tutti i contenuti (dirette, film, episodi) che puntano a questi indirizzi.
    func removeLinks(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        movieLinks = movieLinks.filter { !ids.contains($0.value.id) }
        for (k, v) in episodeLinks { episodeLinks[k] = v.filter { !ids.contains($0.value.id) } }
        episodeLinks = episodeLinks.filter { !$0.value.isEmpty }
        matchedItems = matchedItems.filter { movieLinks[$0.key] != nil || episodeLinks[$0.key] != nil }
        save()
        saveMatches()
    }

    /// Quanti contenuti importati provengono da questi indirizzi.
    func importedCount(_ ids: Set<String>) -> Int {
        items.filter { ids.contains($0.id) }.count
            + movieLinks.values.filter { ids.contains($0.id) }.count
            + episodeLinks.values.reduce(0) { $0 + $1.values.filter { ids.contains($0.id) }.count }
    }

    func removeAll() {
        items = []; movieLinks = [:]; episodeLinks = [:]; matchedItems = [:]
        save(); saveMatches()
    }

    // MARK: Abbinamento al catalogo

    func link(forItem id: String) -> LinkMedia? { movieLinks[id] }

    func link(seriesId: String, season: Int, episode: Int) -> LinkMedia? {
        episodeLinks[seriesId]?["s\(season)e\(episode)"]
    }

    func hasLinks(seriesId: String) -> Bool { !(episodeLinks[seriesId]?.isEmpty ?? true) }

    func stopMatching() { cancelMatching = true }

    /// Rimuove il video collegato a un titolo del catalogo (film o serie intera).
    func removeMatch(itemId: String) {
        movieLinks[itemId] = nil
        episodeLinks[itemId] = nil
        matchedItems[itemId] = nil
        saveMatches()
    }

    func removeMatches(_ ids: [String]) {
        for id in ids { movieLinks[id] = nil; episodeLinks[id] = nil; matchedItems[id] = nil }
        saveMatches()
    }

    func episodeCount(seriesId: String) -> Int { episodeLinks[seriesId]?.count ?? 0 }

    @ObservationIgnored private var matchedCache: (version: Int, movies: [MediaItem], series: [MediaItem]) = (-1, [], [])

    private var matchedLists: (movies: [MediaItem], series: [MediaItem]) {
        _ = matchedItems.count
        if matchedCache.version != matchesVersion {
            let values = Array(matchedItems.values)
            matchedCache = (matchesVersion,
                            Self.sortedByTitle(values.filter { !$0.isSeries && movieLinks[$0.id] != nil }),
                            Self.sortedByTitle(values.filter { $0.isSeries && episodeLinks[$0.id] != nil }))
        }
        return (matchedCache.movies, matchedCache.series)
    }

    var matchedMovies: [MediaItem] { matchedLists.movies }
    var matchedSeries: [MediaItem] { matchedLists.series }

    /// Importazione in blocco: aggiorna tutto e salva una volta sola (adatto a decine di migliaia di voci).
    func applyBatch(movies: [(LinkMedia, MediaItem)], series: [([String: LinkMedia], MediaItem)], unmatched: [LinkMedia]) {
        var ml = movieLinks, el = episodeLinks, mi = matchedItems
        let fresh = FreshnessStore.shared
        for (media, item) in movies {
            if ml[item.id] == nil { fresh.mark(item.id, .added) }
            ml[item.id] = media; mi[item.id] = item
        }
        for (eps, item) in series {
            let before = el[item.id].map { Set($0.keys) }
            el[item.id, default: [:]].merge(eps) { _, new in new }
            fresh.recordSeries(item.id, before: before, after: Set(el[item.id].map { Array($0.keys) } ?? []))
            mi[item.id] = item
        }
        fresh.save()
        movieLinks = ml; episodeLinks = el; matchedItems = mi
        saveMatches()
        if !unmatched.isEmpty { add(unmatched) }
        // Titoli di "La mia lista" diventati guardabili → avviso subito.
        Task { await WatchlistMonitor.shared.check() }
    }

    /// Episodi nuovi di serie già collegate: vengono aggiunti subito, senza analisi.
    /// Restituisce gli id usati e, per serie, gli episodi aggiunti ("s2e5").
    func autoLinkEpisodes(_ added: [LinkMedia]) -> (used: Set<String>, bySeries: [String: [String]]) {
        func norm(_ s: String) -> String {
            s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        // Nome della serie nella playlist → serie del catalogo
        var index: [String: String] = [:]
        for (sid, eps) in episodeLinks {
            for link in eps.values.prefix(3) {
                let key = norm(ParsedTitle.parse(link.title).title)
                if !key.isEmpty, index[key] == nil { index[key] = sid }
            }
        }
        var used = Set<String>()
        var bySeries: [String: [String: LinkMedia]] = [:]
        for m in added where !m.isLive {
            let p = ParsedTitle.parse(m.title)
            guard let s = p.season, let e = p.episode, let sid = index[norm(p.title)] else { continue }
            let key = "s\(s)e\(e)"
            guard episodeLinks[sid]?[key] == nil else { continue }
            bySeries[sid, default: [:]][key] = m
            used.insert(m.id)
        }
        for (sid, eps) in bySeries {
            guard let item = matchedItems[sid] else { continue }
            setEpisodeLinks(eps, for: item)
        }
        return (used, bySeries.mapValues { Array($0.keys) })
    }

    // MARK: Contenuti senza scheda nel catalogo

    /// id stabile per un contenuto aggiunto senza scheda TMDB ("link-…").
    nonisolated static func customId(_ name: String, series: Bool) -> String {
        let key = (series ? "s|" : "m|") + name.lowercased()
        return "link-" + SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Aggiunge al catalogo un film senza scheda (titolo e locandina dalla playlist).
    @discardableResult
    func addCustomMovie(_ media: LinkMedia) -> MediaItem {
        let p = ParsedTitle.parse(media.title)
        let item = MediaItem(id: Self.customId(p.title, series: false), title: p.title, kind: .movie,
                             poster: media.poster, backdrop: media.poster,
                             overview: "Aggiunto dalla playlist" + (media.group.map { " · \($0)" } ?? ""), year: p.year)
        removeLinks([media.id])
        setMovieLink(media, for: item)
        return item
    }

    /// Aggiunge al catalogo una serie senza scheda, con i suoi episodi ("s1e2" → video).
    @discardableResult
    func addCustomSeries(name: String, year: Int?, poster: URL?, episodes: [String: LinkMedia]) -> MediaItem {
        let item = MediaItem(id: Self.customId(name, series: true), title: name, kind: .series,
                             poster: poster, backdrop: poster, overview: "Aggiunta dalla playlist", year: year)
        removeLinks(Set(episodes.values.map(\.id)))
        setEpisodeLinks(episodes, for: item)
        return item
    }

    /// Schede dei film senza scheda TMDB (calcolate fuori dal thread principale: possono essere decine di migliaia).
    nonisolated static func customMoviePairs(_ list: [LinkMedia], overview: String? = nil) -> [(LinkMedia, MediaItem)] {
        list.map { media in
            let p = ParsedTitle.parse(media.title)
            let item = MediaItem(id: customId(p.title, series: false), title: p.title, kind: .movie,
                                 poster: media.poster, backdrop: media.poster,
                                 overview: overview ?? ("Aggiunto dalla playlist" + (media.group.map { " · \($0)" } ?? "")), year: p.year)
            return (media, item)
        }
    }

    nonisolated static func customSeriesPairs(_ list: [(name: String, year: Int?, poster: URL?, episodes: [String: LinkMedia])],
                                              overview: String?) -> [([String: LinkMedia], MediaItem)] {
        list.map { s in
            let text = overview.map { "\($0) · \(s.episodes.count) \($0 == "Corso" ? "lezioni" : "episodi")" } ?? "Aggiunta dalla playlist"
            let item = MediaItem(id: customId(s.name, series: true), title: s.name, kind: .series,
                                 poster: s.poster, backdrop: s.poster, overview: text, year: s.year)
            return (s.episodes, item)
        }
    }

    /// In blocco: un solo aggiornamento degli elenchi, delle novità e del salvataggio
    /// (prima un passaggio per titolo: con 33.000 voci l'app si bloccava e veniva chiusa).
    func addCustom(movies: [(LinkMedia, MediaItem)], series: [([String: LinkMedia], MediaItem)]) {
        guard !movies.isEmpty || !series.isEmpty else { return }
        removeLinks(Set(movies.map(\.0.id) + series.flatMap { $0.0.values.map(\.id) }))
        applyBatch(movies: movies, series: series, unmatched: [])
    }

    func addCustomMovies(_ list: [LinkMedia]) {
        addCustom(movies: Self.customMoviePairs(list), series: [])
    }

    /// Come sopra, preparando le schede in background.
    func addCustomMoviesAsync(_ list: [LinkMedia]) async {
        let pairs = await Task.detached(priority: .userInitiated) { LinkLibrary.customMoviePairs(list) }.value
        addCustom(movies: pairs, series: [])
    }

    func addCustomSeriesAsync(_ list: [(name: String, year: Int?, poster: URL?, episodes: [String: LinkMedia])], overview: String? = nil) async {
        let pairs = await Task.detached(priority: .userInitiated) { LinkLibrary.customSeriesPairs(list, overview: overview) }.value
        addCustom(movies: [], series: pairs)
    }

    func addCustomSeries(_ list: [(name: String, year: Int?, poster: URL?, episodes: [String: LinkMedia])], overview: String? = nil) {
        addCustom(movies: [], series: Self.customSeriesPairs(list, overview: overview))
    }

    /// Abbinamento manuale a una scheda del catalogo scelta dall'amministratore.
    func matchManually(movie media: LinkMedia, to item: MediaItem) {
        removeLinks([media.id])
        setMovieLink(media, for: item)
    }

    func matchManually(series episodes: [String: LinkMedia], to item: MediaItem) {
        removeLinks(Set(episodes.values.map(\.id)))
        setEpisodeLinks(episodes, for: item)
    }

    /// Ordine alfabetico veloce (chiave calcolata una volta per titolo: con decine di migliaia di titoli
    /// il confronto "localizzato" a ogni passo faceva scattare l'app).
    nonisolated static func sortedByTitle(_ list: [MediaItem]) -> [MediaItem] {
        list.map { ($0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), $0) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    @ObservationIgnored private var customCache: (version: Int, items: [MediaItem]) = (-1, [])

    /// Contenuti aggiunti senza scheda TMDB (calcolati una volta per versione degli abbinamenti).
    var customItems: [MediaItem] {
        _ = matchedItems.count   // osservazione: la vista si aggiorna quando cambiano
        if customCache.version != matchesVersion {
            customCache = (matchesVersion, Self.sortedByTitle(matchedItems.values.filter { $0.id.hasPrefix("link-") }))
        }
        return customCache.items
    }

    @ObservationIgnored private var groupCache: (version: Int, courses: [MediaItem], movies: [MediaItem], series: [MediaItem]) = (-1, [], [], [])

    /// Corsi / altri film / altre serie, divisi una sola volta per versione degli abbinamenti
    /// (prima a ogni aggiornamento della Home: con decine di migliaia di voci l'app scattava).
    private var groups: (courses: [MediaItem], movies: [MediaItem], series: [MediaItem]) {
        let all = customItems
        if groupCache.version != matchesVersion {
            var c: [MediaItem] = [], m: [MediaItem] = [], sr: [MediaItem] = []
            for item in all {
                if Self.isCourseItem(item) { c.append(item) }
                else if Self.isDocumentaryItem(item) { continue }
                else if item.isSeries { sr.append(item) } else { m.append(item) }
            }
            groupCache = (matchesVersion, c, m, sr)
        }
        return (groupCache.courses, groupCache.movies, groupCache.series)
    }

    /// Categoria "Corsi": contenuti formativi aggiunti dalla playlist.
    var courseItems: [MediaItem] { groups.courses }
    /// "Altri film" / "Altre serie": contenuti senza scheda che non sono corsi né documentari.
    var otherMovies: [MediaItem] { groups.movies }
    var otherSeries: [MediaItem] { groups.series }

    nonisolated static let docWords = ["documentar", "documentary", "docuserie", "docu-serie", "docufilm", "docu film",
                                       "docu ", "|docu", "doc:", "inchiesta", "reportage"]

    /// Voce della playlist che sembra un documentario (dal gruppo o dal titolo).
    nonisolated static func isDocumentary(_ m: LinkMedia) -> Bool {
        let t = " " + (m.title + " " + (m.group ?? "")).lowercased() + " "
        return docWords.contains { t.contains($0) }
    }

    static func isDocumentaryItem(_ item: MediaItem) -> Bool {
        (item.overview ?? "").hasPrefix("Documentario") ||
        (item.tags ?? []).contains { $0.lowercased().hasPrefix("document") }
    }

    /// Schede abbinate dalla ricerca documentari (anche se TMDB non le etichetta "Documentario").
    @ObservationIgnored private var docIds = Set(UserDefaults.standard.stringArray(forKey: "lumen.docIds") ?? [])

    func markDocumentaries(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        docIds.formUnion(ids)
        UserDefaults.standard.set(Array(docIds), forKey: "lumen.docIds")
        saveMatches()
    }

    @ObservationIgnored private var docCache: (version: Int, items: [MediaItem]) = (-1, [])

    /// Documentari guardabili in Lumen (abbinati al catalogo o aggiunti dalla playlist).
    var documentaryItems: [MediaItem] {
        _ = matchedItems.count
        if docCache.version != matchesVersion {
            docCache = (matchesVersion, Self.sortedByTitle(matchedItems.values.filter { docIds.contains($0.id) || Self.isDocumentaryItem($0) }))
        }
        return docCache.items
    }

    /// I documentari della playlist rimasti senza scheda vengono aggiunti comunque (categoria Documentari).
    func autoAddDocumentaries() async {
        let snapshot = items
        let prepared = await Task.detached(priority: .utility) { () -> ([(LinkMedia, MediaItem)], [([String: LinkMedia], MediaItem)]) in
            let docs = snapshot.filter { !$0.isLive && LinkLibrary.isDocumentary($0) && !LinkLibrary.isCourse($0.title + " " + ($0.group ?? "")) }
            guard !docs.isEmpty else { return ([], []) }
            var movies: [LinkMedia] = []
            var series: [String: (year: Int?, poster: URL?, episodes: [String: LinkMedia])] = [:]
            for m in docs {
                let p = ParsedTitle.parse(m.title)
                if let s = p.season, let e = p.episode {
                    var entry = series[p.title] ?? (p.year, m.poster, [:])
                    entry.episodes["s\(s)e\(e)"] = m
                    if entry.poster == nil { entry.poster = m.poster }
                    series[p.title] = entry
                } else {
                    movies.append(m)
                }
            }
            return (LinkLibrary.customMoviePairs(movies, overview: "Documentario · dalla playlist"),
                    LinkLibrary.customSeriesPairs(series.map { (name: $0.key, year: $0.value.year, poster: $0.value.poster, episodes: $0.value.episodes) },
                                                  overview: "Documentario"))
        }.value
        addCustom(movies: prepared.0, series: prepared.1)
    }

    nonisolated static let courseWords = ["corso", "corsi", "course", "lezione", "lezioni", "lesson", "tutorial",
                                          "masterclass", "formazione", "webinar", "udemy", "videocorso"]

    nonisolated static func isCourse(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        return courseWords.contains { t.contains($0) }
    }

    static func isCourseItem(_ item: MediaItem) -> Bool {
        (item.overview ?? "").hasPrefix("Corso") || isCourse(item.title)
    }

    /// Indirizzi di tutti i contenuti già importati (catalogo, episodi, dirette, non abbinati).
    var allLinkedIds: Set<String> {
        var ids = Set(items.map(\.id))
        for m in movieLinks.values { ids.insert(m.id) }
        for eps in episodeLinks.values { for m in eps.values { ids.insert(m.id) } }
        return ids
    }

    /// Le voci formative non abbinate (corsi, lezioni, tutorial) diventano corsi nella categoria "Corsi":
    /// un corso per gruppo della playlist, con le lezioni in ordine.
    func autoAddCourses() async {
        let snapshot = items
        let pairs = await Task.detached(priority: .utility) { () -> [([String: LinkMedia], MediaItem)] in
            let candidates = snapshot.filter { !$0.isLive && LinkLibrary.isCourse($0.title + " " + ($0.group ?? "")) }
            guard !candidates.isEmpty else { return [] }
            let groups = Dictionary(grouping: candidates) { m -> String in
                let g = (m.group ?? "").trimmingCharacters(in: .whitespaces)
                return g.isEmpty ? ParsedTitle.parse(m.title).title : g
            }
            var list: [(name: String, year: Int?, poster: URL?, episodes: [String: LinkMedia])] = []
            for (name, lessons) in groups {
                let sorted = lessons.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                var eps: [String: LinkMedia] = [:]
                for (i, m) in sorted.enumerated() { eps["s1e\(i + 1)"] = m }
                list.append((name: name, year: nil, poster: sorted.first { $0.poster != nil }?.poster, episodes: eps))
            }
            return LinkLibrary.customSeriesPairs(list, overview: "Corso")
        }.value
        addCustom(movies: [], series: pairs)
    }

    /// Scheda costruita in locale per un contenuto senza scheda TMDB (stagioni dagli episodi collegati).
    func localDetail(for item: MediaItem) -> MediaDetail? {
        guard item.id.hasPrefix("link-") else { return nil }
        let base = matchedItems[item.id] ?? item
        guard base.isSeries, let eps = episodeLinks[item.id] else { return MediaDetail(item: base) }
        var bySeason: [Int: [Episode]] = [:]
        for (key, media) in eps {
            let nums = key.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count == 2 else { continue }
            bySeason[nums[0], default: []].append(Episode(id: "\(item.id)-s\(nums[0])e\(nums[1])", number: nums[1],
                                                          title: media.title))
        }
        let seasons = bySeason.keys.sorted().map { n in
            Season(id: "\(item.id)-s\(n)", number: n, title: "Stagione \(n)",
                   episodes: bySeason[n]!.sorted { $0.number < $1.number })
        }
        return MediaDetail(item: base, seasons: seasons)
    }

    func setMovieLink(_ media: LinkMedia, for item: MediaItem) {
        if movieLinks[item.id] == nil { FreshnessStore.shared.mark(item.id, .added); FreshnessStore.shared.save() }
        movieLinks[item.id] = media
        matchedItems[item.id] = item
        saveMatches()
    }

    func setEpisodeLinks(_ episodes: [String: LinkMedia], for item: MediaItem) {
        let before = episodeLinks[item.id].map { Set($0.keys) }
        episodeLinks[item.id, default: [:]].merge(episodes) { _, new in new }
        FreshnessStore.shared.recordSeries(item.id, before: before, after: Set(episodeLinks[item.id].map { Array($0.keys) } ?? []))
        FreshnessStore.shared.save()
        matchedItems[item.id] = item
        saveMatches()
    }

    /// Aggiunge i contenuti e abbina quelli on demand al catalogo TMDB cercando per titolo (e anno).
    func importAndMatch(_ list: [LinkMedia], tmdb: TMDBProvider?) async {
        // Le dirette restano nell'elenco del pannello; i VOD si integrano nelle schede del catalogo.
        add(list.filter(\.isLive))
        let vods = list.filter { !$0.isLive }
        guard let tmdb else { add(vods); return }
        guard !vods.isEmpty else { return }
        var unmatched: [LinkMedia] = []
        defer { add(unmatched) }
        isMatching = true
        cancelMatching = false
        matchDone = 0
        matchTotal = vods.count
        matchFound = 0
        defer { isMatching = false; saveMatches() }

        // Una sola ricerca per titolo (le serie hanno molti episodi con lo stesso nome).
        var cache: [String: MediaItem?] = [:]
        for media in vods {
            if cancelMatching { break }
            let parsed = ParsedTitle.parse(media.title)
            let hintSeries = parsed.isEpisode || (media.group?.lowercased().contains("serie") ?? false)
            let cacheKey = "\(hintSeries)|\(parsed.title.lowercased())|\(parsed.year ?? 0)"
            let found: MediaItem?
            if let cached = cache[cacheKey] {
                found = cached
            } else {
                found = try? await tmdb.match(title: parsed.title, year: parsed.year, series: hintSeries)
                cache[cacheKey] = found
            }
            matchDone += 1
            guard let item = found else { unmatched.append(media); continue }
            if item.isSeries {
                guard let s = parsed.season, let e = parsed.episode else { unmatched.append(media); continue }
                episodeLinks[item.id, default: [:]]["s\(s)e\(e)"] = media
            } else {
                movieLinks[item.id] = media
            }
            matchedItems[item.id] = item
            matchFound += 1
            if matchDone % 25 == 0 { saveMatches() }
        }
    }

    nonisolated private static var itemsFile: URL {
        matchesFile.deletingLastPathComponent().appendingPathComponent("link-items.json")
    }

    @ObservationIgnored private var saveItemsTask: Task<Void, Never>?
    @ObservationIgnored private var saveMatchesTask: Task<Void, Never>?

    /// Salvataggio in background e raggruppato (più modifiche ravvicinate = una sola scrittura).
    private func save() {
        saveItemsTask?.cancel()
        saveItemsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await self.loadTask?.value   // mai sovrascrivere il file prima di averlo letto
            let list = self.items, url = Self.itemsFile
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
            }.value
        }
    }

    /// Cambia a ogni modifica degli abbinamenti (per le liste calcolate, es. Altri contenuti).
    @ObservationIgnored private(set) var matchesVersion = 0

    private func saveMatches() {
        matchesVersion += 1
        saveMatchesTask?.cancel()
        saveMatchesTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await self.loadTask?.value   // mai sovrascrivere il file prima di averlo letto
            let m = Matches(movies: self.movieLinks, episodes: self.episodeLinks, items: self.matchedItems)
            let url = Self.matchesFile
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(m) { try? data.write(to: url, options: .atomic) }
            }.value
        }
    }
}
