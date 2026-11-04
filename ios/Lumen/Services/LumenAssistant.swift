import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Chiedi a Lumen": assistente con Apple Intelligence (modello sul telefono, iOS 26).
/// Capisce richieste a parole ("qualcosa di leggero da 90 minuti", "il film dell'astronauta su Marte"),
/// propone titoli reali spiegando il perché e indica quelli già disponibili nella tua playlist.
@MainActor
@Observable
final class LumenAssistant {
    struct Pick: Identifiable, Hashable {
        var id: String { item?.id ?? title + "|\(year ?? 0)" }
        var title: String
        var year: Int?
        var isSeries: Bool
        var reason: String
        var item: MediaItem?
        var available: Bool
    }

    enum State: Equatable {
        case idle, thinking, done, failed(String)
    }

    private(set) var state: State = .idle
    private(set) var intro = ""
    private(set) var picks: [Pick] = []
    /// Titoli il cui nome corrisponde a quanto scritto (ricerca classica, per chi scrive direttamente il titolo).
    private(set) var titleMatches: [Pick] = []
    /// Contenuti della tua playlist la cui trama o titolo contiene le parole della richiesta.
    private(set) var playlistMatches: [Pick] = []
    private(set) var lastQuestion = ""

    var hasResults: Bool { !picks.isEmpty || !titleMatches.isEmpty || !playlistMatches.isEmpty }

