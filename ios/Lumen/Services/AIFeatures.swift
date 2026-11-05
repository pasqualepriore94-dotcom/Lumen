import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Funzioni di Apple Intelligence (modello sul telefono, iOS 26) usate in tutta l'app.
// Senza Apple Intelligence ognuna ha un ripiego semplice o resta nascosta.

// MARK: - Cache su disco condivisa

/// Testi generati salvati sul telefono, così non si rigenerano a ogni apertura.
@MainActor
enum AITextCache {
    private static var store: [String: String] = load()
    private static var saveTask: Task<Void, Never>?
    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ai-texts.json")
    }

    static func get(_ key: String) -> String? { store[key] }

    static func set(_ key: String, _ value: String) {
        store[key] = value
        if store.count > 4000 { store = Dictionary(uniqueKeysWithValues: store.suffix(3000).map { ($0.key, $0.value) }) }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(store) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

/// Una risposta testuale breve dal modello (nil se Apple Intelligence non c'è o non risponde).
@MainActor
enum AIText {
    static var isAvailable: Bool { LumenAssistant.unavailableReason == nil }

    static func respond(instructions: String, prompt: String, temperature: Double = 0.3) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        guard let r = try? await session.respond(to: prompt, options: GenerationOptions(temperature: temperature)) else { return nil }
        let out = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"«»"))
        return out.isEmpty ? nil : out
        #else
        return nil
        #endif
    }
}

// MARK: - 2. "Perché te lo consiglio"

@MainActor
enum WhyRecommend {
    /// Titoli già visti più simili (generi in comune), i più "pesanti" per primi.
    static func similarSeen(genres: [String], excluding id: String, title: String? = nil, library: Library) -> [MediaItem] {
        let ownTitle = title.map(norm)
        let wanted = Set(genres)
        guard !wanted.isEmpty else { return [] }
        var seen: [String: (MediaItem, Double)] = [:]
        for s in library.seriesWatch.values where !s.episodes.isEmpty {
            seen[s.id] = (s.item, 1 + min(2, Double(s.episodes.count) / 10))
        }
        for w in library.watched.values where seen[w.id] == nil { seen[w.id] = (w.item, 1) }
        return seen.values
            // Mai il titolo stesso (anche se visto con un'altra scheda, es. dalla playlist)
            .filter { $0.0.id != id && (ownTitle == nil || norm($0.0.title) != ownTitle) }
            .map { pair -> (MediaItem, Double) in
                let common = Set(pair.0.tags ?? []).intersection(wanted).count
                return (pair.0, Double(common) * 2 + pair.1)
            }
            .filter { Set($0.0.tags ?? []).intersection(wanted).count > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map(\.0)
    }

    /// Frase semplice senza AI: "Ti sono piaciuti Dark e Stranger Things: anche questo è Mistero."
    static func fallback(similar: [MediaItem], genres: [String]) -> String? {
        guard !similar.isEmpty else { return nil }
        let names = similar.prefix(2).map(\.title)
        let common = genres.filter { g in similar.contains { ($0.tags ?? []).contains(g) } }.prefix(2)
        let who = names.count == 1 ? "Ti è piaciuto \(names[0])" : "Ti sono piaciuti \(names[0]) e \(names[1])"
        let what = common.isEmpty ? "" : ": stesso genere, \(common.joined(separator: " e ").lowercased())"
        return who + what + "."
    }

    static func cached(_ id: String, signature: Int) -> String? { AITextCache.get("why2|\(id)|\(signature)") }

    static func generate(item: MediaItem, overview: String?, genres: [String], similar: [MediaItem], signature: Int) async -> String? {
        let key = "why2|\(item.id)|\(signature)"
        if let c = AITextCache.get(key) { return c }
        guard !similar.isEmpty else { return nil }
        let seenText = similar.map { s in
            "- \(s.title) (\((s.tags ?? []).joined(separator: ", ")))" + (s.overview.map { ": " + String($0.prefix(160)) } ?? "")
        }.joined(separator: "\n")
        let prompt = """
        Titolo consigliato: \(item.title) (\(genres.joined(separator: ", ")))\(overview.map { "\nTrama: " + String($0.prefix(300)) } ?? "")
        Titoli che l'utente ha visto e apprezzato:
        \(seenText)
        """
        let out = await AIText.respond(instructions: """
        Sei l'assistente di Lumen. Scrivi UNA sola frase in italiano, massimo 22 parole, che spiega perché il titolo
        consigliato piacerà all'utente. Inizia con "Ti è piaciuto" o "Ti sono piaciuti" seguito da uno o due titoli visti,
        poi i due punti e cosa hanno in comune (atmosfera, temi, tipo di protagonisti). Cita solo titoli dell'elenco dei visti,
        mai il titolo consigliato. Usa solo le informazioni fornite,
        niente spoiler, niente virgolette.
        """, prompt: prompt, temperature: 0.4)
        // La frase non deve citare il titolo consigliato come "già visto"
        guard let out, out.count < 260, !norm(out).contains(norm(item.title)) || norm(item.title).count < 4 else { return nil }
        AITextCache.set(key, out)
        return out
    }
}

private func norm(_ s: String) -> String {
    s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
}

// MARK: - 6. Trame più brevi e tradotte

@MainActor
enum PlotWriter {
    /// Trama tradotta in italiano (quando TMDB ha solo quella inglese).
    static func cachedTranslation(_ id: String) -> String? { AITextCache.get("it|\(id)") }

