import Foundation
import Observation

struct WatchProgress: Codable, Identifiable, Hashable {
    var id: String { item.id }
    var item: MediaItem
    var episodeId: String?
    var episodeLabel: String?
    var position: Double
    var duration: Double
    var updatedAt: Date

    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
}

/// Titolo segnato come "Visto", con il tempo stimato passato a guardarlo.
struct WatchedEntry: Codable, Identifiable, Hashable {
    var id: String { item.id }
    var item: MediaItem
    var minutes: Int
    var episodes: Int
    /// true se la durata non era disponibile ed è stata stimata.
    var estimated: Bool
    var date: Date

    var isSeries: Bool { item.isSeries }

    /// Calcola il tempo dalla scheda del titolo: durata del film, oppure somma degli episodi della serie.
    static func make(item: MediaItem, detail: MediaDetail?) -> WatchedEntry {
        if item.isSeries {
            let episodes = detail?.seasons.flatMap(\.episodes) ?? []
            let fallback = max(1, (detail?.duration ?? 0) / 60)
            var estimated = episodes.isEmpty
            let minutes = episodes.reduce(0) { total, e in
                let m = (e.duration ?? 0) / 60
                if m <= 0 { estimated = true }
                return total + (m > 0 ? m : (detail?.duration ?? 0) > 0 ? fallback : 45)
            }
            let count = max(episodes.count, episodes.isEmpty ? 10 : 0)
            return WatchedEntry(item: item, minutes: episodes.isEmpty ? count * 45 : minutes,
                                episodes: count, estimated: estimated, date: Date())
        } else {
            let m = (detail?.duration ?? 0) / 60
            return WatchedEntry(item: item, minutes: m > 0 ? m : 110, episodes: 0, estimated: m <= 0, date: Date())
        }
    }
}

/// Un episodio segnato come visto.
struct EpisodeWatch: Codable, Hashable {
    var minutes: Int
    var label: String
    var estimated: Bool
    var date: Date
}

/// Episodi visti di una serie.
struct SeriesWatch: Codable, Hashable, Identifiable {
    var id: String { item.id }
    var item: MediaItem
    var episodes: [String: EpisodeWatch]
    var totalEpisodes: Int
    var updated: Date

    var minutes: Int { episodes.values.reduce(0) { $0 + $1.minutes } }
    var estimated: Bool { episodes.values.contains { $0.estimated } }
}

struct WatchTotals {
    var movies = 0
    var movieMinutes = 0
    var series = 0
    var seriesMinutes = 0
    var episodes = 0
    var totalMinutes: Int { movieMinutes + seriesMinutes }
}

/// "La mia lista" e "Continua a guardare", salvati sul dispositivo.
@MainActor
@Observable
final class Library {
    private enum Keys {
        static let list = "lumen.myList"
        static let progress = "lumen.progress"
        static let watched = "lumen.watched"
        static let series = "lumen.seriesWatch"
    }

