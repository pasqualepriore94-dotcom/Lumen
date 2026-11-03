import Foundation
import UIKit
import UserNotifications
import BackgroundTasks

/// Controlla i titoli di "La mia lista" e avvisa quando c'è qualcosa di nuovo:
/// - serie: è uscito un nuovo episodio (TMDB);
/// - film: è uscito al cinema in Italia o in digitale;
/// - film o serie: è diventato guardabile in Lumen (video collegato da playlist) o ha nuovi episodi collegati;
/// - playlist da link: tra le novità c'è un titolo della lista.
/// Avvisa sia nella sezione Notifiche dell'app sia con una notifica di sistema.
@MainActor
final class WatchlistMonitor {
    static let shared = WatchlistMonitor()
    nonisolated static let refreshTaskId = "lumen.watchlist.refresh"

    /// Punto d'ingresso dell'aggiornamento in background.
    static func runBackgroundRefresh() async { await shared.check() }
    /// Intervallo minimo tra due controlli.
    static let interval: TimeInterval = 3 * 3600

    /// Stato noto di ogni titolo della lista all'ultimo controllo.
    private struct Snapshot: Codable {
        var lastEpisode: String?        // "s2e5" (serie)
        var cinemaNotified = false      // film
        var digitalNotified = false     // film
        var cinemaDate: Date?
        var digitalDate: Date?
        var playable = false            // video collegato (film)
        var linkedEpisodes = 0          // episodi collegati (serie)
    }

    private struct State: Codable {
        var lastCheck: Date?
        var items: [MediaItem] = []     // copia della lista, per i controlli in background
        var tmdb: ProviderConfig?
        var snapshots: [String: Snapshot] = [:]
    }

