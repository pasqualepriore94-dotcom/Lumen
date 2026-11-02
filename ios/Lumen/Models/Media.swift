import Foundation

// MARK: - Contenuti

enum MediaKind: String, Codable, Hashable {
    case movie
    case series
}

/// Un titolo del catalogo (film o serie). Decodifica "tollerante": i campi
/// mancanti o di tipo diverso vengono ignorati invece di far fallire tutto.
struct MediaItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var kind: MediaKind?
    var poster: URL?
    var backdrop: URL?
    var overview: String?
    var year: Int?
    var tags: [String]?
    var badge: String?
    var rank: Int?
    var rating: String?
    /// Voto medio 0–10 (es. TMDB).
    var score: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, kind, poster, backdrop, overview, year, tags, badge, rank, rating, score
    }

    init(id: String, title: String, kind: MediaKind? = nil, poster: URL? = nil, backdrop: URL? = nil,
         overview: String? = nil, year: Int? = nil, tags: [String]? = nil, badge: String? = nil,
         rank: Int? = nil, rating: String? = nil, score: Double? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.poster = poster
        self.backdrop = backdrop; self.overview = overview; self.year = year; self.tags = tags
        self.badge = badge; self.rank = rank; self.rating = rating; self.score = score
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "id mancante"))
        }
        self.id = id
        self.title = c.lossyString(.title) ?? "Senza titolo"
        self.kind = (try? c.decode(MediaKind.self, forKey: .kind))
        self.poster = c.lossyURL(.poster)
        self.backdrop = c.lossyURL(.backdrop)
        self.overview = c.lossyString(.overview)
        self.year = c.lossyInt(.year)
        self.tags = try? c.decode([String].self, forKey: .tags)
        self.badge = c.lossyString(.badge)
        self.rank = c.lossyInt(.rank)
        self.rating = c.lossyString(.rating)
        self.score = c.lossyDouble(.score)
    }

    var isSeries: Bool { kind == .series }
    var tagLine: String { (tags ?? []).joined(separator: " • ") }
    var bestWideImage: URL? { backdrop ?? poster }
    var bestPosterImage: URL? { poster ?? backdrop }
    var scoreLabel: String? {
        guard let score, score > 0 else { return nil }
        return score.formatted(.number.precision(.fractionLength(1)))
    }
}

struct CatalogSection: Decodable, Identifiable {
    var id: String
    var title: String
    var style: String?
    var items: [MediaItem]

    enum CodingKeys: String, CodingKey { case id, title, style, items }

    init(id: String, title: String, style: String?, items: [MediaItem]) {
        self.id = id; self.title = title; self.style = style; self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lossyString(.title) ?? ""
        id = c.lossyString(.id) ?? title
        style = c.lossyString(.style)
        items = c.lossyArray(MediaItem.self, .items)
    }

    /// poster (default) | large | top10 | wide
    var layout: SectionLayout { SectionLayout(rawValue: style ?? "") ?? .poster }
}

enum SectionLayout: String {
    case poster, large, top10, wide
}

struct HomeFeed: Decodable {
    var hero: MediaItem?
    var sections: [CatalogSection]

    enum CodingKeys: String, CodingKey { case hero, sections }

    init(hero: MediaItem?, sections: [CatalogSection]) {
        self.hero = hero; self.sections = sections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hero = try? c.decode(MediaItem.self, forKey: .hero)
        sections = c.lossyArray(CatalogSection.self, .sections)
    }

    var allItems: [MediaItem] {
        var seen = Set<String>()
        var out: [MediaItem] = []
        for item in ([hero].compactMap { $0 } + sections.flatMap(\.items)) where !seen.contains(item.id) {
            seen.insert(item.id)
            out.append(item)
        }
        return out
    }
}

struct Episode: Codable, Identifiable, Hashable {
    var id: String
    var number: Int
    var title: String
    var overview: String?
    var still: URL?
    var duration: Int?

    enum CodingKeys: String, CodingKey { case id, number, title, overview, still, duration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "id episodio mancante"))
        }
        self.id = id
        number = c.lossyInt(.number) ?? 0
        title = c.lossyString(.title) ?? "Episodio \(number)"
        overview = c.lossyString(.overview)
        still = c.lossyURL(.still)
        duration = c.lossyInt(.duration)
    }

    var durationLabel: String? {
        guard let d = duration, d > 0 else { return nil }
        let minutes = max(1, d / 60)
        return "\(minutes) min"
    }
}

struct Season: Codable, Identifiable, Hashable {
    var id: String
    var number: Int
    var title: String?
    var episodes: [Episode]

    enum CodingKeys: String, CodingKey { case id, number, title, episodes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = c.lossyInt(.number) ?? 1
        id = c.lossyString(.id) ?? "s\(number)"
        title = c.lossyString(.title)
        episodes = c.lossyArray(Episode.self, .episodes)
    }

    var displayTitle: String { title ?? "Stagione \(number)" }
}

struct CastMember: Codable, Hashable, Identifiable {
    var id: String { name + (character ?? "") }
    var name: String
    var character: String?
    var photo: URL?

    enum CodingKeys: String, CodingKey { case name, character, photo }

    init(name: String, character: String? = nil, photo: URL? = nil) {
        self.name = name; self.character = character; self.photo = photo
    }

