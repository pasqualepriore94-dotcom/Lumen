import SwiftUI

/// Gusti dell'utente ricavati da ciò che ha segnato come visto (film, serie, episodi).
struct TasteProfile {
    var weights: [String: Double] = [:]
    var movieWeights: [String: Double] = [:]
    var seriesWeights: [String: Double] = [:]
    var movieCount = 0
    var seriesCount = 0

    var isEmpty: Bool { weights.isEmpty }
    private var maxWeight: Double { weights.values.max() ?? 1 }

    /// Generi in ordine di preferenza. `series`: nil = tutti, true = solo serie, false = solo film.
    func top(_ n: Int, series: Bool? = nil) -> [(genre: String, share: Double)] {
        let source = series == nil ? weights : (series! ? seriesWeights : movieWeights)
        let total = source.values.reduce(0, +)
        guard total > 0 else { return [] }
        return source.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value / total) }
    }

    var favoriteGenre: String? { top(1).first?.genre }
    var prefersSeries: Bool { seriesCount > movieCount }

    /// Percentuale di compatibilità (35–99) di un titolo con i gusti, o nil se non ci sono ancora visti.
    func compatibility(_ item: MediaItem, genres: [String]? = nil) -> Int? {
        let g = (genres?.isEmpty == false ? genres! : (item.tags ?? []))
        guard !isEmpty, !g.isEmpty else { return nil }
        let values = g.map { (weights[$0] ?? 0) / maxWeight }
        let best = values.max() ?? 0
        let avg = values.reduce(0, +) / Double(values.count)
        let total = Double(max(1, movieCount + seriesCount))
        let kindShare = Double(item.isSeries ? seriesCount : movieCount) / total
        let quality = min(1, max(0, (item.score ?? 6.5) / 10))
        let raw = 0.5 * best + 0.25 * avg + 0.12 * kindShare + 0.13 * quality
        return min(99, max(35, Int((35 + raw * 64).rounded())))
    }

    static func build(_ library: Library) -> TasteProfile {
        var p = TasteProfile()
        func add(_ item: MediaItem, weight: Double) {
            for g in item.tags ?? [] {
                p.weights[g, default: 0] += weight
                if item.isSeries { p.seriesWeights[g, default: 0] += weight } else { p.movieWeights[g, default: 0] += weight }
            }
        }
        var counted = Set<String>()
        for s in library.seriesWatch.values where !s.episodes.isEmpty {
            add(s.item, weight: 1 + min(2, Double(s.episodes.count) / 10))
            p.seriesCount += 1
            counted.insert(s.id)
        }
        for w in library.watched.values where !counted.contains(w.id) {
            if w.isSeries { add(w.item, weight: 2); p.seriesCount += 1 } else { add(w.item, weight: 1); p.movieCount += 1 }
        }
        return p
    }
}

extension Library {
    var taste: TasteProfile { TasteProfile.build(self) }

    /// Cambia quando si segna qualcosa come visto o si modifica la lista: serve per controllare i trofei.
    var activitySignature: Int {
        watched.count * 7919 + seriesWatch.values.reduce(0) { $0 + $1.episodes.count } * 31 + myList.count
    }
}

/// Etichetta "92% per te".
struct MatchBadge: View {
    let percent: Int
    var compact = false

    var color: Color {
        percent >= 80 ? Color(red: 0.3, green: 0.85, blue: 0.45) : percent >= 60 ? Color(red: 0.95, green: 0.8, blue: 0.25) : .white.opacity(0.75)
    }

    var body: some View {
        if compact {
            Text("\(percent)%")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .liquidGlassCapsule()
        } else {
            HStack(spacing: 6) {
                Image(systemName: "heart.circle.fill").foregroundStyle(color)
                Text("\(percent)%").font(.system(size: 15, weight: .bold)).foregroundStyle(color)
                Text("per te").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .liquidGlassCapsule()
        }
    }
}

/// Riporta in cima la schermata quando si tocca il suo pulsante nella barra in basso.
struct ScrollsToTopModifier: ViewModifier {
    @Environment(AppState.self) private var app
    let tab: AppTab
    let proxy: ScrollViewProxy
    let anchor: String

    func body(content: Content) -> some View {
        content.onChange(of: app.scrollTopSignal) {
            guard app.scrollTopTab == tab else { return }
            withAnimation(.snappy) { proxy.scrollTo(anchor, anchor: .top) }
        }
    }
}

extension View {
    func scrollsToTop(_ tab: AppTab, proxy: ScrollViewProxy, anchor: String) -> some View {
        modifier(ScrollsToTopModifier(tab: tab, proxy: proxy, anchor: anchor))
    }
}