    private(set) var myList: [MediaItem] = []
    private(set) var progress: [String: WatchProgress] = [:]
    private(set) var watched: [String: WatchedEntry] = [:]
    private(set) var seriesWatch: [String: SeriesWatch] = [:]
    /// Gusti calcolati una volta finché non cambia ciò che hai visto (prima: un ricalcolo per ogni locandina).
    @ObservationIgnored var tasteCache: (signature: Int, profile: TasteProfile)?

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Keys.list), let list = try? JSONDecoder().decode([MediaItem].self, from: data) {
            myList = list
        }
        if let data = d.data(forKey: Keys.progress),
           let p = try? JSONDecoder().decode([String: WatchProgress].self, from: data) {
            progress = p
        }
        if let data = d.data(forKey: Keys.watched),
           let w = try? JSONDecoder().decode([String: WatchedEntry].self, from: data) {
            watched = w
        }
        if let data = d.data(forKey: Keys.series),
           let sw = try? JSONDecoder().decode([String: SeriesWatch].self, from: data) {
            seriesWatch = sw
        }
    }

    // MARK: Episodi visti

    static func minutes(for episode: Episode, detail: MediaDetail?) -> (Int, Bool) {
        let m = (episode.duration ?? 0) / 60
        if m > 0 { return (m, false) }
        let fallback = (detail?.duration ?? 0) / 60
        return (fallback > 0 ? fallback : 45, true)
    }

    func isEpisodeWatched(seriesId: String, episodeId: String) -> Bool {
        seriesWatch[seriesId]?.episodes[episodeId] != nil
    }

    func watchedEpisodeCount(seriesId: String) -> Int {
        seriesWatch[seriesId]?.episodes.count ?? 0
    }

    /// Segna o toglie un gruppo di episodi (uno, una stagione o tutta la serie).
    func setEpisodes(_ list: [Episode], watched isWatched: Bool, item: MediaItem, detail: MediaDetail?) {
        var entry = seriesWatch[item.id] ?? SeriesWatch(item: item, episodes: [:], totalEpisodes: 0, updated: Date())
        entry.item = item
        entry.totalEpisodes = detail?.seasons.reduce(0) { $0 + $1.episodes.count } ?? entry.totalEpisodes
        for e in list {
            if isWatched {
                let (m, estimated) = Self.minutes(for: e, detail: detail)
                entry.episodes[e.id] = EpisodeWatch(minutes: m, label: detail?.label(for: e) ?? e.title,
                                                    estimated: estimated, date: Date())
            } else {
                entry.episodes[e.id] = nil
            }
        }
        entry.updated = Date()
        seriesWatch[item.id] = entry.episodes.isEmpty ? nil : entry
        // La vecchia spunta "serie intera" viene sostituita dal conteggio per episodio.
        watched[item.id] = nil
        save()
    }

    func toggleEpisode(_ episode: Episode, item: MediaItem, detail: MediaDetail?) {
        let now = !isEpisodeWatched(seriesId: item.id, episodeId: episode.id)
        setEpisodes([episode], watched: now, item: item, detail: detail)
    }

    // MARK: Visti

    func isWatched(_ id: String) -> Bool { watched[id] != nil }

    func markWatched(_ entry: WatchedEntry) {
        watched[entry.id] = entry
        progress[entry.id] = nil
        save()
    }

    func unmarkWatched(_ id: String) {
        watched[id] = nil
        seriesWatch[id] = nil
        save()
    }

    /// Film visti + serie con almeno un episodio visto (e vecchie spunte "serie intera").
    var watchedList: [WatchedEntry] {
        var list = Array(watched.values.filter { seriesWatch[$0.id] == nil })
        list += seriesWatch.values.map {
            WatchedEntry(item: $0.item, minutes: $0.minutes, episodes: $0.episodes.count,
                         estimated: $0.estimated, date: $0.updated)
        }
        return list.sorted { $0.date > $1.date }
    }

    var totals: WatchTotals {
        var t = WatchTotals()
        for e in watchedList {
            if e.isSeries {
                t.series += 1; t.seriesMinutes += e.minutes; t.episodes += e.episodes
            } else {
                t.movies += 1; t.movieMinutes += e.minutes
            }
        }
        return t
    }

    func contains(_ item: MediaItem) -> Bool { myList.contains { $0.id == item.id } }

    func toggle(_ item: MediaItem) {
        if let i = myList.firstIndex(where: { $0.id == item.id }) {
            myList.remove(at: i)
        } else {
            myList.insert(item, at: 0)
        }
        save()
    }

    var continueWatching: [WatchProgress] {
        progress.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func resumeEntry(for itemId: String) -> WatchProgress? { progress[itemId] }

    func resumePosition(itemId: String, episodeId: String?) -> Double {
        guard let p = progress[itemId], p.episodeId == episodeId else { return 0 }
        return p.position
    }

    func update(item: MediaItem, episodeId: String?, episodeLabel: String?, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        if position / duration > 0.95 || duration - position < 20 {
            progress[item.id] = nil
        } else if position > 5 {
            progress[item.id] = WatchProgress(item: item, episodeId: episodeId, episodeLabel: episodeLabel,
                                              position: position, duration: duration, updatedAt: Date())
        }
        save()
    }

    func removeProgress(_ itemId: String) {
        progress[itemId] = nil
        save()
    }

    func clearHistory() {
        progress = [:]
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(myList) { d.set(data, forKey: Keys.list) }
        if let data = try? JSONEncoder().encode(progress) { d.set(data, forKey: Keys.progress) }
        if let data = try? JSONEncoder().encode(watched) { d.set(data, forKey: Keys.watched) }
        if let data = try? JSONEncoder().encode(seriesWatch) { d.set(data, forKey: Keys.series) }
    }
}
