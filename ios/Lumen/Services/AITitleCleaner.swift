import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Abbinamento più intelligente della playlist: i nomi che il catalogo non riconosce (sigle, tag,
/// titoli scritti male o in altre lingue) vengono "ripuliti" da Apple Intelligence e cercati di nuovo.
extension LinkMapper {
    /// Massimo di titoli da far rileggere per analisi (il modello sul telefono è veloce ma non istantaneo).
    static let aiRescueLimit = 3000
    static let aiBatch = 15

    func aiRescue(_ grouped: Grouped, tmdb: TMDBProvider, gen: Int) async {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), LumenAssistant.unavailableReason == nil else { return }
        // Titoli senza scheda e non ancora riletti
        var todo: [(key: String, raw: String, series: Bool)] = []
        var seen = Set<String>()
        for s in grouped.series {
            let k = Self.key(series: s)
            guard cache[k] != nil, cache[k]?.item == nil, cache["ai|" + k] == nil, seen.insert(k).inserted else { continue }
            todo.append((k, s.episodes.values.first?.title ?? s.name, true))
        }
        for m in grouped.movies {
            let k = Self.key(movie: m.parsed)
            guard cache[k] != nil, cache[k]?.item == nil, cache["ai|" + k] == nil, seen.insert(k).inserted else { continue }
            todo.append((k, m.media.title, false))
        }
        guard !todo.isEmpty else { return }
        todo = Array(todo.prefix(Self.aiRescueLimit))
        total += todo.count
        phaseLabel = "Apple Intelligence: rilettura dei titoli non riconosciuti"
        onProgress?()

        var start = 0
        while start < todo.count {
            if cancelled || gen != generation { return }
            let batch = Array(todo[start..<min(start + Self.aiBatch, todo.count)])
            start += batch.count
            let cleaned = await Self.clean(batch.map { ($0.raw, $0.series) })
            if cancelled || gen != generation { return }
            // Nuove ricerche in parallelo
            await withTaskGroup(of: (String, MediaItem?).self) { group in
                for (i, entry) in batch.enumerated() {
                    guard let c = cleaned[i], !c.title.isEmpty else { continue }
                    let year = c.year > 1900 ? c.year : nil
                    group.addTask { (entry.key, try? await tmdb.match(title: c.title, year: year, series: entry.series || c.isSeries)) }
                }
                for await (key, item) in group where item != nil { cache[key] = CachedMatch(item: item) }
            }
            for entry in batch { cache["ai|" + entry.key] = CachedMatch(item: nil) }   // riletto: non ripetere
            done += batch.count
            onProgress?()
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func clean(_ names: [(String, Bool)]) async -> [Int: CleanTitle] {
        let list = names.enumerated().map { "\($0.offset). \($0.element.0)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        Ricevi nomi di voci di una playlist video (film e serie TV), spesso con sigle di paese, lingua, qualità,
        numeri di stagione/episodio, anni o errori di battitura. Per ogni voce restituisci il titolo ufficiale
        del film o della serie com'è conosciuto (in italiano o in originale), senza tag, sigle, qualità o episodi,
        l'anno di uscita se lo conosci (0 se non lo sai) e se è una serie TV. Mantieni lo stesso numero (index).
        """)
        do {
            let r = try await session.respond(to: list, generating: CleanTitles.self, options: GenerationOptions(temperature: 0))
            var out: [Int: CleanTitle] = [:]
            for t in r.content.items where t.index >= 0 && t.index < names.count { out[t.index] = t }
            return out
        } catch {
            return [:]   // blocco non elaborabile (es. contenuti filtrati): resta senza scheda
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct CleanTitles {
    @Guide(description: "Un elemento per ogni voce ricevuta, con lo stesso index")
    var items: [CleanTitle]
}

@available(iOS 26.0, *)
@Generable
struct CleanTitle {
    @Guide(description: "Il numero della voce, uguale a quello ricevuto")
    var index: Int
    @Guide(description: "Titolo ufficiale pulito, senza sigle, tag di qualità o lingua, senza stagione o episodio")
    var title: String
    @Guide(description: "Anno di uscita, 0 se non noto")
    var year: Int
    @Guide(description: "true se è una serie TV")
    var isSeries: Bool
}
#endif

/// "Dove eravamo rimasti": riassunto con Apple Intelligence degli episodi visti di una serie,
/// fino all'ultimo episodio guardato, senza anticipare nulla di quelli successivi.
@MainActor
enum SeriesRecap {
    private static var cache: [String: String] = [:]

    /// Ultimo episodio visto (stagione, episodio) in base a "Visto" sugli episodi.
    static func lastWatched(seriesId: String, library: Library) -> (season: Int, episode: Int)? {
        let keys = library.seriesWatch[seriesId].map { Array($0.episodes.keys) } ?? []
        let pairs = keys.compactMap { id -> (Int, Int)? in
            guard let r = id.range(of: #"s(\d+)e(\d+)$"#, options: .regularExpression) else { return nil }
            let nums = id[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return nums.count == 2 ? (nums[0], nums[1]) : nil
        }
        return pairs.max { ($0.0, $0.1) < ($1.0, $1.1) }.map { (season: $0.0, episode: $0.1) }
    }

    static func cached(seriesId: String, upTo: (season: Int, episode: Int)) -> String? {
        cache["\(seriesId)|\(upTo.season)|\(upTo.episode)"]
    }

    static func generate(title: String, seriesId: String, detail: MediaDetail, upTo: (season: Int, episode: Int)) async throws -> String {
        let key = "\(seriesId)|\(upTo.season)|\(upTo.episode)"
        if let c = cache[key] { return c }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw RecapError.unavailable }
        if let reason = LumenAssistant.unavailableReason { throw RecapError.message(reason) }
        // Trame degli episodi fino a quello visto (le più recenti contano di più: ultime ~28)
        var lines: [String] = []
        for season in detail.seasons.sorted(by: { $0.number < $1.number }) where season.number > 0 && season.number <= upTo.season {
            for ep in season.episodes.sorted(by: { $0.number < $1.number }) {
                if season.number == upTo.season && ep.number > upTo.episode { break }
                guard let o = ep.overview, !o.isEmpty else { continue }
                lines.append("S\(season.number)E\(ep.number) \(ep.title): \(String(o.prefix(260)))")
            }
        }
        guard !lines.isEmpty else { throw RecapError.message("Non ci sono trame degli episodi da riassumere per questa serie.") }
        let text = lines.suffix(28).joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        Sei l'assistente di Lumen. Scrivi in italiano un riassunto chiaro e scorrevole, al massimo 130 parole,
        di cosa è successo nella serie fino all'episodio indicato, per aiutare chi riprende la visione.
        Usa solo le informazioni fornite. Non anticipare nulla degli episodi successivi. Niente elenchi puntati.
        """)
        let r = try await session.respond(to: "Serie: \(title). Ultimo episodio visto: S\(upTo.season)E\(upTo.episode).\nTrame:\n\(text)",
                                          options: GenerationOptions(temperature: 0.2))
        let out = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[key] = out
        return out
        #else
        throw RecapError.unavailable
        #endif
    }

    enum RecapError: LocalizedError {
        case unavailable, message(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Serve iOS 26 con Apple Intelligence."
            case .message(let m): return m
            }
        }
    }
}
