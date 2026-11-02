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
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                pendingTitle = line.components(separatedBy: ",").dropFirst().joined(separator: ",")
                    .trimmingCharacters(in: .whitespaces)
                if let r = line.range(of: "tvg-logo=\""), let end = line[r.upperBound...].firstIndex(of: "\"") {
                    pendingLogo = URL(string: String(line[r.upperBound..<end]))
                }
                if let r = line.range(of: "group-title=\""), let end = line[r.upperBound...].firstIndex(of: "\"") {
                    pendingGroup = String(line[r.upperBound..<end])
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let u = URL(string: line, relativeTo: base)?.absoluteURL {
                let title = (pendingTitle?.isEmpty == false ? pendingTitle! : prettyTitle(u))
                let ext = u.pathExtension.lowercased()
                let isVOD = ["mp4", "mkv", "m4v", "mov", "avi"].contains(ext) || u.path.contains("/movie/") || u.path.contains("/series/")
                items.append(LinkMedia(title: title, url: u, poster: pendingLogo,
                                       isLive: !isVOD, source: "Playlist", group: pendingGroup))
                pendingTitle = nil
                pendingLogo = nil
                pendingGroup = nil
            }
        }
        return items.isEmpty ? .nothing("La playlist è vuota.") : .media(items)
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
struct ParsedTitle: Equatable {
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

    private struct Matches: Codable {
        var movies: [String: LinkMedia]
        var episodes: [String: [String: LinkMedia]]
        var items: [String: MediaItem]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([LinkMedia].self, from: data) {
            items = saved
        }
        if let data = try? Data(contentsOf: Self.matchesFile),
           let m = try? JSONDecoder().decode(Matches.self, from: data) {
            movieLinks = m.movies
            episodeLinks = m.episodes
            matchedItems = m.items
        }
    }

    private static var matchesFile: URL {
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

    /// Aggiunge i contenuti e abbina quelli on demand al catalogo TMDB cercando per titolo (e anno).
    func importAndMatch(_ list: [LinkMedia], tmdb: TMDBProvider?) async {
        add(list)
        guard let tmdb else { return }
        let vods = list.filter { !$0.isLive }
        guard !vods.isEmpty else { return }
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
            guard let item = found else { continue }
            if item.isSeries {
                guard let s = parsed.season, let e = parsed.episode else { continue }
                episodeLinks[item.id, default: [:]]["s\(s)e\(e)"] = media
            } else {
                movieLinks[item.id] = media
            }
            matchedItems[item.id] = item
            matchFound += 1
            if matchDone % 25 == 0 { saveMatches() }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func saveMatches() {
        let m = Matches(movies: movieLinks, episodes: episodeLinks, items: matchedItems)
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: Self.matchesFile) }
    }
}
