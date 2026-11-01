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

/// "La mia lista" e "Continua a guardare", salvati sul dispositivo.
@MainActor
@Observable
final class Library {
    private enum Keys {
        static let list = "lumen.myList"
        static let progress = "lumen.progress"
    }

    private(set) var myList: [MediaItem] = []
    private(set) var progress: [String: WatchProgress] = [:]

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Keys.list), let list = try? JSONDecoder().decode([MediaItem].self, from: data) {
            myList = list
        }
        if let data = d.data(forKey: Keys.progress),
           let p = try? JSONDecoder().decode([String: WatchProgress].self, from: data) {
            progress = p
        }
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
    }
}
