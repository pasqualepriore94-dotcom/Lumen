import Foundation

// MARK: - Configurazione app (condivisa tra admin web e admin in-app)

enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case tmdb
    case demo
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tmdb: return "Catalogo TMDB"
        case .demo: return "Demo integrato"
        case .custom: return "API personalizzata"
        }
    }
}

/// Percorsi degli endpoint. Segnaposto disponibili: {query}, {id}, {episode}.
struct ProviderPaths: Codable, Hashable {
    var home: String
    var search: String
    var detail: String
    var streams: String
    var clips: String
    /// Facoltativo: elenco paginato di tutto il catalogo. Segnaposto {kind} {genre} {sort} {page}.
    var browse: String

    static let `default` = ProviderPaths(
        home: "/home",
        search: "/search?q={query}",
        detail: "/titles/{id}",
        streams: "/titles/{id}/streams?episode={episode}",
        clips: "/clips",
        browse: ""
    )

    init(home: String, search: String, detail: String, streams: String, clips: String, browse: String) {
        self.home = home; self.search = search; self.detail = detail; self.streams = streams
        self.clips = clips; self.browse = browse
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProviderPaths.default
        home = (try? c.decode(String.self, forKey: .home)) ?? d.home
        search = (try? c.decode(String.self, forKey: .search)) ?? d.search
        detail = (try? c.decode(String.self, forKey: .detail)) ?? d.detail
        streams = (try? c.decode(String.self, forKey: .streams)) ?? d.streams
        clips = (try? c.decode(String.self, forKey: .clips)) ?? d.clips
        browse = (try? c.decode(String.self, forKey: .browse)) ?? d.browse
    }
}

struct ProviderConfig: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: ProviderType
    var baseURL: String
    var paths: ProviderPaths
    var headers: [String: String]
    /// Opzioni specifiche del tipo (TMDB: tmdbKey, omdbKey, language, region).
    var options: [String: String]
    var enabled: Bool

    static let demo = ProviderConfig(id: "demo", name: "Catalogo demo", type: .demo, baseURL: "",
                                     paths: .default, headers: [:], options: [:], enabled: true)

    static let tmdb = ProviderConfig(id: "tmdb", name: "Catalogo film e serie (TMDB)", type: .tmdb,
                                     baseURL: "https://api.themoviedb.org/3", paths: .default, headers: [:],
                                     options: ["tmdbKey": "1b36f5d2503ec79155ce5d9afdb9e57c", "omdbKey": "823137cf", "language": "it-IT", "region": "IT"],
                                     enabled: true)

    static func newCustom() -> ProviderConfig {
        ProviderConfig(id: "api-" + UUID().uuidString.prefix(6).lowercased(), name: "Nuova API", type: .custom,
                       baseURL: "https://", paths: .default, headers: [:], options: [:], enabled: true)
    }

    init(id: String, name: String, type: ProviderType, baseURL: String, paths: ProviderPaths,
         headers: [String: String], options: [String: String] = [:], enabled: Bool) {
        self.id = id; self.name = name; self.type = type; self.baseURL = baseURL
        self.paths = paths; self.headers = headers; self.options = options; self.enabled = enabled
    }

    func option(_ key: String) -> String {
        (options[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Una sorgente è utilizzabile se attiva e, per TMDB, se ha la chiave.
    var isUsable: Bool {
        guard enabled else { return false }
        if type == .tmdb { return !option("tmdbKey").isEmpty }
        return true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        type = (try? c.decode(ProviderType.self, forKey: .type)) ?? .custom
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? ""
        paths = (try? c.decode(ProviderPaths.self, forKey: .paths)) ?? .default
        headers = (try? c.decode([String: String].self, forKey: .headers)) ?? [:]
        options = (try? c.decode([String: String].self, forKey: .options)) ?? [:]
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
    }
}

struct AppConfig: Codable, Equatable {
    var appName: String
    var accentHex: String
    var activeProviderId: String?
    var providers: [ProviderConfig]

    static let `default` = AppConfig(appName: "Lumen", accentHex: "#7C5CFF",
                                     activeProviderId: "tmdb", providers: [.tmdb, .demo])

    init(appName: String, accentHex: String, activeProviderId: String?, providers: [ProviderConfig]) {
        self.appName = appName; self.accentHex = accentHex
        self.activeProviderId = activeProviderId; self.providers = providers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default
        appName = (try? c.decode(String.self, forKey: .appName)) ?? d.appName
        accentHex = (try? c.decode(String.self, forKey: .accentHex)) ?? d.accentHex
        activeProviderId = try? c.decode(String.self, forKey: .activeProviderId)
        let list = ((try? c.decode([Failable<ProviderConfig>].self, forKey: .providers)) ?? []).compactMap(\.value)
        providers = list.isEmpty ? d.providers : list
    }

    /// Copia senza intestazioni (token, chiavi): da usare per esportare o pubblicare.
    var withoutSecrets: AppConfig {
        var copy = self
        copy.providers = providers.map { var p = $0; p.headers = [:]; return p }
        return copy
    }

    func jsonString(pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let item: MediaItem
    let episode: Episode?
    let episodeLabel: String?
}
