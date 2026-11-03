import SwiftUI
import Observation

/// Un trofeo/obiettivo, con avanzamento verso il traguardo.
struct Achievement: Identifiable, Hashable {
    enum Tier: Int { case bronze, silver, gold, platinum }

    var id: String
    var title: String
    var detail: String
    var icon: String
    var category: String
    var tier: Tier
    var current: Int
    var target: Int

    var unlocked: Bool { current >= target }
    var fraction: Double { min(1, Double(current) / Double(max(1, target))) }

    var color: Color {
        switch tier {
        case .bronze: return Color(red: 0.8, green: 0.52, blue: 0.3)
        case .silver: return Color(red: 0.78, green: 0.8, blue: 0.86)
        case .gold: return Color(red: 1, green: 0.8, blue: 0.2)
        case .platinum: return Color(red: 0.55, green: 0.85, blue: 1)
        }
    }
}

@MainActor
enum Achievements {
    static func evaluate(_ library: Library) -> [Achievement] {
        let t = library.totals
        let hours = t.totalMinutes / 60
        let taste = library.taste

        // Date di visione (film, serie complete ed episodi)
        var dates: [Date] = library.watched.values.map(\.date)
        for s in library.seriesWatch.values { dates.append(contentsOf: s.episodes.values.map(\.date)) }
        let cal = Calendar.current
        let days = Set(dates.map { cal.startOfDay(for: $0) })
        let nights = dates.filter { (0...4).contains(cal.component(.hour, from: $0)) }.count
        let weekends = dates.filter { cal.isDateInWeekend($0) }.count
        let streak = longestStreak(days)
        let genresSeen = taste.weights.count
        let topGenreTitles = topGenreCount(library)
        let completedSeries = library.seriesWatch.values.filter { $0.totalEpisodes > 0 && $0.episodes.count >= $0.totalEpisodes }.count
            + library.watched.values.filter { $0.isSeries && library.seriesWatch[$0.id] == nil }.count
        let bestEpisodesInDay = Dictionary(grouping: library.seriesWatch.values.flatMap { $0.episodes.values.map(\.date) }) {
            cal.startOfDay(for: $0)
        }.values.map(\.count).max() ?? 0

        func a(_ id: String, _ title: String, _ detail: String, _ icon: String, _ cat: String,
               _ tier: Achievement.Tier, _ cur: Int, _ target: Int) -> Achievement {
            Achievement(id: id, title: title, detail: detail, icon: icon, category: cat, tier: tier, current: cur, target: target)
        }

        return [
            a("movie-1", "Primo ciak", "Segna come visto il tuo primo film", "film", "Film", .bronze, t.movies, 1),
            a("movie-10", "Cinefilo", "Guarda 10 film", "film.stack", "Film", .silver, t.movies, 10),
            a("movie-50", "Habitué della sala", "Guarda 50 film", "popcorn.fill", "Film", .gold, t.movies, 50),
            a("movie-100", "Leggenda del cinema", "Guarda 100 film", "trophy.fill", "Film", .platinum, t.movies, 100),

            a("ep-1", "Pilota", "Guarda il primo episodio di una serie", "tv", "Serie TV", .bronze, t.episodes, 1),
            a("ep-100", "Seriale", "Guarda 100 episodi", "tv.inset.filled", "Serie TV", .silver, t.episodes, 100),
            a("ep-500", "Divoratore di stagioni", "Guarda 500 episodi", "play.tv.fill", "Serie TV", .gold, t.episodes, 500),
            a("series-done-1", "Titoli di coda", "Completa una serie intera", "checkmark.seal.fill", "Serie TV", .silver, completedSeries, 1),
            a("series-done-10", "Finale di stagione", "Completa 10 serie", "rosette", "Serie TV", .gold, completedSeries, 10),
            a("binge", "Binge watcher", "Guarda 6 episodi nello stesso giorno", "bolt.fill", "Serie TV", .silver, bestEpisodesInDay, 6),

            a("hours-10", "Riscaldamento", "Raggiungi 10 ore di visione", "hourglass.bottomhalf.filled", "Tempo", .bronze, hours, 10),
            a("hours-100", "Cento ore", "Raggiungi 100 ore di visione", "hourglass", "Tempo", .silver, hours, 100),
            a("hours-500", "Divano d'oro", "Raggiungi 500 ore di visione", "sofa.fill", "Tempo", .gold, hours, 500),
            a("hours-1000", "Mille ore", "Raggiungi 1.000 ore di visione", "crown.fill", "Tempo", .platinum, hours, 1000),

            a("genres-5", "Esploratore", "Guarda titoli di 5 generi diversi", "map.fill", "Gusti", .bronze, genresSeen, 5),
            a("genres-12", "Onnivoro", "Guarda titoli di 12 generi diversi", "globe.europe.africa.fill", "Gusti", .gold, genresSeen, 12),
            a("specialist", "Specialista", "Guarda 15 titoli del tuo genere preferito", "star.circle.fill", "Gusti", .silver, topGenreTitles, 15),
            a("both", "Doppia vita", "Guarda almeno 5 film e 5 serie", "rectangle.on.rectangle", "Gusti", .silver,
              min(t.movies, t.series), 5),

            a("list-10", "Collezionista", "Aggiungi 10 titoli alla tua lista", "plus.rectangle.on.rectangle", "Abitudini", .bronze, library.myList.count, 10),
            a("night", "Nottambulo", "Guarda qualcosa tra mezzanotte e le 5", "moon.stars.fill", "Abitudini", .bronze, nights, 1),
            a("weekend", "Weekend sul divano", "Guarda 10 titoli o episodi nel weekend", "calendar", "Abitudini", .silver, weekends, 10),
            a("streak-7", "Costanza", "Guarda qualcosa per 7 giorni di fila", "flame.fill", "Abitudini", .gold, streak, 7),
            a("days-30", "Abbonato fedele", "Guarda qualcosa in 30 giorni diversi", "calendar.badge.checkmark", "Abitudini", .gold, days.count, 30),
        ]
    }

