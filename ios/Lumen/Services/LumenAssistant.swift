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
    private(set) var lastQuestion = ""

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
        if let reason = Self.unavailableReason { state = .failed(reason); return }
        state = .thinking
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: Self.instructions(library: library))
                let response = try await session.respond(to: q, generating: AIPicks.self)
                intro = response.content.intro
                picks = await resolve(response.content.picks, app: app)
                state = picks.isEmpty ? .failed("Non ho trovato titoli adatti: prova a descrivere la richiesta in un altro modo.") : .done
            } catch {
                state = .failed(Self.describe(error))
            }
            return
        }
        #endif
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
        Proponi da 4 a 8 film o serie TV reali ed esistenti, adatti alla richiesta dell'utente.
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
        for p in raw.prefix(8) {
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

    private static func norm(_ s: String) -> String {
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
    @Guide(description: "Da 4 a 8 film o serie TV reali ed esistenti adatti alla richiesta")
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