    private var state = State()
    private var running = false

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watchlist-monitor.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        }
    }

    var lastCheck: Date? { state.lastCheck }

    /// Aggiorna la copia della lista e la sorgente TMDB (chiamato con l'app aperta).
    func sync(list: [MediaItem], app: AppState) {
        if !list.isEmpty && state.items.isEmpty { Self.askPermission() }
        state.items = list
        if let t = app.config.providers.first(where: { $0.type == .tmdb && $0.isUsable }) { state.tmdb = t }
        save()
    }

    /// Esegue il controllo se è passato abbastanza tempo dall'ultimo (o subito con `force`).
    func checkIfNeeded(force: Bool = false) async {
        if !force, let last = state.lastCheck, Date().timeIntervalSince(last) < Self.interval { return }
        await check()
    }

    func check() async {
        guard !running else { return }
        running = true
        defer { running = false; Self.scheduleBackgroundRefresh() }
        await LinkLibrary.shared.loadIfNeeded()
        let tmdb = state.tmdb.map { TMDBProvider(config: $0) }
        let links = LinkLibrary.shared
        var alerts: [(String, String, String)] = []   // titolo, testo, icona

        for item in state.items {
            let first = state.snapshots[item.id] == nil
            var snap = state.snapshots[item.id] ?? Snapshot()

            // Disponibilità in Lumen (video collegati dalla playlist)
            if item.isSeries {
                let n = links.episodeCount(seriesId: item.id)
                if !first, n > snap.linkedEpisodes {
                    let added = n - snap.linkedEpisodes
                    alerts.append(("Nuovi episodi da guardare",
                                   "\(item.title): \(added == 1 ? "1 nuovo episodio disponibile" : "\(added) nuovi episodi disponibili") in Lumen.",
                                   "play.tv.fill"))
                }
                snap.linkedEpisodes = n
            } else {
                let playable = links.link(forItem: item.id) != nil
                if !first, playable, !snap.playable {
                    alerts.append(("Nuovo contenuto disponibile", "\(item.title) è ora disponibile da guardare in Lumen.", "play.circle.fill"))
                }
                snap.playable = playable
            }

            // Uscite (TMDB)
            if let tmdb, let split = try? TMDBProvider.split(item.id) {
                let kind = split.0, id = split.1
                if kind == .series, let json = try? await tmdb.get("/tv/\(id)"),
                   let last = json["last_episode_to_air"] as? [String: Any] {
                    let s = last["season_number"] as? Int ?? 0, e = last["episode_number"] as? Int ?? 0
                    let key = "s\(s)e\(e)"
                    if !first, let previous = snap.lastEpisode, previous != key {
                        let name = (last["name"] as? String).flatMap { $0.isEmpty ? nil : " «\($0)»" } ?? ""
                        let ready = links.link(seriesId: item.id, season: s, episode: e) != nil ? " È già pronto da guardare in Lumen." : ""
                        alerts.append(("Nuovo episodio disponibile", "\(item.title) · S\(s) E\(e)\(name).\(ready)", "tv.badge.wifi"))
                    }
                    snap.lastEpisode = key
                } else if kind == .movie, let json = try? await tmdb.get("/movie/\(id)", ["append_to_response": "release_dates"]) {
                    let (cinema, digital) = Self.italianDates(json, region: state.tmdb.map { $0.option("region") }.flatMap { $0.isEmpty ? nil : $0 } ?? "IT")
                    snap.cinemaDate = cinema ?? snap.cinemaDate
                    snap.digitalDate = digital ?? snap.digitalDate
                    let now = Date()
                    if let d = snap.cinemaDate, d <= now, !snap.cinemaNotified {
                        // Al primo controllo un film già uscito da tempo non genera avvisi.
                        if !first || now.timeIntervalSince(d) < 86_400 * 2 {
                            alerts.append(("Uscito al cinema", "\(item.title) è nelle sale da \(Self.dayText(d)).", "ticket.fill"))
                        }
                        snap.cinemaNotified = true
                    }
                    if let d = snap.digitalDate, d <= now, !snap.digitalNotified {
                        if !first || now.timeIntervalSince(d) < 86_400 * 2 {
                            alerts.append(("Disponibile in digitale", "\(item.title) è disponibile in streaming e noleggio da \(Self.dayText(d)).", "play.rectangle.fill"))
                        }
                        snap.digitalNotified = true
                    }
                }
            }
            state.snapshots[item.id] = snap
        }
        // Dimentica i titoli tolti dalla lista
        let ids = Set(state.items.map(\.id))
        state.snapshots = state.snapshots.filter { ids.contains($0.key) }
        state.lastCheck = Date()
        save()
        for a in alerts { deliver(title: a.0, body: a.1, icon: a.2) }
    }

    /// Le novità di una playlist da link contengono titoli della lista?
    func playlistAdded(_ added: [LinkMedia], playlistName: String) {
        guard !state.items.isEmpty, !added.isEmpty else { return }
        let wanted = Dictionary(state.items.map { (Self.norm($0.title), $0) }, uniquingKeysWith: { a, _ in a })
        var hits: [String: Int] = [:]
        for m in added where !m.isLive {
            if let item = wanted[Self.norm(ParsedTitle.parse(m.title).title)] { hits[item.title, default: 0] += 1 }
        }
        for (title, count) in hits {
            deliver(title: "Nuovo contenuto disponibile",
                    body: "\(title): \(count == 1 ? "1 nuova voce" : "\(count) nuove voci") in \(playlistName). Analizza le novità per guardarle.",
                    icon: "sparkles.tv")
        }
    }

    // MARK: Supporto

    private func deliver(title: String, body: String, icon: String) {
        NotificationStore.shared.post(AppNotification(kind: .info, title: title, body: body, icon: icon))
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func askPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            if s.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func dayText(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "oggi" : "il " + d.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "it_IT")))
    }

    private static func italianDates(_ json: [String: Any], region: String) -> (Date?, Date?) {
        let countries = (json["release_dates"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        let local = countries.first { $0["iso_3166_1"] as? String == region }
        let entries = local?["release_dates"] as? [[String: Any]] ?? []
        func date(_ types: Set<Int>) -> Date? {
            entries.filter { types.contains($0["type"] as? Int ?? 0) }
                .compactMap { ($0["release_date"] as? String).flatMap(parse) }.min()
        }
        return (date([3]) ?? date([2]), date([4]))
    }

    private static func parse(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.file, options: .atomic) }
    }

    // MARK: Aggiornamento in background

    /// Chiede a iOS di riaprire l'app in background per il prossimo controllo (quando lo ritiene opportuno).
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }
}
