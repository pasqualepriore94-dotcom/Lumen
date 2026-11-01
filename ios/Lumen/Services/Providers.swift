import Foundation

/// Qualsiasi sorgente di contenuti agganciabile all'app.
protocol ContentProvider {
    var capabilities: ProviderCapabilities { get }
    func home() async throws -> HomeFeed
    func search(_ query: String) async throws -> [MediaItem]
    func detail(id: String) async throws -> MediaDetail
    func streams(id: String, episodeId: String?) async throws -> [StreamSource]
    func clips() async throws -> [Clip]
    func genres(kind: MediaKind) async throws -> [Genre]
    func browse(kind: MediaKind, genre: String?, sort: BrowseSort, page: Int) async throws -> BrowsePage
}

struct ProviderCapabilities {
    var streams = true
    var clips = true
    var browse = false
}

struct Genre: Identifiable, Hashable {
    let id: String
    let name: String
}

enum BrowseSort: String, CaseIterable, Identifiable {
    case popular, topRated, newest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .popular: return "Più popolari"
        case .topRated: return "Più votati"
        case .newest: return "Più recenti"
        }
    }
}

struct BrowsePage {
    var items: [MediaItem]
    var page: Int
    var totalPages: Int
    var hasMore: Bool { page < totalPages }
}

extension ContentProvider {
    var capabilities: ProviderCapabilities { ProviderCapabilities() }
    func genres(kind: MediaKind) async throws -> [Genre] { [] }
    func browse(kind: MediaKind, genre: String?, sort: BrowseSort, page: Int) async throws -> BrowsePage {
        throw ProviderError.notSupported
    }
}

enum ProviderError: LocalizedError {
    case noProvider
    case invalidURL(String)
    case http(Int)
    case decoding(String)
    case notFound
    case noStreams
    case notSupported
    case catalogOnly

    var errorDescription: String? {
        switch self {
        case .noProvider: return "Nessuna sorgente attiva. Configurane una dal pannello amministratore."
        case .invalidURL(let s): return "URL non valido: \(s)"
        case .http(let code): return "Il server ha risposto con errore \(code)."
        case .decoding(let msg): return "Risposta non nel formato atteso. \(msg)"
        case .notFound: return "Contenuto non trovato."
        case .noStreams: return "Nessun flusso video disponibile per questo titolo."
        case .notSupported: return "Funzione non disponibile con questa sorgente."
        case .catalogOnly: return "Questa sorgente è un catalogo: mostra trame, cast e voti ma non contiene video. Guarda il trailer o i servizi su cui è disponibile."
        }
    }
}

enum ProviderFactory {
    static func make(_ config: ProviderConfig?) -> ContentProvider {
        guard let config else { return EmptyProvider() }
        switch config.type {
        case .tmdb: return TMDBProvider(config: config)
        case .demo: return DemoProvider()
        case .custom: return CustomAPIProvider(config: config)
        }
    }
}

struct EmptyProvider: ContentProvider {
    var capabilities: ProviderCapabilities { ProviderCapabilities(streams: false, clips: false, browse: false) }
    func home() async throws -> HomeFeed { throw ProviderError.noProvider }
    func search(_ query: String) async throws -> [MediaItem] { throw ProviderError.noProvider }
    func detail(id: String) async throws -> MediaDetail { throw ProviderError.noProvider }
    func streams(id: String, episodeId: String?) async throws -> [StreamSource] { throw ProviderError.noProvider }
    func clips() async throws -> [Clip] { throw ProviderError.noProvider }
}

// MARK: - Demo integrato (contenuti open / di test, inclusi nell'app)

struct DemoCatalog: Decodable {
    var home: HomeFeed
    var details: [String: MediaDetail]
    var streams: [String: [StreamSource]]
    var clips: [Clip]

    static let shared: DemoCatalog? = {
        guard let url = Bundle.main.url(forResource: "demo_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(DemoCatalog.self, from: data)
        } catch {
            print("Errore catalogo demo: \(error)")
            return nil
        }
    }()
}

struct DemoProvider: ContentProvider {
    private func catalog() throws -> DemoCatalog {
        guard let c = DemoCatalog.shared else { throw ProviderError.decoding("Catalogo demo mancante") }
        return c
    }

    func home() async throws -> HomeFeed { try catalog().home }

