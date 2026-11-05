import Foundation

/// Catalogo completo di film e serie da The Movie Database (API ufficiale, chiave gratuita):
/// trame in italiano, cast, voti, generi, stagioni ed episodi, trailer e servizi su cui guardarli.
/// Facoltativo: con una chiave OMDb mostra anche il voto IMDb.
struct TMDBProvider: ContentProvider {
    let config: ProviderConfig

    private var key: String { config.option("tmdbKey") }
    private var omdbKey: String { config.option("omdbKey") }
    private var language: String { config.option("language").isEmpty ? "it-IT" : config.option("language") }
    private var region: String { config.option("region").isEmpty ? "IT" : config.option("region") }
    private var base: String {
        let b = config.baseURL.trimmingCharacters(in: .whitespaces)
        return b.isEmpty ? "https://api.themoviedb.org/3" : (b.hasSuffix("/") ? String(b.dropLast()) : b)
    }

    var capabilities: ProviderCapabilities { ProviderCapabilities(streams: false, clips: false, browse: true) }

    // MARK: Home

    func home() async throws -> HomeFeed {
        guard !key.isEmpty else { throw TMDBError.missingKey }
        let genres = try await genreMap()

        struct Spec { let id, title, style, path: String; var query: [String: String] = [:]; var kind: MediaKind?; var badge: String?; var limit = 20 }
        let specs: [Spec] = [
            Spec(id: "trending", title: "Di tendenza questa settimana", style: "poster", path: "/trending/all/week"),
            Spec(id: "top10", title: "La Top 10 dei film di oggi", style: "top10", path: "/trending/movie/day", kind: .movie, limit: 10),
            Spec(id: "tv-popular", title: "Serie TV popolari", style: "large", path: "/tv/popular", kind: .series),
            Spec(id: "cinema", title: "Ora al cinema", style: "wide", path: "/movie/now_playing", query: ["region": region], kind: .movie, badge: "Al cinema"),
            Spec(id: "movie-popular", title: "Film popolari", style: "poster", path: "/movie/popular", kind: .movie),
            Spec(id: "tv-top10", title: "La Top 10 delle serie di oggi", style: "top10", path: "/trending/tv/day", kind: .series, limit: 10),
            Spec(id: "tv-top", title: "Serie TV più votate", style: "poster", path: "/tv/top_rated", kind: .series),
            Spec(id: "movie-top", title: "Film più votati di sempre", style: "poster", path: "/movie/top_rated", kind: .movie),
            Spec(id: "anime", title: "Anime e ispirati agli anime", style: "poster", path: "/discover/tv",
                 query: ["with_genres": "16", "with_original_language": "ja", "sort_by": "popularity.desc"], kind: .series),
            Spec(id: "animation", title: "Animazione per tutti", style: "poster", path: "/discover/movie",
                 query: ["with_genres": "16", "sort_by": "popularity.desc"], kind: .movie),
            Spec(id: "comedy", title: "Commedie", style: "poster", path: "/discover/movie",
                 query: ["with_genres": "35", "sort_by": "popularity.desc"], kind: .movie),
            Spec(id: "scifi", title: "Fantascienza e fantasy", style: "poster", path: "/discover/tv",
                 query: ["with_genres": "10765", "sort_by": "popularity.desc"], kind: .series),
            Spec(id: "horror", title: "Horror e brividi", style: "poster", path: "/discover/movie",
                 query: ["with_genres": "27", "sort_by": "popularity.desc"], kind: .movie),
            Spec(id: "crime", title: "Crime e thriller", style: "poster", path: "/discover/tv",
                 query: ["with_genres": "80", "sort_by": "popularity.desc"], kind: .series),
            Spec(id: "docs", title: "Documentari", style: "wide", path: "/discover/movie",
                 query: ["with_genres": "99", "sort_by": "popularity.desc"], kind: .movie),
            Spec(id: "docs-tv", title: "Docuserie", style: "poster", path: "/discover/tv",
                 query: ["with_genres": "99", "sort_by": "popularity.desc"], kind: .series),
            Spec(id: "docs-crime", title: "Documentari true crime", style: "poster", path: "/discover/tv",
                 query: ["with_genres": "99,80", "sort_by": "popularity.desc"], kind: .series),
            Spec(id: "docs-history", title: "Documentari di storia", style: "poster", path: "/discover/movie",
                 query: ["with_genres": "99,36", "sort_by": "popularity.desc"], kind: .movie),
            Spec(id: "docs-music", title: "Documentari musicali", style: "poster", path: "/discover/movie",
                 query: ["with_genres": "99,10402", "sort_by": "popularity.desc"], kind: .movie),
            Spec(id: "upcoming", title: "Prossimamente", style: "wide", path: "/movie/upcoming", query: ["region": region], kind: .movie, badge: "In arrivo"),
        ]

        let results: [(Int, CatalogSection)] = await withTaskGroup(of: (Int, CatalogSection)?.self) { group in
            for (index, spec) in specs.enumerated() {
                group.addTask {
                    guard let json = try? await self.get(spec.path, spec.query),
                          let list = json["results"] as? [[String: Any]] else { return nil }
                    var items = list.compactMap { self.item(from: $0, kind: spec.kind, genres: genres) }
                        .filter { $0.poster != nil }
                    items = Array(items.prefix(spec.limit))
                    if spec.style == "top10" { items = items.enumerated().map { var i = $0.element; i.rank = $0.offset + 1; return i } }
                    if let badge = spec.badge { items = items.map { var i = $0; i.badge = badge; return i } }
                    guard !items.isEmpty else { return nil }
                    var section = CatalogSection(id: spec.id, title: spec.title, style: spec.style, items: items)
                    section.source = SectionSource(path: spec.path, query: spec.query, kind: spec.kind, badge: spec.badge)
                    return (index, section)
                }
            }
            var out: [(Int, CatalogSection)] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        let sections = results.sorted { $0.0 < $1.0 }.map(\.1)
        guard !sections.isEmpty else { throw TMDBError.unreachable }
        let hero = sections.first?.items.first { $0.backdrop != nil }
        return HomeFeed(hero: hero, sections: sections)
    }

    /// Una pagina del catalogo completo di una categoria della home ("Mostra tutto").
    func sectionPage(_ source: SectionSource, page: Int) async throws -> BrowsePage {
        guard !key.isEmpty else { throw TMDBError.missingKey }
        let genres = try await genreMap()
        var query = source.query
        query["page"] = String(page)
        if source.path.hasPrefix("/discover") { query["include_adult"] = "false" }
        let json = try await get(source.path, query)
        let list = json["results"] as? [[String: Any]] ?? []
        let total = min(500, json["total_pages"] as? Int ?? page)
        var items = list.compactMap { item(from: $0, kind: source.kind, genres: genres) }.filter { $0.poster != nil }
        if let badge = source.badge { items = items.map { var i = $0; i.badge = badge; return i } }
        return BrowsePage(items: items, page: page, totalPages: total)
    }

    // MARK: Ricerca

    func search(_ query: String) async throws -> [MediaItem] {
        guard !key.isEmpty else { throw TMDBError.missingKey }
        let genres = try await genreMap()
        let json = try await get("/search/multi", ["query": query, "include_adult": "false"])
        let list = json["results"] as? [[String: Any]] ?? []
        return list.compactMap { item(from: $0, kind: nil, genres: genres) }
    }

    // MARK: Abbinamento per titolo (contenuti da link)

    /// Cerca un titolo nel catalogo; prova prima con l'anno, poi senza.
    func match(title: String, year: Int?, series: Bool) async throws -> MediaItem? {
        guard !key.isEmpty, title.count >= 2 else { return nil }
        let genres = try await genreMap()
        let path = series ? "/search/tv" : "/search/movie"
        var attempts: [[String: String]] = []
        if let year {
            attempts.append(["query": title, series ? "first_air_date_year" : "year": String(year)])
        }
        attempts.append(["query": title])
        for query in attempts {
            let json = try await get(path, query.merging(["include_adult": "false"]) { a, _ in a })
            let list = json["results"] as? [[String: Any]] ?? []
            if let first = list.first, let item = item(from: first, kind: series ? .series : .movie, genres: genres) {
                return item
            }
        }
        // Se il tipo indovinato era sbagliato, prova l'altro.
        if !series, year == nil {
            let json = try await get("/search/tv", ["query": title])
            if let first = (json["results"] as? [[String: Any]])?.first {
                return item(from: first, kind: .series, genres: genres)
            }
        }
        return nil
    }

    // MARK: Catalogo completo

    func genres(kind: MediaKind) async throws -> [Genre] {
        guard !key.isEmpty else { throw TMDBError.missingKey }
        let json = try await get(kind == .movie ? "/genre/movie/list" : "/genre/tv/list")
        return (json["genres"] as? [[String: Any]] ?? []).compactMap { g in
            guard let id = g["id"], let name = g["name"] as? String else { return nil }
            return Genre(id: "\(id)", name: name.prefix(1).uppercased() + name.dropFirst())
        }
    }

    func browse(kind: MediaKind, genre: String?, sort: BrowseSort, page: Int) async throws -> BrowsePage {
        guard !key.isEmpty else { throw TMDBError.missingKey }
        let genres = try await genreMap()
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var query = ["page": String(page), "include_adult": "false"]
        switch sort {
        case .popular:
            query["sort_by"] = "popularity.desc"
        case .topRated:
            query["sort_by"] = "vote_average.desc"
            query["vote_count.gte"] = kind == .movie ? "500" : "200"
        case .newest:
            query["sort_by"] = kind == .movie ? "primary_release_date.desc" : "first_air_date.desc"
            query[kind == .movie ? "primary_release_date.lte" : "first_air_date.lte"] = today
            query["vote_count.gte"] = "10"
        }
        if let genre, !genre.isEmpty { query["with_genres"] = genre }
        let json = try await get(kind == .movie ? "/discover/movie" : "/discover/tv", query)
        let list = json["results"] as? [[String: Any]] ?? []
        let total = min(500, json["total_pages"] as? Int ?? page)
        return BrowsePage(items: list.compactMap { item(from: $0, kind: kind, genres: genres) },
                          page: page, totalPages: total)
    }

    // MARK: Dettaglio

    func detail(id: String) async throws -> MediaDetail {
        guard !key.isEmpty else { throw TMDBError.missingKey }
        let (kind, tmdbId) = try Self.split(id)
        let isMovie = kind == .movie
        let append = isMovie
            ? "credits,videos,watch/providers,release_dates"
            : "credits,videos,watch/providers,content_ratings,external_ids"
        let json = try await get("/\(isMovie ? "movie" : "tv")/\(tmdbId)",
                                 ["append_to_response": append,
                                  "include_video_language": "\(language.prefix(2)),en,null"])

        let genreNames = (json["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        guard var base = item(from: json, kind: kind, genres: [:]) else { throw ProviderError.notFound }
        base.tags = Array(genreNames.prefix(3))

        // Classificazione per età
        if isMovie {
            let countries = (json["release_dates"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            base.rating = certification(countries, key: "release_dates", field: "certification")
        } else {
            let countries = (json["content_ratings"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            let local = countries.first { $0["iso_3166_1"] as? String == region }?["rating"] as? String
            let us = countries.first { $0["iso_3166_1"] as? String == "US" }?["rating"] as? String
            base.rating = [local, us].compactMap { $0 }.first { !$0.isEmpty }
        }

        // Cast e regia
        let credits = json["credits"] as? [String: Any] ?? [:]
        let cast: [CastMember] = (credits["cast"] as? [[String: Any]] ?? []).prefix(15).compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            return CastMember(name: name, character: (c["character"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              photo: image(c["profile_path"], size: "w185"))
        }
        var director: String?
        if isMovie {
            director = (credits["crew"] as? [[String: Any]] ?? []).first { $0["job"] as? String == "Director" }?["name"] as? String
        } else {
            director = (json["created_by"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.first
        }

        // Trailer (YouTube)
        let videos = (json["videos"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        let youtube = videos.filter { $0["site"] as? String == "YouTube" }
        let best = youtube.first { $0["type"] as? String == "Trailer" && ($0["iso_639_1"] as? String) == String(language.prefix(2)) }
            ?? youtube.first { $0["type"] as? String == "Trailer" }
            ?? youtube.first { $0["type"] as? String == "Teaser" }
        let trailer = (best?["key"] as? String).flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }

        // Dove guardarlo (dati JustWatch forniti da TMDB)
        let providersRoot = ((json["watch/providers"] as? [String: Any])?["results"] as? [String: Any])?[region] as? [String: Any] ?? [:]
        var watch: [WatchProvider] = []
        for type in ["flatrate", "free", "ads", "rent", "buy"] {
            for p in providersRoot[type] as? [[String: Any]] ?? [] {
                guard let name = p["provider_name"] as? String, !watch.contains(where: { $0.name == name }) else { continue }
                watch.append(WatchProvider(name: name, logo: image(p["logo_path"], size: "w154"), type: type))
            }
        }
        let watchLink = (providersRoot["link"] as? String).flatMap(URL.init(string:))

        // Stagioni ed episodi (serie)
        var seasons: [Season] = []
        if !isMovie {
            let numbers = (json["seasons"] as? [[String: Any]] ?? [])
                .compactMap { $0["season_number"] as? Int }
                .filter { $0 > 0 }
                .prefix(25)
            seasons = await withTaskGroup(of: Season?.self) { group in
                for n in numbers {
                    group.addTask { try? await self.season(tvId: tmdbId, number: n) }
                }
                var out: [Season] = []
                for await s in group { if let s, !s.episodes.isEmpty { out.append(s) } }
                return out.sorted { $0.number < $1.number }
            }
        }

        // Voto IMDb (facoltativo, via OMDb)
        let imdbId = (json["imdb_id"] as? String) ?? ((json["external_ids"] as? [String: Any])?["imdb_id"] as? String)
        var imdbRating: String?
        if let imdbId, !imdbId.isEmpty, !omdbKey.isEmpty {
            imdbRating = try? await omdbRating(imdbId)
        }

        let runtime = (json["runtime"] as? Int) ?? (json["episode_run_time"] as? [Int])?.first
        var detail = MediaDetail(item: base, seasons: seasons, cast: cast, duration: runtime.map { $0 * 60 },
                                 genres: genreNames, director: director, trailer: trailer, imdbId: imdbId,
                                 imdbRating: imdbRating, watchProviders: watch, watchLink: watchLink)
        detail.releases = isMovie ? movieReleases(json) : seriesReleases(json)
        // Saga (Harry Potter, Il Signore degli Anelli, …): tutti i film in ordine di uscita.
        if isMovie, let coll = json["belongs_to_collection"] as? [String: Any], let cid = coll["id"] as? Int,
           let cjson = try? await get("/collection/\(cid)") {
            let genres = (try? await genreMap()) ?? [:]
            let parts = (cjson["parts"] as? [[String: Any]] ?? []).sorted {
                let a = $0["release_date"] as? String ?? "", b = $1["release_date"] as? String ?? ""
                return (a.isEmpty ? "9999" : a) < (b.isEmpty ? "9999" : b)
            }
            let items = parts.compactMap { item(from: $0, kind: .movie, genres: genres) }
            if items.count > 1 {
                detail.collectionName = (cjson["name"] as? String) ?? (coll["name"] as? String)
                detail.collection = items
            }
        }
        return detail
    }

    // MARK: Date di uscita

    private static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    private func countryName(_ code: String) -> String {
        Locale(identifier: "it_IT").localizedString(forRegionCode: code) ?? code
    }

    /// Uscita al cinema nel paese dell'app (Italia), prima uscita mondiale e uscita in digitale.
    /// Tipi TMDB: 1 anteprima, 2 cinema limitata, 3 cinema, 4 digitale, 5 home video, 6 TV.
    private func movieReleases(_ json: [String: Any]) -> [ReleaseInfo] {
        let countries = (json["release_dates"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        func dates(_ country: [String: Any], types: Set<Int>) -> [Date] {
            (country["release_dates"] as? [[String: Any]] ?? [])
                .filter { types.contains($0["type"] as? Int ?? 0) }
                .compactMap { Self.parseDate($0["release_date"]) }
        }
        var out: [ReleaseInfo] = []
        let local = countries.first { $0["iso_3166_1"] as? String == region }
        let localName = countryName(region)
        let localCinema: Date? = local.flatMap { dates($0, types: [3]).min() ?? dates($0, types: [2]).min() }
        if let d = localCinema {
            out.append(ReleaseInfo(label: "Al cinema in \(localName)", date: d, icon: "ticket.fill"))
        }
        // Prima uscita al cinema nel mondo
        var first: (Date, String)?
        for c in countries {
            guard let code = c["iso_3166_1"] as? String, let d = (dates(c, types: [3]).min() ?? dates(c, types: [2]).min()) else { continue }
            if first == nil || d < first!.0 { first = (d, code) }
        }
        if let f = first, localCinema == nil || abs(f.0.timeIntervalSince(localCinema!)) > 86_400 * 2 {
            out.append(ReleaseInfo(label: "Prima uscita al cinema (\(countryName(f.1)))", date: f.0, icon: "globe.europe.africa.fill"))
        }
        if out.isEmpty, let d = Self.parseDate(json["release_date"]) {
            out.append(ReleaseInfo(label: "Data di uscita", date: d, icon: "ticket.fill"))
        }
        if let d = local.flatMap({ dates($0, types: [4]).min() }) {
            out.append(ReleaseInfo(label: "In digitale in \(localName)", date: d, icon: "play.rectangle.fill"))
        }
        return out
    }

    private func seriesReleases(_ json: [String: Any]) -> [ReleaseInfo] {
        var out: [ReleaseInfo] = []
        if let d = Self.parseDate(json["first_air_date"]) {
            out.append(ReleaseInfo(label: "Prima messa in onda", date: d, icon: "tv.fill"))
        }
        if let next = json["next_episode_to_air"] as? [String: Any], let d = Self.parseDate(next["air_date"]) {
            let s = next["season_number"] as? Int ?? 0, e = next["episode_number"] as? Int ?? 0
            out.append(ReleaseInfo(label: "Prossimo episodio (S\(s) E\(e))", date: d, icon: "calendar.badge.clock"))
        } else if let d = Self.parseDate(json["last_air_date"]), (json["in_production"] as? Bool) == false {
            out.append(ReleaseInfo(label: "Ultimo episodio", date: d, icon: "flag.checkered"))
        }
        return out
    }

    func streams(id: String, episodeId: String?) async throws -> [StreamSource] {
        throw ProviderError.catalogOnly
    }

    func clips() async throws -> [Clip] {
        throw ProviderError.notSupported
    }

    // MARK: Supporto

    private func season(tvId: String, number: Int) async throws -> Season {
        let json = try await get("/tv/\(tvId)/season/\(number)")
        let episodes: [[String: Any]] = (json["episodes"] as? [[String: Any]] ?? []).map { (e: [String: Any]) -> [String: Any] in
            [
                "id": "tv-\(tvId)-s\(number)e\(e["episode_number"] as? Int ?? 0)",
                "number": e["episode_number"] as? Int ?? 0,
                "title": e["name"] as? String ?? "",
                "overview": (e["overview"] as? String) ?? "",
                "still": image(e["still_path"], size: "w300")?.absoluteString ?? "",
                "duration": ((e["runtime"] as? Int) ?? 0) * 60,
            ]
        }
        let payload: [String: Any] = [
            "id": "s\(number)", "number": number,
            "title": json["name"] as? String ?? "Stagione \(number)",
            "episodes": episodes,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(Season.self, from: data)
    }

    private func certification(_ countries: [[String: Any]], key: String, field: String) -> String? {
        for code in [region, "US"] {
            if let c = countries.first(where: { $0["iso_3166_1"] as? String == code }),
               let dates = c[key] as? [[String: Any]],
               let cert = dates.compactMap({ $0[field] as? String }).first(where: { !$0.isEmpty }) {
                return cert
            }
        }
        return nil
    }

    private func omdbRating(_ imdbId: String) async throws -> String? {
        var comps = URLComponents(string: "https://www.omdbapi.com/")!
        comps.queryItems = [URLQueryItem(name: "i", value: imdbId), URLQueryItem(name: "apikey", value: omdbKey)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let r = json?["imdbRating"] as? String, r != "N/A" else { return nil }
        return r
    }

    func item(from j: [String: Any], kind fallback: MediaKind?, genres: [Int: String]) -> MediaItem? {
        let mediaType = j["media_type"] as? String
        let kind: MediaKind
        switch mediaType {
        case "movie"?: kind = .movie
        case "tv"?: kind = .series
        case .some: return nil   // persone e altri risultati
        case .none: kind = fallback ?? (j["first_air_date"] != nil || j["name"] != nil && j["title"] == nil ? .series : .movie)
        }
        guard let idValue = j["id"], let title = (j["title"] ?? j["name"]) as? String else { return nil }
        let date = (j["release_date"] ?? j["first_air_date"]) as? String ?? ""
        let ids = j["genre_ids"] as? [Int] ?? []
        let overview = (j["overview"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return MediaItem(
            id: "\(kind == .movie ? "movie" : "tv")-\(idValue)",
            title: title,
            kind: kind,
            poster: image(j["poster_path"], size: "w342"),
            backdrop: image(j["backdrop_path"], size: "w780"),
            overview: overview,
            year: Int(date.prefix(4)),
            tags: ids.isEmpty ? nil : Array(ids.compactMap { genres[$0] }.prefix(3)),
            score: (j["vote_average"] as? Double) ?? (j["vote_average"] as? Int).map(Double.init)
        )
    }

    private func image(_ path: Any?, size: String) -> URL? {
        guard let p = path as? String, !p.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(p)")
    }

    static func split(_ id: String) throws -> (MediaKind, String) {
        if id.hasPrefix("movie-") { return (.movie, String(id.dropFirst(6))) }
        if id.hasPrefix("tv-") { return (.series, String(id.dropFirst(3))) }
        throw ProviderError.notFound
    }

    private func genreMap() async throws -> [Int: String] {
        if let cached = await TMDBCache.shared.genres(for: language) { return cached }
        async let movies = get("/genre/movie/list")
        async let tv = get("/genre/tv/list")
        var map: [Int: String] = [:]
        let lists = try await [movies, tv]
        for json in lists {
            for g in json["genres"] as? [[String: Any]] ?? [] {
                if let id = g["id"] as? Int, let name = g["name"] as? String {
                    map[id] = name.prefix(1).uppercased() + name.dropFirst()
                }
            }
        }
        await TMDBCache.shared.store(map, for: language)
        return map
    }

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        guard var comps = URLComponents(string: base + path) else { throw ProviderError.invalidURL(base + path) }
        var items = [URLQueryItem(name: "language", value: language)]
        items += query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let bearer = key.hasPrefix("eyJ")
        if !bearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        comps.queryItems = items
        guard let url = comps.url else { throw ProviderError.invalidURL(path) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw TMDBError.invalidKey }
            if !(200..<300).contains(http.statusCode) { throw ProviderError.http(http.statusCode) }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Risposta TMDB inattesa")
        }
        return json
    }
}

enum TMDBError: LocalizedError {
    case missingKey, invalidKey, unreachable
    var errorDescription: String? {
        switch self {
        case .missingKey: return "Manca la chiave TMDB. L'amministratore può inserirla in Amministrazione → Sorgenti."
        case .invalidKey: return "La chiave TMDB non è valida."
        case .unreachable: return "Impossibile caricare il catalogo TMDB. Controlla la connessione."
        }
    }
}

actor TMDBCache {
    static let shared = TMDBCache()
    private var genres: [String: [Int: String]] = [:]
    func genres(for language: String) -> [Int: String]? { genres[language] }
    func store(_ map: [Int: String], for language: String) { genres[language] = map }
}
