import Foundation
import Observation

/// Proposta di abbinamento di un film del link a un titolo del catalogo.
struct MovieProposal: Identifiable, Hashable, Codable {
    var id: String { media.id }
    var media: LinkMedia
    var parsed: ParsedTitle
    var match: MediaItem?
}

/// Serie ricostruita raggruppando per nome gli episodi del link.
struct SeriesProposal: Identifiable, Hashable, Codable {
    var id: String { key }
    var key: String
    var name: String
    var year: Int?
    /// "s1e2" → video
    var episodes: [String: LinkMedia]
    var poster: URL?
    var match: MediaItem?

    var seasons: [Int] {
        Array(Set(episodes.keys.compactMap { k in Int(k.dropFirst().prefix { $0.isNumber }) })).sorted()
    }
}

/// Un abbinamento già cercato nel catalogo (trovato o no). Gli errori di rete non vengono memorizzati,
/// così alla ripresa quei titoli vengono cercati di nuovo.
struct CachedMatch: Codable, Hashable {
    var item: MediaItem?
}

/// Prepara le proposte (film e serie) cercandole nel catalogo PRIMA dell'importazione.
/// Le ricerche già fatte restano in `cache`: se il lavoro si interrompe, riprende da dove era rimasto.
@MainActor
@Observable
final class LinkMapper {
    var movies: [MovieProposal] = []
    var series: [SeriesProposal] = []
    var lives: [LinkMedia] = []
    var isMapping = false
    var done = 0
    var total = 0
    var cache: [String: CachedMatch] = [:]
    @ObservationIgnored var onProgress: (@MainActor () -> Void)?
    @ObservationIgnored private(set) var cancelled = false
    @ObservationIgnored private var generation = 0

    func reset() {
        movies = []; series = []; lives = []; done = 0; total = 0; cancelled = true; cache = [:]; generation += 1; isMapping = false
    }

    func cancel() { cancelled = true; generation += 1; isMapping = false }

    /// true se tutte le ricerche sono state completate (nessuna interrotta o fallita per la rete).
    var isComplete: Bool {
        series.allSatisfy { cache[Self.key(series: $0)] != nil } && movies.allSatisfy { cache[Self.key(movie: $0.parsed)] != nil }
    }

    static func key(series s: SeriesProposal) -> String { "s|\(s.name.lowercased())|\(s.year ?? 0)" }
    static func key(movie p: ParsedTitle) -> String { "m|\(p.title.lowercased())|\(p.year ?? 0)" }

    /// Divide i contenuti in film / serie / live e cerca ogni titolo nel catalogo.
    func prepare(_ items: [LinkMedia], tmdb: TMDBProvider?) async {
        generation += 1
        let gen = generation
        cancelled = false
        lives = items.filter(\.isLive)
        var movieList: [MovieProposal] = []
        var groups: [String: SeriesProposal] = [:]
        var order: [String] = []
        for m in items where !m.isLive {
            let p = ParsedTitle.parse(m.title)
            if let s = p.season, let e = p.episode {
                let key = p.title.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
                if groups[key] == nil {
                    groups[key] = SeriesProposal(key: key, name: p.title, year: p.year, episodes: [:], poster: m.poster)
                    order.append(key)
                }
                groups[key]?.episodes["s\(s)e\(e)"] = m
                if groups[key]?.poster == nil { groups[key]?.poster = m.poster }
            } else {
                movieList.append(MovieProposal(media: m, parsed: p))
            }
        }
        // Applica subito quanto già trovato in precedenza.
        movies = movieList.map { var m = $0; m.match = cache[Self.key(movie: m.parsed)]?.item; return m }
        series = order.compactMap { groups[$0] }.map { var s = $0; s.match = cache[Self.key(series: s)]?.item; return s }

        guard let tmdb else { return }
        isMapping = true
        defer { if gen == generation { isMapping = false; onProgress?() } }
        total = movies.count + series.count
        done = 0

        // Serie: una ricerca per serie
        for i in series.indices {
            if cancelled || gen != generation { return }
            let k = Self.key(series: series[i])
            if let hit = cache[k] {
                series[i].match = hit.item
            } else {
                do {
                    let found = try await tmdb.match(title: series[i].name, year: series[i].year, series: true)
                    guard gen == generation else { return }
                    cache[k] = CachedMatch(item: found)
                    series[i].match = found
                } catch {
                    if gen != generation { return }
                    // rete assente o app sospesa: il titolo verrà ricercato alla ripresa
                }
            }
            done += 1
            if done % 20 == 0 { onProgress?() }
        }
        // Film: una ricerca per titolo (con cache per i doppioni)
        for i in movies.indices {
            if cancelled || gen != generation { return }
            let k = Self.key(movie: movies[i].parsed)
            if let hit = cache[k] {
                movies[i].match = hit.item
            } else {
                do {
                    let found = try await tmdb.match(title: movies[i].parsed.title, year: movies[i].parsed.year, series: false)
                    guard gen == generation else { return }
                    cache[k] = CachedMatch(item: found)
                    movies[i].match = found
                } catch {
                    if gen != generation { return }
                    // rete assente o app sospesa: il titolo verrà ricercato alla ripresa
                }
            }
            done += 1
            if done % 20 == 0 { onProgress?() }
        }
    }
}

extension LinkLibrary {
    /// Importa le proposte già abbinate (senza nuove ricerche).
    func applyMapping(movies: [MovieProposal], series: [SeriesProposal], lives: [LinkMedia]) {
        var unmatched: [LinkMedia] = lives
        for m in movies {
            if let item = m.match { setMovieLink(m.media, for: item) } else { unmatched.append(m.media) }
        }
        for s in series {
            if let item = s.match { setEpisodeLinks(s.episodes, for: item) } else { unmatched.append(contentsOf: s.episodes.values) }
        }
        add(unmatched)
    }
}
