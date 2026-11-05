import Foundation
import Observation
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

// Siri, Comandi rapidi e Ricerca Spotlight.

/// Cosa deve fare l'app dopo un comando di Siri o un tocco su un risultato di Spotlight.
@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()

    enum Action: Equatable {
        case ask(String)
        case resume
        case open(String)
    }

    var pending: Action?
    /// Cambia a ogni nuova richiesta (anche se uguale alla precedente).
    private(set) var token = 0

    func send(_ action: Action) {
        pending = action
        token += 1
    }

    /// Legge la richiesta lasciata da Siri (anche se l'app era chiusa o ancora in avvio).
    func pullInbox() {
        guard let raw = IntentInbox.take() else { return }
        if raw == "resume" { send(.resume) }
        else if raw.hasPrefix("ask:") { send(.ask(String(raw.dropFirst(4)))) }
        else if raw.hasPrefix("open:") { send(.open(String(raw.dropFirst(5)))) }
    }
}

/// Casella di passaggio tra i comandi di Siri e l'app: i comandi rispondono subito
/// (senza aspettare che l'app abbia finito di avviarsi, causa di "Qualcosa è andato storto").
enum IntentInbox {
    private static let key = "lumen.intent.inbox"

    static func put(_ value: String) {
        UserDefaults.standard.set(value, forKey: key)
        Task { @MainActor in IntentRouter.shared.pullInbox() }
    }

    static func take() -> String? {
        guard let v = UserDefaults.standard.string(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return v
    }

    /// Titoli delle categorie su misura salvate (lette dal file, senza passare dall'app).
    static func suggestedTitles(limit: Int) -> [String] {
        struct Item: Decodable { var id: String; var title: String }
        struct Row: Decodable { var items: [Item] }
        struct Saved: Decodable { var rows: [Row] }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("personal-rows.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return [] }
        let dismissed: Set<String> = {
            guard let d = UserDefaults.standard.data(forKey: "lumen.dismissedSuggestions"),
                  let list = try? JSONDecoder().decode([Item].self, from: d) else { return [] }
            return Set(list.map(\.id))
        }()
        // Il primo titolo di ogni categoria, poi il secondo, …
        var out: [String] = []
        var seen = Set<String>()
        let rows = saved.rows.map { $0.items.filter { !dismissed.contains($0.id) } }
        for i in 0..<(rows.map(\.count).max() ?? 0) {
            for r in rows where i < r.count && seen.insert(r[i].id).inserted {
                out.append(r[i].title)
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// Ultimo titolo che stavi guardando.
    static func lastWatching() -> (title: String, episode: String?)? {
        struct Item: Decodable { var title: String }
        struct Progress: Decodable { var item: Item; var episodeLabel: String?; var updatedAt: Date }
        guard let d = UserDefaults.standard.data(forKey: "lumen.progress"),
              let map = try? JSONDecoder().decode([String: Progress].self, from: d),
              let last = map.values.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        return (last.item.title, last.episodeLabel)
    }

    static func list(_ titles: [String]) -> String {
        guard titles.count > 1 else { return titles.first ?? "" }
        return titles.dropLast().joined(separator: ", ") + " e " + titles.last!
    }
}

// MARK: - Comandi di Siri

struct WhatToWatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Consigli per stasera"
    static var description = IntentDescription("Ti dice cosa guardare stasera in base ai tuoi gusti e apre i consigli in Lumen.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentInbox.put("ask:Cosa mi consigli di guardare stasera?")
        let titles = IntentInbox.suggestedTitles(limit: 3)
        if titles.isEmpty {
            return .result(dialog: IntentDialog(full: "Ecco i consigli di Lumen per stasera.", supporting: "Ecco i consigli per stasera."))
        }
        let text = "Stasera ti propongo \(IntentInbox.list(titles)). Trovi altri consigli in Lumen."
        return .result(dialog: IntentDialog(full: LocalizedStringResource(stringLiteral: text),
                                            supporting: LocalizedStringResource(stringLiteral: text)))
    }
}

struct SearchLumenIntent: AppIntent {
    static var title: LocalizedStringResource = "Cerca su Lumen"
    static var description = IntentDescription("Cerca un titolo o descrivi cosa ti va di vedere.")
    static var openAppWhenRun = true

    @Parameter(title: "Cosa cerchi", requestValueDialog: "Cosa vuoi cercare su Lumen?")
    var query: String

    func perform() async throws -> some IntentResult {
        IntentInbox.put("ask:" + query)
        return .result()
    }
}

struct ResumeWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Dove ero rimasto"
    static var description = IntentDescription("Apre l'ultimo film o l'ultima serie che stavi guardando.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentInbox.put("resume")
        guard let last = IntentInbox.lastWatching() else {
            return .result(dialog: "Non stai guardando nulla al momento: apro Lumen.")
        }
        let text = "Riprendo \(last.title)" + (last.episode.map { ", \($0)" } ?? "") + "."
        return .result(dialog: IntentDialog(full: LocalizedStringResource(stringLiteral: text),
                                            supporting: LocalizedStringResource(stringLiteral: text)))
    }
}

struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatToWatchIntent(), phrases: [
            // Niente "guarda", "vedi", "riprendi": Siri le prende per i suoi comandi di riproduzione.
            "Consigliami qualcosa su \(.applicationName)",
            "Cosa mi consiglia \(.applicationName)",
            "Consigli di \(.applicationName) per stasera",
            "Dammi un consiglio su \(.applicationName)"
        ], shortTitle: "Consigli per stasera", systemImageName: "sparkles.tv")
        AppShortcut(intent: SearchLumenIntent(), phrases: [
            "Cerca su \(.applicationName)",
            "Cerca un film su \(.applicationName)",
            "Cerca una serie su \(.applicationName)"
        ], shortTitle: "Cerca su Lumen", systemImageName: "magnifyingglass")
        AppShortcut(intent: ResumeWatchingIntent(), phrases: [
            "Dove ero rimasto su \(.applicationName)",
            "Dove eravamo rimasti su \(.applicationName)",
            "Apri l'ultimo titolo su \(.applicationName)"
        ], shortTitle: "Dove ero rimasto", systemImageName: "play.circle")
    }
}

// MARK: - Ricerca Spotlight

/// Mette i titoli guardabili in Lumen nella ricerca di iPhone (scorri giù dalla Home e scrivi il titolo).
@MainActor
enum SpotlightIndexer {
    private static let domain = "app.lumen.catalog"
    private static let signatureKey = "lumen.spotlight.signature"

    static func indexIfNeeded() async {
        let links = LinkLibrary.shared
        let items = Array(links.matchedItems.values)
        let signature = "\(items.count)|\(items.map(\.id).sorted().prefix(50).joined())"
        guard UserDefaults.standard.string(forKey: signatureKey) != signature else { return }
        let entries = items.map { item -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .movie)
            attrs.title = item.title
            let kind = item.isSeries ? "Serie TV" : "Film"
            attrs.contentDescription = ([kind, item.year.map(String.init)].compactMap { $0 } + [item.tagLine].filter { !$0.isEmpty })
                .joined(separator: " · ") + "\nDa guardare su Lumen"
            attrs.keywords = (item.tags ?? []) + [kind, "Lumen"]
            attrs.displayName = item.title
            return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: domain, attributeSet: attrs)
        }
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        // A blocchi: la playlist può avere decine di migliaia di titoli.
        var start = 0
        while start < entries.count {
            let chunk = Array(entries[start..<min(start + 1000, entries.count)])
            try? await index.indexSearchableItems(chunk)
            start += 1000
        }
        UserDefaults.standard.set(signature, forKey: signatureKey)
    }
}
