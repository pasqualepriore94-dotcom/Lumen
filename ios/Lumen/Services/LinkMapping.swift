import Foundation
import Observation

/// Proposta di abbinamento di un film del link a un titolo del catalogo.
struct MovieProposal: Identifiable, Hashable {
    var id: String { media.id }
    var media: LinkMedia
    var parsed: ParsedTitle
    var match: MediaItem?
}

/// Serie ricostruita raggruppando per nome gli episodi del link.
struct SeriesProposal: Identifiable, Hashable {
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

/// Prepara le proposte (film e serie) cercandole nel catalogo PRIMA dell'importazione.
@MainActor
@Observable
final class LinkMapper {
    var movies: [MovieProposal] = []
    var series: [SeriesProposal] = []
    var lives: [LinkMedia] = []
    var isMapping = false
    var done = 0
    var total = 0
    @ObservationIgnored private var cancelled = false

    func reset() {
        movies = []; series = []; lives = []; done = 0; total = 0; cancelled = true
    }

    func cancel() { cancelled = true }

    /// Divide i contenuti in film / serie / live e cerca ogni titolo nel catalogo.
    func prepare(_ items: [LinkMedia], tmdb: TMDBProvider?) async {
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
        movies = movieList
        series = order.compactMap { groups[$0] }

        guard let tmdb else { return }
        isMapping = true
        defer { isMapping = false }
        total = movies.count + series.count
        done = 0

        // Serie: una ricerca per serie
        for i in series.indices {
            if cancelled { return }
            let s = series[i]
            series[i].match = try? await tmdb.match(title: s.name, year: s.year, series: true)
            done += 1
        }
        // Film: una ricerca per titolo (con cache per i doppioni)
        var cache: [String: MediaItem?] = [:]
        for i in movies.indices {
            if cancelled { return }
            let p = movies[i].parsed
            let key = "\(p.title.lowercased())|\(p.year ?? 0)"
            if let hit = cache[key] {
                movies[i].match = hit
            } else {
                let found = try? await tmdb.match(title: p.title, year: p.year, series: false)
                cache[key] = found
                movies[i].match = found
            }
            done += 1
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
