import Foundation

/// Filtro dei contenuti per adulti delle playlist: le voci riconosciute dal gruppo o dal titolo
/// non vengono importate e quelle già importate vengono tolte. TMDB esclude già i titoli per adulti.
enum ContentFilter {
    private static let key = "lumen.hideAdult"
    private static let removedKey = "lumen.hiddenAdultCount"

    /// Attivo di base.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Quanti contenuti sono stati esclusi finora (per l'impostazione).
    static var removedCount: Int {
        get { UserDefaults.standard.integer(forKey: removedKey) }
        set { UserDefaults.standard.set(newValue, forKey: removedKey) }
    }

    /// Parole intere che indicano contenuti per adulti (nel gruppo o nel titolo della voce).
    private static let words: Set<String> = [
        "xxx", "porn", "porno", "pornhub", "adult", "adults", "adulti", "adulto", "hentai",
        "erotic", "erotico", "erotica", "erotici", "erotiche", "erotik", "erotique", "playboy", "hustler",
        "brazzers", "vm18", "18+", "+18", "nsfw", "milf", "onlyfans", "camgirl", "redlight"
    ]
    /// Eccezioni note (canali e titoli normali che contengono una delle parole).
    private static let safePhrases = ["adult swim", "young adult", "adulti si diventa"]

    static func isAdult(_ m: LinkMedia) -> Bool { isAdult(text: m.title + " | " + (m.group ?? "")) }

    static func isAdult(text: String) -> Bool {
        let lower = text.lowercased()
        if safePhrases.contains(where: lower.contains) { return false }
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+")).inverted)
        return tokens.contains { !$0.isEmpty && words.contains($0) }
    }

    /// Voci da importare: senza quelle per adulti se il filtro è attivo.
    static func apply(_ list: [LinkMedia]) -> [LinkMedia] {
        guard enabled else { return list }
        return list.filter { !isAdult($0) }
    }
}

extension LinkLibrary {
    /// Toglie dalla libreria i contenuti per adulti già importati (film, episodi, dirette, voci senza scheda).
    /// Restituisce quanti ne ha tolti.
    @discardableResult
    func purgeAdultContent() async -> Int {
        guard ContentFilter.enabled else { return 0 }
        let all = items + Array(movieLinks.values) + episodeLinks.values.flatMap { $0.values }
        let ids = await Task.detached(priority: .utility) { Set(all.filter(ContentFilter.isAdult).map(\.id)) }.value
        guard !ids.isEmpty else { return 0 }
        removeLinks(ids)
        ContentFilter.removedCount += ids.count
        return ids.count
    }
}