    static func translate(id: String, text: String) async -> String? {
        if let c = AITextCache.get("it|\(id)") { return c }
        let out = await AIText.respond(instructions: """
        Traduci in italiano naturale e scorrevole la trama di un film o di una serie TV.
        Rispondi solo con la traduzione, senza commenti. Mantieni i nomi propri.
        """, prompt: text, temperature: 0.1)
        guard let out else { return nil }
        AITextCache.set("it|\(id)", out)
        return out
    }

    /// Trama breve (massimo ~28 parole) in italiano, per le Clip.
    static func cachedShort(_ id: String) -> String? { AITextCache.get("short|\(id)") }

    static func short(id: String, text: String) async -> String? {
        if let c = AITextCache.get("short|\(id)") { return c }
        guard text.split(separator: " ").count > 22 || !looksItalian(text) else { return nil }
        let out = await AIText.respond(instructions: """
        Riscrivi in italiano la trama ricevuta in una o due frasi, massimo 28 parole, che invoglino a guardare.
        Niente spoiler, niente commenti, rispondi solo con la trama.
        """, prompt: text, temperature: 0.2)
        guard let out else { return nil }
        AITextCache.set("short|\(id)", out)
        return out
    }

    private static func looksItalian(_ s: String) -> Bool {
        let t = " " + s.lowercased() + " "
        let it = [" il ", " che ", " della ", " una ", " per ", " non ", " di "].filter { t.contains($0) }.count
        let en = [" the ", " and ", " his ", " her ", " with ", " of "].filter { t.contains($0) }.count
        return it >= en
    }
}

// MARK: - Titoli scartati dai consigli

/// Titoli che hai scartato: non vengono più proposti (categorie su misura e suggerimenti di Apple Intelligence).
@MainActor
@Observable
final class SuggestionFilter {
    static let shared = SuggestionFilter()
    private static let key = "lumen.dismissedSuggestions"

    /// Più recenti per primi.
    private(set) var dismissed: [MediaItem] = []
    @ObservationIgnored private var ids: Set<String> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([MediaItem].self, from: data) {
            dismissed = list
            ids = Set(list.map(\.id))
        }
    }

    func isDismissed(_ id: String) -> Bool { ids.contains(id) }

    func dismiss(_ item: MediaItem) {
        guard ids.insert(item.id).inserted else { return }
        dismissed.insert(item, at: 0)
        save()
    }

    func restore(_ id: String) {
        guard ids.remove(id) != nil else { return }
        dismissed.removeAll { $0.id == id }
        save()
    }

    /// Per il modello: "non proporre questi titoli".
    var promptList: String { dismissed.prefix(40).map(\.title).joined(separator: "; ") }