    private static func longestStreak(_ days: Set<Date>) -> Int {
        let cal = Calendar.current
        var best = 0
        for d in days where !days.contains(cal.date(byAdding: .day, value: -1, to: d)!) {
            var len = 1
            var cur = d
            while let next = cal.date(byAdding: .day, value: 1, to: cur), days.contains(next) { len += 1; cur = next }
            best = max(best, len)
        }
        return best
    }

    private static func topGenreCount(_ library: Library) -> Int {
        var counts: [String: Int] = [:]
        var items = library.watched.values.map(\.item)
        items += library.seriesWatch.values.filter { library.watched[$0.id] == nil && !$0.episodes.isEmpty }.map(\.item)
        for i in items { for g in i.tags ?? [] { counts[g, default: 0] += 1 } }
        return counts.values.max() ?? 0
    }
}

/// Ricorda i trofei sbloccati e mostra un avviso quando se ne sblocca uno nuovo.
@MainActor
@Observable
final class AchievementTracker {
    static let shared = AchievementTracker()
    private let key = "lumen.achievements.unlocked"

    private(set) var unlocked: Set<String>
    var recent: Achievement?

    private init() {
        unlocked = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func check(_ library: Library, announce: Bool = true) {
        let firstRun = UserDefaults.standard.object(forKey: key) == nil
        let now = Achievements.evaluate(library).filter(\.unlocked)
        let new = now.filter { !unlocked.contains($0.id) }
        guard !new.isEmpty || firstRun else { return }
        unlocked.formUnion(now.map(\.id))
        UserDefaults.standard.set(Array(unlocked), forKey: key)
        // Al primo avvio i trofei già raggiunti vengono registrati senza avvisi.
        guard announce, !firstRun, let best = new.max(by: { $0.tier.rawValue < $1.tier.rawValue }) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { recent = best }
        for a in new {
            NotificationStore.shared.post(AppNotification(kind: .trophy, title: "Trofeo sbloccato: \(a.title)",
                                                          body: a.detail, icon: "trophy.fill"))
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if recent?.id == best.id { withAnimation { recent = nil } }
        }
    }
}

/// Avviso "Trofeo sbloccato".
struct AchievementToast: View {
    @State private var tracker = AchievementTracker.shared

    var body: some View {
        if let a = tracker.recent {
            HStack(spacing: 12) {
                Image(systemName: a.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(a.color)
                    .frame(width: 44, height: 44)
                    .liquidGlass(in: Circle(), tint: a.color.opacity(0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trofeo sbloccato!").font(.caption.weight(.bold)).foregroundStyle(a.color)
                    Text(a.title).font(.subheadline.weight(.semibold))
                    Text(a.detail).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(12)
            .liquidGlassCard(radius: 24, tint: a.color.opacity(0.25))
            .padding(.horizontal, 16)
            .onTapGesture { withAnimation { tracker.recent = nil } }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Bacheca dei trofei e degli obiettivi.
struct AchievementsView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let all = Achievements.evaluate(library)
        let done = all.filter(\.unlocked).count
        let categories = all.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let next = all.filter { !$0.unlocked }.max { $0.fraction < $1.fraction }

        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
                        Text("\(done) di \(all.count) trofei")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                        ProgressView(value: Double(done), total: Double(all.count)).tint(app.accent)
                            .padding(.horizontal, 30)
                        if let next {
                            Text("Prossimo obiettivo: \(next.title) · \(min(next.current, next.target))/\(next.target)")
                                .font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .liquidGlassCard(radius: 30, tint: app.accent.opacity(0.35))

                    ForEach(categories, id: \.self) { cat in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(cat).font(.headline).padding(.leading, 4)
                            ForEach(all.filter { $0.category == cat }) { row($0) }
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(AuroraBackground(accent: app.accent).opacity(0.6))
            .navigationTitle("Trofei e obiettivi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ a: Achievement) -> some View {
        HStack(spacing: 14) {
            Image(systemName: a.unlocked ? a.icon : "lock.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(a.unlocked ? a.color : .white.opacity(0.4))
                .frame(width: 46, height: 46)
                .liquidGlass(in: Circle(), tint: a.unlocked ? a.color.opacity(0.35) : nil)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(a.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(a.unlocked ? "Sbloccato" : "\(min(a.current, a.target))/\(a.target)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(a.unlocked ? a.color : Theme.secondaryText)
                }
                Text(a.detail).font(.caption).foregroundStyle(Theme.secondaryText)
                if !a.unlocked {
                    ProgressView(value: a.fraction).tint(a.color)
                }
            }
        }
        .padding(12)
        .liquidGlassCard(radius: 20)
        .opacity(a.unlocked ? 1 : 0.85)
    }
}
