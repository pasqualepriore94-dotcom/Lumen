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
}

// MARK: - Comandi di Siri

struct WhatToWatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Cosa guardo stasera"
    static var description = IntentDescription("Apre Lumen con i consigli di Apple Intelligence in base ai tuoi gusti.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentRouter.shared.send(.ask("Cosa mi consigli di guardare stasera?"))
        return .result(dialog: "Ecco cosa ti propone Lumen per stasera.")
    }
}

struct SearchLumenIntent: AppIntent {
    static var title: LocalizedStringResource = "Cerca su Lumen"
    static var description = IntentDescription("Cerca un titolo o descrivi cosa ti va di vedere.")
    static var openAppWhenRun = true

    @Parameter(title: "Cosa cerchi", requestValueDialog: "Cosa vuoi cercare su Lumen?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.send(.ask(query))
        return .result()
    }
}

struct ResumeWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Riprendi la visione"
    static var description = IntentDescription("Apre l'ultimo film o l'ultima serie che stavi guardando.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.send(.resume)
        return .result()
    }
}

struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatToWatchIntent(), phrases: [
            "Cosa guardo stasera su \(.applicationName)",
            "Cosa guardo stasera con \(.applicationName)",
            "Consigliami qualcosa su \(.applicationName)",
            "Cosa vedo su \(.applicationName)"
        ], shortTitle: "Cosa guardo stasera", systemImageName: "sparkles.tv")
        AppShortcut(intent: SearchLumenIntent(), phrases: [
            "Cerca su \(.applicationName)",
            "Cerca un film su \(.applicationName)",
            "Cerca una serie su \(.applicationName)"
        ], shortTitle: "Cerca su Lumen", systemImageName: "magnifyingglass")
        AppShortcut(intent: ResumeWatchingIntent(), phrases: [
            "Riprendi la visione su \(.applicationName)",
            "Continua a guardare su \(.applicationName)"
        ], shortTitle: "Riprendi la visione", systemImageName: "play.circle")
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
