import Foundation

/// Qualsiasi sorgente di contenuti agganciabile all'app.
protocol ContentProvider {
    func home() async throws -> HomeFeed
    func search(_ query: String) async throws -> [MediaItem]
    func detail(id: String) async throws -> MediaDetail
    func streams(id: String, episodeId: String?) async throws -> [StreamSource]
    func clips() async throws -> [Clip]
}

enum ProviderError: LocalizedError {
    case noProvider
    case invalidURL(String)
    case http(Int)
    case decoding(String)
    case notFound
    case noStreams

    var errorDescription: String? {
        switch self {
        case .noProvider: return "Nessuna sorgente attiva. Configurane una dal pannello amministratore."
        case .invalidURL(let s): return "URL non valido: \(s)"
        case .http(let code): return "Il server ha risposto con errore \(code)."
        case .decoding(let msg): return "Risposta non nel formato atteso. \(msg)"
        case .notFound: return "Contenuto non trovato."
        case .noStreams: return "Nessun flusso video disponibile per questo titolo."
        }
    }
}

enum ProviderFactory {
    static func make(_ config: ProviderConfig?) -> ContentProvider {
        guard let config else { return EmptyProvider() }
        switch config.type {
        case .demo: return DemoProvider()
        case .custom: return CustomAPIProvider(config: config)
        }
    }
}

struct EmptyProvider: ContentProvider {
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
