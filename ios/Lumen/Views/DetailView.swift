import SwiftUI
import UIKit

struct DetailView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let item: MediaItem
    @State private var detail: MediaDetail?
    @State private var errorMessage: String?
    @State private var seasonIndex = 0
    @State private var expandedOverview = false
    @State private var watchSummary: WatchedEntry?
    @State private var trailerURL: URL?
    @State private var showTrailer = false

    private var current: MediaItem { detail?.item ?? item }
    private var canStream: Bool { app.provider.capabilities.streams }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backdrop
                VStack(alignment: .leading, spacing: 16) {
                    Text(current.title).font(.system(size: 28, weight: .bold))
                    metaRow
                    ratings
                    mainActions
                    if let p = library.resumeEntry(for: current.id), canStream {
                        progressInfo(p)
                    }
                    overview
                    credits
                    actions
                    if let detail, !detail.cast.isEmpty {
                        castCarousel(detail.cast)
                    }
                    if let detail, !detail.watchProviders.isEmpty {
                        whereToWatch(detail)
                    }
                    if let detail, !detail.seasons.isEmpty {
                        episodes(detail)
                    } else if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack {
                Color.black
                RemoteImage(url: current.bestWideImage)
                    .blur(radius: 60)
                    .opacity(0.45)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
            .padding(14)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(.black)
        .presentationCornerRadius(34)
        .preferredColorScheme(.dark)
        .playbackHUD()
        .sheet(item: $watchSummary) { WatchTimeView(highlight: $0) }
        .fullScreenCover(isPresented: $showTrailer) {
            if let trailerURL { TrailerPlayerView(title: current.title, url: trailerURL) }
        }
        .task(id: app.contentKey) { await load() }
    }

    // MARK: Testata

    private var backdrop: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(RemoteImage(url: current.bestWideImage))
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom))
            .overlay {
                if canStream || detail?.trailer != nil {
                    Button { primaryAction() } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 24))
                            .frame(width: 62, height: 62)
                    }
                    .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                }
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28, style: .continuous))
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            if let year = current.year { Text(String(year)) }
            if let rating = current.rating {
                Text(rating)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .liquidGlassCapsule()
            }
            if let seasons = detail?.seasons, current.isSeries, !seasons.isEmpty {
                Text(seasons.count == 1 ? "1 stagione" : "\(seasons.count) stagioni")
            } else if let d = detail?.duration, d > 0 {
                Text(formatDuration(d))
            }
            Text(current.isSeries ? "Serie TV" : "Film")
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.secondaryText)
    }

    @ViewBuilder
    private var ratings: some View {
        let hasAny = current.scoreLabel != nil || detail?.imdbRating != nil
        if hasAny {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if let score = current.scoreLabel {
                        ratingChip(label: "TMDB", value: score, icon: "star.fill", tint: app.accent)
                    }
                    if let imdb = detail?.imdbRating {
                        ratingChip(label: "IMDb", value: imdb, icon: "star.fill",
                                   tint: Color(red: 0.96, green: 0.77, blue: 0.09))
                    }
                }
            }
        }
    }

    private func ratingChip(label: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.system(size: 15, weight: .bold))
            Text("/10 \(label)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .liquidGlassCapsule()
    }

    @ViewBuilder
    private var mainActions: some View {
        if canStream {
            PrimaryButton(title: resumeTitle) { primaryAction() }
        }
        if let trailer = detail?.trailer {
            if canStream {
                SecondaryButton(title: "Guarda il trailer", icon: "play.rectangle") { playTrailer(trailer) }
            } else {
                PrimaryButton(title: "Guarda il trailer", icon: "play.rectangle.fill") { playTrailer(trailer) }
            }
        }
    }

    private func playTrailer(_ url: URL) {
        trailerURL = url
        showTrailer = true
    }

    private func primaryAction() {
        if canStream {
            Task { await Playback.play(item: current, app: app, library: library) }
        } else if let trailer = detail?.trailer {
            playTrailer(trailer)
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let text = current.overview {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(expandedOverview ? nil : 5)
                .onTapGesture { withAnimation { expandedOverview.toggle() } }
        } else if detail != nil {
            Text("Trama non disponibile in italiano.").font(.subheadline).foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private var credits: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let genres = detail?.genres, !genres.isEmpty {
                (Text("Generi: ").foregroundColor(Theme.secondaryText) + Text(genres.joined(separator: ", ")))
            }
            if let director = detail?.director {
                (Text(current.isSeries ? "Ideata da: " : "Regia: ").foregroundColor(Theme.secondaryText) + Text(director))
            }
        }
        .font(.footnote)
    }

    private var resumeTitle: String {
        guard let p = library.resumeEntry(for: current.id) else { return "Riproduci" }
        if let label = p.episodeLabel, let code = label.components(separatedBy: " ").first {
            return "Riprendi \(code)"
        }
        return "Riprendi"
    }

    private func progressInfo(_ p: WatchProgress) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: p.fraction).tint(app.accent)
            Text("\(formatTime(max(0, p.duration - p.position))) rimanenti")
                .font(.caption).foregroundStyle(Theme.secondaryText)
        }
    }

    private var actions: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                actionButton(library.contains(current) ? "checkmark" : "plus", "La mia lista") {
                    withAnimation { library.toggle(current) }
                }
                watchedButton
                ShareLink(item: current.title, message: Text(current.overview ?? "")) {
                    actionLabel("square.and.arrow.up", "Condividi")
                }
                .buttonStyle(GlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))))
                if let link = detail?.watchLink {
                    actionButton("tv", "Dove vederlo") { openURL(link) }
                }
            }
        }
    }

    private var watchedButton: some View {
        let seen = library.isWatched(current.id)
        return Button {
            if seen {
                withAnimation { library.unmarkWatched(current.id) }
            } else {
                let entry = WatchedEntry.make(item: current, detail: detail)
                withAnimation { library.markWatched(entry) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                watchSummary = entry
            }
        } label: {
            actionLabel(seen ? "eye.fill" : "eye", seen ? "Visto ✓" : "Visto")
        }
        .buttonStyle(GlassButtonStyle(tint: seen ? app.accent : nil,
                                      shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))))
    }

    private func actionButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon, title) }
            .buttonStyle(GlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))))
    }

    private func actionLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: Cast

    private func castCarousel(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(cast) { person in
                        VStack(spacing: 6) {
                            Group {
                                if person.photo != nil {
                                    ImageTile(url: person.photo, width: 76, height: 76, corner: 38)
                                } else {
                                    Circle().fill(.white.opacity(0.12)).frame(width: 76, height: 76)
                                        .overlay(Text(person.name.prefix(1)).font(.title2.bold()))
                                }
                            }
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.6))
                            Text(person.name).font(.caption.weight(.semibold)).lineLimit(2)
                                .multilineTextAlignment(.center)
                            if let character = person.character {
                                Text(character).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: 86)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Dove guardarlo

    private func whereToWatch(_ detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Disponibile su").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(detail.watchProviders) { p in
                        Button { if let link = detail.watchLink { openURL(link) } } label: {
                            VStack(spacing: 6) {
                                ImageTile(url: p.logo, width: 54, height: 54, corner: 14)
                                Text(p.name).font(.caption2).lineLimit(1).frame(width: 70)
                                Text(label(for: p.type)).font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .liquidGlassCard(radius: 22)
            }
            .scrollIndicators(.hidden)
            Text("Dati sulla disponibilità forniti da JustWatch tramite TMDB.")
                .font(.caption2).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func label(for type: String?) -> String {
        switch type {
        case "flatrate": return "Abbonamento"
        case "free", "ads": return "Gratis"
        case "rent": return "Noleggio"
        case "buy": return "Acquisto"
        default: return ""
        }
    }

    // MARK: Episodi

    @ViewBuilder
    private func episodes(_ detail: MediaDetail) -> some View {
        let seasons = detail.seasons
        let index = min(seasonIndex, seasons.count - 1)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Episodi").font(.headline)
                Spacer()
                if seasons.count > 1 {
                    Menu {
                        ForEach(Array(seasons.enumerated()), id: \.element.id) { i, s in
                            Button(s.displayTitle) { seasonIndex = i }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(seasons[index].displayTitle)
                            Image(systemName: "chevron.down").font(.caption)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .liquidGlassCapsule(interactive: true)
                    }
                }
            }
            ForEach(seasons[index].episodes) { episode in
                EpisodeRow(episode: episode, fallbackImage: current.bestWideImage, playable: canStream) {
                    Task {
                        await Playback.play(item: current, episode: episode,
                                            episodeLabel: detail.label(for: episode), app: app, library: library)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func load() async {
        do {
            detail = try await app.provider.detail(id: item.id)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(1, m)) min"
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let fallbackImage: URL?
    var playable = true
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { if playable { play() } }) {
                HStack(spacing: 12) {
                    ImageTile(url: episode.still ?? fallbackImage, width: 130, height: 74, corner: 12)
                        .overlay {
                            if playable {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13))
                                    .frame(width: 32, height: 32)
                                    .liquidGlass(in: Circle())
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(episode.number). \(episode.title)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if let d = episode.durationLabel {
                            Text(d).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
            }
        }
        .padding(10)
        .liquidGlassCard(radius: 20)
    }
}
