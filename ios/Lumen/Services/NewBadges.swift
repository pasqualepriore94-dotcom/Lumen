import SwiftUI

/// Novità da segnare sulla locandina.
enum FreshKind: String, Codable, Comparable {
    case added, episode, season

    var label: String {
        switch self {
        case .added: return "Aggiunto di recente"
        case .episode: return "Nuovo episodio"
        case .season: return "Nuova stagione"
        }
    }

    var color: Color {
        switch self {
        case .added: return Color(red: 0.2, green: 0.62, blue: 1)
        case .episode: return Color(red: 0.95, green: 0.32, blue: 0.3)
        case .season: return Color(red: 0.62, green: 0.38, blue: 1)
        }
    }

    /// Per quanti giorni resta il segno sulla locandina.
    var days: Double { self == .season ? 14 : 7 }

    static func < (a: FreshKind, b: FreshKind) -> Bool {
        let order: [FreshKind] = [.added, .episode, .season]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

struct FreshMark: Codable, Hashable {
    var kind: FreshKind
    var date: Date
    var isValid: Bool { Date().timeIntervalSince(date) < kind.days * 86_400 }
}

/// Registro delle novità dei contenuti collegati (playlist): quando un titolo, un episodio o una stagione
/// diventa disponibile in Lumen.
@MainActor
final class FreshnessStore {
    static let shared = FreshnessStore()
    private(set) var marks: [String: FreshMark] = [:]

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("link-freshness.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let m = try? JSONDecoder().decode([String: FreshMark].self, from: data) {
            marks = m.filter { $0.value.isValid }
        }
    }

    func mark(_ id: String, _ kind: FreshKind, date: Date = Date()) {
        // Una novità più importante non viene sostituita da una minore ancora valida.
        if let old = marks[id], old.isValid, old.kind > kind { return }
        marks[id] = FreshMark(kind: kind, date: date)
    }

    /// Confronta gli episodi collegati prima e dopo un'importazione.
    func recordSeries(_ id: String, before: Set<String>?, after: Set<String>) {
        guard let before, !before.isEmpty else { mark(id, .added); return }
        let added = after.subtracting(before)
        guard !added.isEmpty else { return }
        func season(_ k: String) -> Int { Int(k.dropFirst().prefix { $0.isNumber }) ?? 0 }
        let maxBefore = before.map(season).max() ?? 0
        mark(id, added.contains { season($0) > maxBefore } ? .season : .episode)
    }

    func save() {
        marks = marks.filter { $0.value.isValid }
        if let data = try? JSONEncoder().encode(marks) { try? data.write(to: Self.file, options: .atomic) }
    }

    /// Novità da mostrare sulla locandina: contenuti collegati + nuove uscite dei titoli in "La mia lista".
    func badge(for id: String) -> FreshKind? {
        let local = marks[id].flatMap { $0.isValid ? $0.kind : nil }
        let remote = WatchlistMonitor.shared.freshKind(for: id)
        return [local, remote].compactMap { $0 }.max()
    }
}

/// Etichetta della novità sulla locandina.
struct FreshBadge: View {
    let kind: FreshKind
    var compact = false

    var body: some View {
        Text(kind.label.uppercased())
            .font(.system(size: compact ? 7.5 : 9, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(kind.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
    }
}