    /// Accetta sia "Nome Cognome" sia { "name": …, "character": …, "photo": … }.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.name = name; character = nil; photo = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lossyString(.name) ?? "?"
        character = c.lossyString(.character)
        photo = c.lossyURL(.photo)
    }
}

struct WatchProvider: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var logo: URL?
    var type: String?   // flatrate | rent | buy

    enum CodingKeys: String, CodingKey { case name, logo, type }

    init(name: String, logo: URL?, type: String?) { self.name = name; self.logo = logo; self.type = type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lossyString(.name) ?? "?"
        logo = c.lossyURL(.logo)
        type = c.lossyString(.type)
    }
}

/// Dettaglio di un titolo. Accetta sia `{ "item": {...}, "seasons": [...] }`
/// sia un oggetto "piatto" con i campi del titolo al primo livello.
struct MediaDetail: Codable {
    var item: MediaItem
    var seasons: [Season]
    var cast: [CastMember]
    var duration: Int?
    var genres: [String]
    var director: String?
    var trailer: URL?
    var imdbId: String?
    var imdbRating: String?
    var watchProviders: [WatchProvider]
    var watchLink: URL?

    enum CodingKeys: String, CodingKey {
        case item, seasons, cast, duration, genres, director, trailer, imdbId, imdbRating, watchProviders, watchLink
    }

    init(item: MediaItem, seasons: [Season] = [], cast: [CastMember] = [], duration: Int? = nil,
         genres: [String] = [], director: String? = nil, trailer: URL? = nil, imdbId: String? = nil,
         imdbRating: String? = nil, watchProviders: [WatchProvider] = [], watchLink: URL? = nil) {
        self.item = item; self.seasons = seasons; self.cast = cast; self.duration = duration
        self.genres = genres; self.director = director; self.trailer = trailer; self.imdbId = imdbId
        self.imdbRating = imdbRating; self.watchProviders = watchProviders; self.watchLink = watchLink
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? c.decode(MediaItem.self, forKey: .item) {
            item = nested
        } else {
            item = try MediaItem(from: decoder)
        }
        seasons = c.lossyArray(Season.self, .seasons)
        cast = c.lossyArray(CastMember.self, .cast)
        duration = c.lossyInt(.duration)
        genres = (try? c.decode([String].self, forKey: .genres)) ?? []
        director = c.lossyString(.director)
        trailer = c.lossyURL(.trailer)
        imdbId = c.lossyString(.imdbId)
        imdbRating = c.lossyString(.imdbRating)
        watchProviders = c.lossyArray(WatchProvider.self, .watchProviders)
        watchLink = c.lossyURL(.watchLink)
    }

    var firstEpisode: Episode? { seasons.first?.episodes.first }

    func episode(id: String?) -> Episode? {
        guard let id else { return nil }
        return seasons.flatMap(\.episodes).first { $0.id == id }
    }

    func label(for episode: Episode) -> String {
        if let season = seasons.first(where: { $0.episodes.contains(episode) }) {
            return "S\(season.number):E\(episode.number) \(episode.title)"
        }
        return episode.title
    }
}

struct StreamSource: Decodable, Hashable {
    var url: URL
    var quality: String?
    var headers: [String: String]?

    enum CodingKeys: String, CodingKey { case url, quality, headers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = c.lossyURL(.url) else {
            throw DecodingError.keyNotFound(CodingKeys.url, .init(codingPath: c.codingPath, debugDescription: "url stream mancante"))
        }
        self.url = url
        quality = c.lossyString(.quality)
        headers = try? c.decode([String: String].self, forKey: .headers)
    }
}

struct Clip: Decodable, Identifiable, Hashable {
    var id: String
    var item: MediaItem
    var video: URL

    enum CodingKeys: String, CodingKey { case id, item, video }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(MediaItem.self, forKey: .item)
        guard let video = c.lossyURL(.video) else {
            throw DecodingError.keyNotFound(CodingKeys.video, .init(codingPath: c.codingPath, debugDescription: "video mancante"))
        }
        self.video = video
        id = c.lossyString(.id) ?? video.absoluteString
    }
}

// MARK: - Decodifica tollerante

struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

/// Accetta sia un array diretto `[...]` sia un oggetto con `results`, `items`, `data`, `streams` o `clips`.
struct ListEnvelope<T: Decodable>: Decodable {
    let items: [T]

    init(from decoder: Decoder) throws {
        if let list = try? Array<Failable<T>>(from: decoder) {
            items = list.compactMap(\.value)
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        for name in ["results", "items", "data", "streams", "clips", "sources"] {
            if let key = AnyKey(stringValue: name), let list = try? c.decode([Failable<T>].self, forKey: key) {
                items = list.compactMap(\.value)
                return
            }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Atteso un array o un oggetto con 'results'/'items'"))
    }
}

extension KeyedDecodingContainer {
    func lossyString(_ key: Key) -> String? {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func lossyInt(_ key: Key) -> Int? {
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let d = try? decode(Double.self, forKey: key) { return Int(d) }
        if let s = try? decode(String.self, forKey: key) { return Int(s) }
        return nil
    }

    func lossyDouble(_ key: Key) -> Double? {
        if let d = try? decode(Double.self, forKey: key) { return d }
        if let s = try? decode(String.self, forKey: key) { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    func lossyURL(_ key: Key) -> URL? {
        guard let s = lossyString(key)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let url = URL(string: s) { return url }
        return s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }

    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        ((try? decode([Failable<T>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}
