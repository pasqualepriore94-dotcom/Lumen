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
    @ObservationIgnored var generation = 0
    /// Fase in corso, per il contatore (es. riconoscimento con Apple Intelligence).
    var phaseLabel: String?

    /// `keepCache`: le ricerche già fatte nel catalogo restano valide anche per le analisi successive
    /// (rianalizzare la stessa playlist è quasi immediato).
    func reset(keepCache: Bool = true) {
        movies = []; series = []; lives = []; done = 0; total = 0; cancelled = true; generation += 1; isMapping = false
        if !keepCache { cache = [:] }
    }

    func cancel() { cancelled = true; generation += 1; isMapping = false }

    /// Toglie dai risultati ciò che è già stato importato (così non viene riproposto).
    func removeImported(_ linked: Set<String>) {
        movies.removeAll { linked.contains($0.media.id) }
        series.removeAll { $0.episodes.values.allSatisfy { linked.contains($0.id) } }
        lives.removeAll { linked.contains($0.id) }
    }

    /// Ricerche simultanee sul catalogo (TMDB accetta circa 40 richieste al secondo).
    static let parallelism = 8

    /// true se tutte le ricerche sono state completate (nessuna interrotta o fallita per la rete).
    var isComplete: Bool {
        series.allSatisfy { cache[Self.key(series: $0)] != nil } && movies.allSatisfy { cache[Self.key(movie: $0.parsed)] != nil }
    }

    nonisolated static func key(series s: SeriesProposal) -> String { "s|\(s.name.lowercased())|\(s.year ?? 0)" }
    nonisolated static func key(movie p: ParsedTitle) -> String { "m|\(p.title.lowercased())|\(p.year ?? 0)" }

    struct Grouped {
        var movies: [MovieProposal]
        var series: [SeriesProposal]
        var lives: [LinkMedia]
    }

    /// Divide in film / serie (episodi raggruppati per nome) / dirette. Lavoro solo locale, fuori dal thread principale.
    nonisolated static func group(_ items: [LinkMedia]) -> Grouped {
        var movieList: [MovieProposal] = []
        var groups: [String: SeriesProposal] = [:]
        var order: [String] = []
        var lives: [LinkMedia] = []
        for m in items {
            if m.isLive { lives.append(m); continue }
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
        return Grouped(movies: movieList, series: order.compactMap { groups[$0] }, lives: lives)
    }

    /// Ricostruisce le proposte (senza ricerche in rete) applicando gli abbinamenti già trovati.
    func rebuild(_ items: [LinkMedia]) async {
        let grouped = await Task.detached(priority: .userInitiated) { Self.group(items) }.value
        apply(grouped)
    }

    private func apply(_ g: Grouped) {
        let c = cache
        lives = g.lives
        movies = g.movies.map { var m = $0; m.match = c[Self.key(movie: m.parsed)]?.item; return m }
        series = g.series.map { var s = $0; s.match = c[Self.key(series: s)]?.item; return s }
    }

    private struct Query: Sendable {
        var key: String
        var title: String
        var year: Int?
        var series: Bool
    }

    private enum Lookup {
        case found(MediaItem?)
        case failed
    }

    nonisolated private static func lookup(_ q: Query, _ tmdb: TMDBProvider) async -> (String, Lookup) {
        do {
            return (q.key, .found(try await tmdb.match(title: q.title, year: q.year, series: q.series)))
        } catch {
            return (q.key, .failed)
        }
    }

    /// Divide i contenuti e cerca nel catalogo ogni titolo diverso una sola volta, con più ricerche in parallelo.
    func prepare(_ input: [LinkMedia], tmdb: TMDBProvider?) async {
        // Contenuti per adulti esclusi prima dell'analisi (se il filtro è attivo)
        let items = ContentFilter.enabled ? await Task.detached(priority: .userInitiated) { ContentFilter.apply(input) }.value : input
        generation += 1
        let gen = generation
        cancelled = false
        let grouped = await Task.detached(priority: .userInitiated) { Self.group(items) }.value
        guard gen == generation else { return }

        // Titoli diversi da cercare (le serie una volta sola, i film doppi una volta sola).
        var queries: [Query] = []
        var seen = Set<String>()
        var already = 0
        for s in grouped.series {
            let k = Self.key(series: s)
            guard seen.insert(k).inserted else { continue }
            if cache[k] != nil { already += 1 } else { queries.append(Query(key: k, title: s.name, year: s.year, series: true)) }
        }
        for m in grouped.movies {
            let k = Self.key(movie: m.parsed)
            guard seen.insert(k).inserted else { continue }
            if cache[k] != nil { already += 1 } else { queries.append(Query(key: k, title: m.parsed.title, year: m.parsed.year, series: false)) }
        }
        total = seen.count
        done = already

        phaseLabel = nil
        guard let tmdb else { apply(grouped); onProgress?(); return }
        isMapping = true
        onProgress?()

        if !queries.isEmpty { await withTaskGroup(of: (String, Lookup).self) { group in
            var next = queries.makeIterator()
            for _ in 0..<Self.parallelism {
                guard let q = next.next() else { break }
                group.addTask { await Self.lookup(q, tmdb) }
            }
            while let result = await group.next() {
                if cancelled || gen != generation { group.cancelAll(); return }
                if case .found(let item) = result.1 { cache[result.0] = CachedMatch(item: item) }
                // .failed (rete o limite di richieste): non memorizzato, verrà ricercato
                done += 1
                if done % 25 == 0 { onProgress?() }
                if let q = next.next() { group.addTask { await Self.lookup(q, tmdb) } }
            }
        } }
        guard gen == generation, !cancelled else { return }
        // Titoli rimasti senza scheda: Apple Intelligence ne ricava il nome pulito e si riprova.
        await aiRescue(grouped, tmdb: tmdb, gen: gen)
        guard gen == generation, !cancelled else { return }
        // Ancora senza scheda: confronto delle locandine
        await posterRescue(grouped, tmdb: tmdb, gen: gen)
        guard gen == generation, !cancelled else { return }
        phaseLabel = nil
        apply(grouped)
        isMapping = false
        onProgress?()
    }
}

extension LinkLibrary {
    /// Importa le proposte già abbinate (senza nuove ricerche), salvando una sola volta.
    func applyMapping(movies: [MovieProposal], series: [SeriesProposal], lives: [LinkMedia]) {
        var unmatched: [LinkMedia] = lives
        var movieLinks: [(LinkMedia, MediaItem)] = []
        var seriesLinks: [([String: LinkMedia], MediaItem)] = []
        for m in movies {
            if let item = m.match { movieLinks.append((m.media, item)) } else { unmatched.append(m.media) }
        }
        for s in series {
            if let item = s.match { seriesLinks.append((s.episodes, item)) } else { unmatched.append(contentsOf: s.episodes.values) }
        }
        applyBatch(movies: movieLinks, series: seriesLinks, unmatched: unmatched)
        Task { @MainActor in
            await autoAddCourses()
            await autoAddDocumentaries()
        }
    }
}