    /// nil se l'assistente è disponibile, altrimenti il motivo.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "Questo iPhone non supporta Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Attiva Apple Intelligence in Impostazioni → Apple Intelligence e Siri, poi riapri Lumen."
                case .modelNotReady:
                    return "Apple Intelligence sta ancora scaricando il modello: riprova tra qualche minuto (con Wi-Fi e in carica è più veloce)."
                @unknown default:
                    return "Apple Intelligence non è disponibile in questo momento."
                }
            }
        }
        #endif
        return "Serve iOS 26 con Apple Intelligence."
    }

    func ask(_ question: String, app: AppState, library: Library) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        lastQuestion = q
        intro = ""
        picks = []
        titleMatches = []
        playlistMatches = []
        state = .thinking
        let tmdb = app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }

        // 1) Se hai scritto un titolo: ricerca classica, subito.
        if let tmdb, let found = try? await tmdb.search(q) {
            titleMatches = Self.plausibleTitles(found, query: q).prefix(12).map(Self.pick)
        }
        // 2) Parole della richiesta nella tua playlist (titoli e trame).
        let taste = library.taste
        let catalog = Array(LinkLibrary.shared.matchedItems.values)
        let found = await Task.detached(priority: .userInitiated) { Self.searchPlaylist(q, items: catalog, taste: taste) }.value
        playlistMatches = found.map(Self.pick).filter { p in !titleMatches.contains { $0.id == p.id } }

        // 3) Apple Intelligence: suggerimenti a partire dalla descrizione.
        var aiError: String?
        if let reason = Self.unavailableReason {
            aiError = reason
        } else {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                do {
                    let session = LanguageModelSession(instructions: Self.instructions(library: library))
                    let response = try await session.respond(to: q, generating: AIPicks.self,
                                                             options: GenerationOptions(temperature: 0.3))
                    intro = response.content.intro
                    let known = Set(titleMatches.map(\.id))
                    picks = await resolve(response.content.picks, app: app).filter { !known.contains($0.id) }
                } catch {
                    aiError = Self.describe(error)
                }
            }
            #endif
        }
        if hasResults {
            state = .done
        } else {
            state = .failed(aiError ?? "Non ho trovato titoli adatti: prova a descrivere la richiesta in un altro modo.")
        }
    }

    // MARK: Ricerca per titolo e nella playlist

    /// Tiene i risultati il cui titolo somiglia davvero a quanto scritto (non le frasi descrittive).
    private static func plausibleTitles(_ items: [MediaItem], query: String) -> [MediaItem] {
        let q = norm(query)
        let qTokens = Set(q.split(separator: " ").map(String.init))
        guard !qTokens.isEmpty else { return [] }
        return items.filter { item in
            let t = norm(item.title)
            if t == q || t.hasPrefix(q) || q.hasPrefix(t) && t.count > 3 { return true }
            let tTokens = Set(t.split(separator: " ").map(String.init))
            let common = Double(qTokens.intersection(tTokens).count)
            return common / Double(qTokens.count) >= 0.6 && common / Double(max(1, tTokens.count)) >= 0.5
        }
    }

    private static func pick(_ item: MediaItem) -> Pick {
        let links = LinkLibrary.shared
        let available = links.link(forItem: item.id) != nil || links.episodeCount(seriesId: item.id) > 0
        return Pick(title: item.title, year: item.year, isSeries: item.isSeries,
                    reason: item.overview.map { String($0.prefix(140)) + ($0.count > 140 ? "…" : "") } ?? "",
                    item: item, available: available)
    }

    nonisolated private static let stopwords: Set<String> = [
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "di", "del", "della", "dei", "degli", "delle", "da", "dal",
        "in", "con", "su", "per", "tra", "fra", "che", "e", "o", "a", "al", "alla", "ai", "agli", "alle", "nel", "nella",
        "film", "serie", "qualcosa", "voglio", "vedere", "guardare", "stasera", "cosa", "dove", "quello", "quella", "come",
        "the", "of", "and", "molto", "piu", "più", "mi", "va", "tipo", "anni", "anno", "rimasto", "sono", "c", "è", "e'"
    ]

    /// Contenuti collegati (playlist) con le parole chiave della richiesta nel titolo o nella trama.
    nonisolated private static func searchPlaylist(_ query: String, items: [MediaItem], taste: TasteProfile) -> [MediaItem] {
        let words = norm(query).split(separator: " ").map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) }
        guard !words.isEmpty else { return [] }
        var scored: [(MediaItem, Double)] = []
        for item in items {
            let title = norm(item.title)
            let text = title + " " + norm(item.overview ?? "") + " " + norm((item.tags ?? []).joined(separator: " "))
            var score = 0.0
            for w in words {
                if title.contains(w) { score += 3 } else if text.contains(w) { score += 1 }
            }
            guard score >= Double(min(2, words.count)) else { continue }
            score += Double(taste.compatibility(item) ?? 50) / 100
            scored.append((item, score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
    }

    // MARK: Contesto per il modello

    private static func instructions(library: Library) -> String {
        let taste = library.taste
        let favorites = taste.top(5).map(\.genre).joined(separator: ", ")
        let seen = (library.watched.values.map(\.item) + library.seriesWatch.values.map(\.item))
            .map(\.title).prefix(25).joined(separator: "; ")
        // Titoli già guardabili in Lumen (dalla playlist), i più adatti ai gusti, per proporli quando pertinenti.
        let links = LinkLibrary.shared
        let candidates = links.matchedItems.values
            .sorted { (taste.compatibility($0) ?? 50) > (taste.compatibility($1) ?? 50) }
            .prefix(45)
            .map { "\($0.title)" + ($0.year.map { " (\($0))" } ?? "") }
            .joined(separator: "; ")
        return """
        Sei l'assistente di Lumen, un'app per guardare film e serie TV. Rispondi sempre in italiano.
        Proponi 10 film o serie TV reali ed esistenti, adatti alla richiesta dell'utente.
        Se l'utente scrive il titolo di un film o di una serie, metti per primo proprio quel titolo e poi titoli simili.
        Se l'utente descrive un titolo che non ricorda, metti per primo quello che corrisponde alla descrizione.
        Non inventare titoli. Indica l'anno corretto. Spiega in breve perché ogni titolo è adatto, senza spoiler.
        \(favorites.isEmpty ? "" : "Generi preferiti dell'utente: \(favorites).")
        \(seen.isEmpty ? "" : "Titoli già visti (non riproporli, salvo richiesta esplicita): \(seen).")
        \(candidates.isEmpty ? "" : "Titoli già disponibili da guardare in Lumen, da preferire quando sono pertinenti: \(candidates).")
        """
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func resolve(_ raw: [AIPick], app: AppState) async -> [Pick] {
        let links = LinkLibrary.shared
        // Indice per titolo dei contenuti collegati
        var byTitle: [String: MediaItem] = [:]
        for item in links.matchedItems.values { byTitle[Self.norm(item.title)] = item }
        let tmdb = app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }
        var out: [Pick] = []
        var seen = Set<String>()
        for p in raw.prefix(12) {
            var item = byTitle[Self.norm(p.title)]
            if item == nil, let tmdb {
                item = try? await tmdb.match(title: p.title, year: p.year > 1900 ? p.year : nil, series: p.isSeries)
            }
            let key = item?.id ?? Self.norm(p.title)
            guard seen.insert(key).inserted else { continue }
            let available = item.map { links.link(forItem: $0.id) != nil || links.episodeCount(seriesId: $0.id) > 0 } ?? false
            out.append(Pick(title: item?.title ?? p.title, year: item?.year ?? (p.year > 1900 ? p.year : nil),
                            isSeries: item?.isSeries ?? p.isSeries, reason: p.reason, item: item, available: available))
        }
        // Prima quelli che si possono guardare subito
        return out.enumerated().sorted { a, b in
            a.element.available != b.element.available ? a.element.available : a.offset < b.offset
        }.map(\.element)
    }
    #endif

    nonisolated private static func norm(_ s: String) -> String {
        s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func describe(_ error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize:
                return "La richiesta è troppo lunga: prova con una frase più breve."
            case .guardrailViolation:
                return "Apple Intelligence non può rispondere a questa richiesta."
            case .unsupportedLanguageOrLocale:
                return "Lingua non supportata da Apple Intelligence: controlla la lingua in Impostazioni → Apple Intelligence e Siri."
            default:
                break
            }
        }
        #endif
        return "Non sono riuscito a rispondere: \(error.localizedDescription)"
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct AIPicks {
    @Guide(description: "Una frase breve e cordiale in italiano che introduce i suggerimenti (massimo 20 parole)")
    var intro: String
    @Guide(description: "Esattamente 10 film o serie TV reali ed esistenti adatti alla richiesta", .count(10))
    var picks: [AIPick]
}

@available(iOS 26.0, *)
@Generable
struct AIPick {
    @Guide(description: "Titolo del film o della serie, come è conosciuto in Italia")
    var title: String
    @Guide(description: "Anno di uscita (per le serie, anno della prima stagione)")
    var year: Int
    @Guide(description: "true se è una serie TV, false se è un film")
    var isSeries: Bool
    @Guide(description: "Perché è adatto alla richiesta, in italiano, senza spoiler, massimo 25 parole")
    var reason: String
}
#endif