    func search(_ query: String) async throws -> [MediaItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = try catalog().home.allItems
        guard !q.isEmpty else { return all }
        return all.filter { item in
            [item.title, item.overview ?? "", item.tagLine].contains {
                $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    func detail(id: String) async throws -> MediaDetail {
        let c = try catalog()
        if let d = c.details[id] { return d }
        if let item = c.home.allItems.first(where: { $0.id == id }) { return MediaDetail(item: item) }
        throw ProviderError.notFound
    }

    func streams(id: String, episodeId: String?) async throws -> [StreamSource] {
        let c = try catalog()
        if let episodeId, let list = c.streams[episodeId] { return list }
        if let list = c.streams[id] { return list }
        throw ProviderError.noStreams
    }

    func clips() async throws -> [Clip] { try catalog().clips }

    var capabilities: ProviderCapabilities { ProviderCapabilities(streams: true, clips: true, browse: true) }

    func genres(kind: MediaKind) async throws -> [Genre] {
        let tags = try catalog().home.allItems.filter { ($0.kind ?? .movie) == kind }.flatMap { $0.tags ?? [] }
        return Array(Set(tags)).sorted().map { Genre(id: $0, name: $0) }
    }

    func browse(kind: MediaKind, genre: String?, sort: BrowseSort, page: Int) async throws -> BrowsePage {
        var items = try catalog().home.allItems.filter { ($0.kind ?? .movie) == kind }
        if let genre { items = items.filter { ($0.tags ?? []).contains(genre) } }
        switch sort {
        case .popular: break
        case .topRated: items.sort { ($0.score ?? 0) > ($1.score ?? 0) }
        case .newest: items.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        }
        return BrowsePage(items: page == 1 ? items : [], page: page, totalPages: 1)
    }
}

// MARK: - API personalizzata (contratto JSON descritto in docs/API.md)

struct CustomAPIProvider: ContentProvider {
    let config: ProviderConfig

    func home() async throws -> HomeFeed {
        try await get(HomeFeed.self, path: config.paths.home)
    }

    func search(_ query: String) async throws -> [MediaItem] {
        try await get(ListEnvelope<MediaItem>.self, path: config.paths.search, vars: ["query": query]).items
    }

    func detail(id: String) async throws -> MediaDetail {
        try await get(MediaDetail.self, path: config.paths.detail, vars: ["id": id])
    }

    func streams(id: String, episodeId: String?) async throws -> [StreamSource] {
        let list = try await get(ListEnvelope<StreamSource>.self, path: config.paths.streams,
                                 vars: ["id": id, "episode": episodeId ?? ""]).items
        if list.isEmpty { throw ProviderError.noStreams }
        return list
    }

    func clips() async throws -> [Clip] {
        try await get(ListEnvelope<Clip>.self, path: config.paths.clips).items
    }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(streams: true, clips: !config.paths.clips.isEmpty, browse: !config.paths.browse.isEmpty)
    }

    func browse(kind: MediaKind, genre: String?, sort: BrowseSort, page: Int) async throws -> BrowsePage {
        guard !config.paths.browse.isEmpty else { throw ProviderError.notSupported }
        let items = try await get(ListEnvelope<MediaItem>.self, path: config.paths.browse,
                                  vars: ["kind": kind.rawValue, "genre": genre ?? "", "sort": sort.rawValue,
                                         "page": String(page)]).items
        return BrowsePage(items: items, page: page, totalPages: items.isEmpty ? page : page + 1)
    }

    // MARK: rete

    func buildURL(_ template: String, vars: [String: String]) throws -> URL {
        var path = template
        for (key, value) in vars {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlValueAllowed) ?? value
            path = path.replacingOccurrences(of: "{\(key)}", with: encoded)
        }
        // Rimuove eventuali parametri vuoti tipo "?episode=" per pulizia.
        path = path.replacingOccurrences(of: "?episode=&", with: "?")
        if path.hasSuffix("?episode=") { path.removeLast("?episode=".count) }
        if path.hasSuffix("&episode=") { path.removeLast("&episode=".count) }

        let full: String
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            full = path
        } else {
            var base = config.baseURL.trimmingCharacters(in: .whitespaces)
            while base.hasSuffix("/") { base.removeLast() }
            full = base + (path.hasPrefix("/") ? path : "/" + path)
        }
        guard let url = URL(string: full), url.scheme != nil, url.host != nil else {
            throw ProviderError.invalidURL(full)
        }
        return url
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, vars: [String: String] = [:]) async throws -> T {
        let url = try buildURL(path, vars: vars)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in config.headers where !key.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "Campo mancante '\(key.stringValue)' in \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }
}

extension CharacterSet {
    static let urlValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#/")
        return set
    }()
}
