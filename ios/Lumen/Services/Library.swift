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
    }

    private(set) var myList: [MediaItem] = []
    private(set) var progress: [String: WatchProgress] = [:]
    private(set) var watched: [String: WatchedEntry] = [:]

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
        save()
    }

    var watchedList: [WatchedEntry] { watched.values.sorted { $0.date > $1.date } }

    var totals: WatchTotals {
        var t = WatchTotals()
        for e in watched.values {
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
    }
}