    private func save() {
        if let data = try? JSONEncoder().encode(dismissed) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - 5. Categorie su misura in Home

@MainActor
@Observable
final class PersonalRows {
    static let shared = PersonalRows()

    struct Row: Codable, Identifiable, Hashable {
        var id: String
        var title: String
        var items: [MediaItem]
    }

    private struct Saved: Codable {
        var date: Date
        var signature: Int
        var rows: [Row]
    }

    private var storedRows: [Row] = []
    /// Righe da mostrare (senza i titoli scartati).
    var rows: [Row] {
        let filter = SuggestionFilter.shared
        _ = filter.dismissed.count
        return storedRows.map { r in var r = r; r.items.removeAll { filter.isDismissed($0.id) }; return r }
    }
    private(set) var generating = false
    @ObservationIgnored private var savedDate: Date?
    @ObservationIgnored private var savedSignature = 0

    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("personal-rows.json")
    }

    private init() {
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            storedRows = s.rows
            // Le righe salvate con la versione precedente (8 titoli) vengono rigenerate più lunghe.
            savedDate = s.rows.contains { $0.items.count > 12 } ? s.date : nil
            savedSignature = s.signature
        }
    }

    /// Rigenera le righe quando sono vecchie (più di un giorno e nel frattempo hai visto altro, o più di 3 giorni).
    func refreshIfNeeded(app: AppState, library: Library, force: Bool = false) async {
        guard AIText.isAvailable, !generating else { return }
        let seenCount = library.watched.count + library.seriesWatch.values.filter { !$0.episodes.isEmpty }.count
        guard seenCount >= 2 else { return }
        let signature = library.activitySignature
        if !force, let savedDate {
            let age = Date().timeIntervalSince(savedDate)
            let stale = (age > 20 * 3600 && signature != savedSignature) || age > 72 * 3600
            guard stale else { return }
        }
        generating = true
        defer { generating = false }
        guard let fresh = await generate(app: app, library: library), !fresh.isEmpty else { return }
        storedRows = fresh
        savedDate = Date()
        savedSignature = signature
        if let data = try? JSONEncoder().encode(Saved(date: Date(), signature: signature, rows: fresh)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func generate(app: AppState, library: Library) async -> [Row]? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        let taste = library.taste
        let favorites = taste.top(6).map { "\($0.genre) (\(Int($0.share * 100))%)" }.joined(separator: ", ")
        let seenItems = library.seriesWatch.values.filter { !$0.episodes.isEmpty }.map(\.item) + library.watched.values.map(\.item)
        let seen = seenItems.prefix(30).map { "\($0.title)\($0.isSeries ? " (serie)" : "")" }.joined(separator: "; ")
        let links = LinkLibrary.shared
        let candidates = links.matchedItems.values
            .filter { $0.id.hasPrefix("movie-") || $0.id.hasPrefix("tv-") }
            .sorted { (taste.compatibility($0) ?? 50) > (taste.compatibility($1) ?? 50) }
            .prefix(45)
            .map { "\($0.title)\($0.isSeries ? " (serie)" : "")" }
            .joined(separator: "; ")
        let dismissedList = SuggestionFilter.shared.promptList
        let session = LanguageModelSession(instructions: """
        Sei l'assistente di Lumen, un'app per guardare film e serie TV. Rispondi in italiano.
        Crea 3 categorie su misura per la home dell'utente, basate sui suoi gusti, con nomi originali e specifici
        (esempi: "Thriller psicologici per te", "Serie brevi da finire in un weekend", "Commedie per staccare la testa").
        Ogni categoria ha 10 film o serie TV reali ed esistenti, coerenti con il nome, che l'utente non ha ancora visto.
        Preferisci i titoli già disponibili in Lumen quando sono adatti. Non inventare titoli.
        """)
        let prompt = """
        Generi preferiti: \(favorites)
        Titoli già visti (non riproporli): \(seen)
        \(dismissedList.isEmpty ? "" : "Titoli che all'utente non interessano (non proporli mai): \(dismissedList)")
        \(candidates.isEmpty ? "" : "Titoli disponibili in Lumen: \(candidates)")
        """
        guard let response = try? await session.respond(to: prompt, generating: AIRows.self, options: GenerationOptions(temperature: 0.6))
        else { return nil }
        let seenIds = Set(seenItems.map(\.id))
        var byTitle: [String: MediaItem] = [:]
        for item in links.matchedItems.values { byTitle[Self.norm(item.title)] = item }
        let tmdb = app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }
        var out: [Row] = []
        var used = Set<String>()
        for (r, row) in response.content.rows.enumerated() {
            let picks = Array(row.picks.prefix(12))
            var found: [Int: MediaItem] = [:]
            await withTaskGroup(of: (Int, MediaItem?).self) { group in
                for (i, p) in picks.enumerated() {
                    if let local = byTitle[Self.norm(p.title)] { found[i] = local; continue }
                    guard let tmdb else { continue }
                    let title = p.title, year = p.year > 1900 ? p.year : nil, series = p.isSeries
                    group.addTask { (i, try? await tmdb.match(title: title, year: year, series: series)) }
                }
                for await (i, item) in group { if let item { found[i] = item } }
            }
            let seeds = picks.indices.compactMap { found[$0] }
            // Generi della categoria: i più frequenti tra i titoli proposti dal modello
            var counts: [String: Int] = [:]
            for s in seeds { for g in s.tags ?? [] { counts[g, default: 0] += 1 } }
            let rowGenres = Set(counts.sorted { $0.value > $1.value }.prefix(2).map(\.key))
            let main = counts.max { $0.value < $1.value }?.key
            // Più titoli: consigliati da TMDB a partire dai primi titoli della categoria…
            var recs: [MediaItem] = []
            if let tmdb {
                await withTaskGroup(of: [MediaItem].self) { group in
                    for s in seeds.prefix(5) where s.id.hasPrefix("movie-") || s.id.hasPrefix("tv-") {
                        let id = s.id
                        group.addTask { await tmdb.recommendations(for: id) }
                    }
                    for await list in group { recs += list }
                }
            }
            recs = recs.filter { !Set($0.tags ?? []).isDisjoint(with: rowGenres) }
                .sorted { (taste.compatibility($0) ?? 50) > (taste.compatibility($1) ?? 50) }
            // …e dalla tua playlist, dello stesso genere e compatibili con i tuoi gusti
            var fromPlaylist: [MediaItem] = []
            if let g = main {
                let scored = links.matchedItems.values
                    .filter { ($0.tags ?? []).contains(g) }
                    .map { ($0, taste.compatibility($0) ?? 0) }
                    .filter { $0.1 >= 60 }
                    .sorted { $0.1 > $1.1 }
                fromPlaylist = scored.prefix(15).map(\.0)
            }
            let filter = SuggestionFilter.shared
            let items = (seeds + fromPlaylist + recs)
                .filter { !seenIds.contains($0.id) && !filter.isDismissed($0.id) && used.insert($0.id).inserted }
                .prefix(40)
            // Prima quelli che si possono guardare subito
            let sorted = items.enumerated().sorted { a, b in
                let av = links.link(forItem: a.element.id) != nil || links.episodeCount(seriesId: a.element.id) > 0
                let bv = links.link(forItem: b.element.id) != nil || links.episodeCount(seriesId: b.element.id) > 0
                return av != bv ? av : a.offset < b.offset
            }.map(\.element)
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"«»")))
            if sorted.count >= 6, !title.isEmpty { out.append(Row(id: "ai-row-\(r)", title: title, items: sorted)) }
        }
        return out
        #else
        return nil
        #endif
    }

    nonisolated private static func norm(_ s: String) -> String {
        s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct AIRows {
    @Guide(description: "Esattamente 3 categorie su misura", .count(3))
    var rows: [AIRow]
}

@available(iOS 26.0, *)
@Generable
struct AIRow {
    @Guide(description: "Nome originale della categoria, in italiano, massimo 6 parole")
    var title: String
    @Guide(description: "10 film o serie TV reali ed esistenti adatti alla categoria", .count(10))
    var picks: [AIRowPick]
}

@available(iOS 26.0, *)
@Generable
struct AIRowPick {
    @Guide(description: "Titolo come è conosciuto in Italia")
    var title: String
    @Guide(description: "Anno di uscita (per le serie, della prima stagione)")
    var year: Int
    @Guide(description: "true se è una serie TV")
    var isSeries: Bool
}
#endif
