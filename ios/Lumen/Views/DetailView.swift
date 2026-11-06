import SwiftUI
import UIKit

struct DetailView: View {
    @Environment(AuthStore.self) private var auth
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
    @State private var trailer: TrailerItem?
    @State private var sagaItem: MediaItem?
    @State private var showManualMatch = false
    @State private var recapText: String?
    @State private var recapLoading = false
    @State private var recapError: String?
    @State private var previewPlaying = false
    @State private var previewMuted = true
    @State private var previewPaused = false
    /// Trailer fermato dall'utente (tocco sul video o pulsante pausa).
    @State private var previewStopped = false
    /// "Perché te lo consiglio" (Apple Intelligence, con ripiego semplice).
    @State private var whyText: String?
    /// Trama tradotta in italiano quando TMDB ha solo quella inglese.
    @State private var translatedOverview: String?
    @State private var translating = false

    private var current: MediaItem { detail?.item ?? item }
    private var canStream: Bool { app.provider.capabilities.streams }
    private var links: LinkLibrary { LinkLibrary.shared }
    /// Video da link abbinato a questo film.
    private var movieLink: LinkMedia? { current.isSeries ? nil : links.link(forItem: current.id) }

    private func episodeLink(_ episode: Episode, in detail: MediaDetail) -> LinkMedia? {
        guard let season = detail.seasons.first(where: { $0.episodes.contains(episode) }) else { return nil }
        return links.link(seriesId: current.id, season: season.number, episode: episode.number)
    }

    /// Prima puntata disponibile da link (per il tasto Riproduci delle serie).
    private var firstLinkedEpisode: (Episode, LinkMedia)? {
        guard let detail, current.isSeries, links.hasLinks(seriesId: current.id) else { return nil }
        let resumeId = library.resumeEntry(for: current.id)?.episodeId
        let all = detail.seasons.flatMap(\.episodes)
        if let id = resumeId, let e = all.first(where: { $0.id == id }), let l = episodeLink(e, in: detail) { return (e, l) }
        for e in all { if let l = episodeLink(e, in: detail) { return (e, l) } }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backdrop
                VStack(alignment: .leading, spacing: 16) {
                    if let fresh = FreshnessStore.shared.badge(for: current.id) { FreshBadge(kind: fresh) }
                    Text(current.title).font(.system(size: 28, weight: .bold))
                    metaRow
                    ratings
                    releasesCard
                    recapCard
                    customMatchCard
                    mainActions
                    suggestionControl
                    if auth.isAdmin && (movieLink != nil || seriesHasLinks) {
                        Button(role: .destructive) {
                            withAnimation { links.removeMatch(itemId: current.id) }
                        } label: {
                            Label("Rimuovi video collegato da link", systemImage: "link.badge.minus")
                                .font(.footnote)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red.opacity(0.85))
                    }
                    if let p = library.resumeEntry(for: current.id), canStream {
                        progressInfo(p)
                    }
                    overview
                    credits
                    actions
                    if let detail, detail.collection.count > 1 {
                        sagaSection(detail)
                    }
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
                // Con il trailer a tutta pagina titolo e dati stanno sopra la parte bassa del video
                .padding(.top, previewId != nil ? -112 : 0)
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
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.6))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 16)
            .zIndex(10)
            .accessibilityLabel("Chiudi")
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(.black)
        .presentationCornerRadius(34)
        .preferredColorScheme(.dark)
        .playbackHUD()
        .sheet(item: $watchSummary) { WatchTimeView(highlight: $0) }
        .sheet(item: $sagaItem) { DetailView(item: $0) }
        .fullScreenCover(item: $trailer) { t in
            TrailerPlayerView(title: current.title, url: t.url)
        }
        .task(id: app.contentKey) { await load() }
        .task(id: (detail?.item.id ?? "") + "|\(library.activitySignature)") { await loadAIExtras() }
    }

    private func close() {
        if app.detailItem?.id == item.id { app.detailItem = nil }
        dismiss()
    }

    // MARK: Testata

    private var previewId: String? { detail?.trailer.flatMap { TrailerPlayerView.videoId(from: $0) } }

    private var backdrop: some View {
        let hasTrailer = previewId != nil
        return Color.clear
            // Con il trailer: anteprima alta a tutta pagina (come le app di streaming), senza controlli di YouTube.
            .aspectRatio(hasTrailer ? 0.82 : 16.0 / 9.0, contentMode: .fit)
            // La locandina si vede solo finché il trailer non parte, poi sparisce del tutto
            .overlay(RemoteImage(url: hasTrailer ? (current.bestPosterImage ?? current.bestWideImage) : current.bestWideImage)
                .opacity(hasTrailer && previewPlaying ? 0 : 1)
                .animation(.easeInOut(duration: 0.6), value: previewPlaying))
            .background(Color.black)
            .overlay {
                if let id = previewId {
                    TrailerPreview(videoId: id, muted: previewMuted, paused: previewPaused || trailer != nil || previewStopped,
                                   controls: false, autoplay: true, cover: true, playing: $previewPlaying)
                        .opacity(previewPlaying ? 1 : 0)
                        .animation(.easeInOut(duration: 0.6), value: previewPlaying)
                        .allowsHitTesting(false)
                }
            }
            // Locandina e video riempiono l'anteprima ma non devono uscirne (finivano sotto al testo)
            .clipped()
            .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.22),
                                            .init(color: .clear, location: 0.5), .init(color: .black.opacity(hasTrailer ? 1 : 0.7), location: 1)],
                                    startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false))
            .contentShape(Rectangle())
            .onTapGesture { if hasTrailer && previewPlaying { withAnimation { previewStopped.toggle() } } }
            .overlay {
                if hasTrailer && previewStopped {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .frame(width: 70, height: 70)
                        .liquidGlass(in: Circle())
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if !hasTrailer && (canStream || movieLink != nil || firstLinkedEpisode != nil) {
                    Button { primaryAction() } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 24))
                            .frame(width: 62, height: 62)
                    }
                    .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Pausa/riprendi e audio del trailer
                if hasTrailer && previewPlaying {
                    VStack(spacing: 10) {
                        Button { withAnimation { previewStopped.toggle() } } label: {
                            Image(systemName: previewStopped ? "play.fill" : "pause.fill")
                                .font(.system(size: 14, weight: .bold)).frame(width: 40, height: 40)
                        }
                        .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                        Button { previewMuted.toggle() } label: {
                            Image(systemName: previewMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .bold)).frame(width: 40, height: 40)
                        }
                        .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                    }
                    .foregroundStyle(.white)
                    .padding(.trailing, 16)
                    .padding(.bottom, 128)
                    .transition(.opacity)
                }
            }
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

    /// Gli altri film della stessa saga, in ordine di uscita, con il capitolo attuale evidenziato.
    private func sagaSection(_ detail: MediaDetail) -> some View {
        let parts = detail.collection
        let index = parts.firstIndex { $0.id == current.id }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.collectionName ?? "La saga").font(.headline)
                Text(index.map { i -> String in
                    let before = i, after = parts.count - i - 1
                    var text = "Capitolo \(i + 1) di \(parts.count)"
                    if before > 0 { text += " · \(before == 1 ? "1 precedente" : "\(before) precedenti")" }
                    if after > 0 { text += " · \(after == 1 ? "1 successivo" : "\(after) successivi")" }
                    return text
                } ?? "\(parts.count) film")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
                            let isCurrent = part.id == current.id
                            Button { if !isCurrent { sagaItem = part } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    PosterCard(item: part, width: 104)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(isCurrent ? app.accent : .clear, lineWidth: 2.5)
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            Text("\(i + 1)")
                                                .font(.system(size: 11, weight: .heavy))
                                                .frame(width: 22, height: 22)
                                                .background(isCurrent ? app.accent : .black.opacity(0.6), in: Circle())
                                                .padding(4)
                                        }
                                    Text(isCurrent ? "Stai guardando"
                                         : ([part.year.map(String.init), index.map { i < $0 ? "prima" : "dopo" }]
                                            .compactMap { $0 }.joined(separator: " · ")))
                                        .font(.caption2.weight(isCurrent ? .bold : .regular))
                                        .foregroundStyle(isCurrent ? app.accent : Theme.secondaryText)
                                    if links.link(forItem: part.id) != nil {
                                        Label("Disponibile", systemImage: "play.fill")
                                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                                    }
                                }
                                .frame(width: 104, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .id(part.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
                // Si vede anche il capitolo precedente (prima la riga partiva dal film aperto e i precedenti restavano nascosti a sinistra)
                .onAppear {
                    guard let index else { return }
                    proxy.scrollTo(parts[max(0, index - 1)].id, anchor: .leading)
                }
            }
        }
    }

    /// Contenuto aggiunto senza scheda: l'amministratore può abbinarlo a una scheda TMDB.
    @ViewBuilder
    private var customMatchCard: some View {
        if current.id.hasPrefix("link-"), auth.isAdmin {
            Button { showManualMatch = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "link.badge.plus").font(.title3).foregroundStyle(app.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Abbina a una scheda del catalogo").font(.subheadline.weight(.semibold))
                        Text("Aggiunge trama, cast, voti e trailer da TMDB").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .buttonStyle(GlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous))))
            .sheet(isPresented: $showManualMatch) {
                ManualMatchSheet(query: current.title, year: current.year, isSeries: current.isSeries) { picked in
                    let old = current
                    if old.isSeries, let eps = links.episodeLinks[old.id] {
                        links.matchManually(series: eps, to: picked)
                    } else if let media = links.link(forItem: old.id) {
                        links.matchManually(movie: media, to: picked)
                    }
                    // Riapre la scheda completa del titolo abbinato
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        app.detailItem = picked
                    }
                }
            }
        }
    }

    /// "Dove eravamo rimasti?": riassunto con Apple Intelligence fino all'ultimo episodio visto.
    @ViewBuilder
    private var recapCard: some View {
        if current.isSeries, let detail, !detail.seasons.isEmpty,
           let last = SeriesRecap.lastWatched(seriesId: current.id, library: library) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Dove eravamo rimasti?", systemImage: "sparkles").font(.headline)
                    Spacer()
                    Text("fino a S\(last.season) E\(last.episode)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if let text = recapText ?? SeriesRecap.cached(seriesId: current.id, upTo: last) {
                    Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    Text("Riassunto generato da Apple Intelligence: può contenere imprecisioni.")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                } else if recapLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(app.accent)
                        Text("Sto ripercorrendo gli episodi visti…").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    if let recapError { Text(recapError).font(.caption).foregroundStyle(.orange) }
                    Button {
                        recapLoading = true
                        recapError = nil
                        Task {
                            do { recapText = try await SeriesRecap.generate(title: current.title, seriesId: current.id, detail: detail, upTo: last) }
                            catch { recapError = error.localizedDescription }
                            recapLoading = false
                        }
                    } label: {
                        Text("Riassumi senza spoiler").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                    .buttonStyle(GlassButtonStyle(tint: app.accent.opacity(0.6)))
                    .foregroundStyle(.white)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(radius: 20)
        }
    }

    @ViewBuilder
    private var releasesCard: some View {
        if let list = detail?.releases, !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(list, id: \.self) { r in
                    HStack(spacing: 10) {
                        Image(systemName: r.icon).foregroundStyle(app.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.label).font(.caption).foregroundStyle(Theme.secondaryText)
                            Text(r.date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "it_IT"))))
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        if let when = Self.relative(r.date) {
                            Text(when).font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .liquidGlassCapsule(tint: app.accent.opacity(0.35))
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(radius: 20)
        }
    }

    /// "tra 12 giorni" / "domani" / "oggi" per le date future.
    private static func relative(_ date: Date) -> String? {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return nil
        case 0: return "Oggi"
        case 1: return "Domani"
        default: return "Tra \(days) giorni"
        }
    }

    /// Spiegazione della compatibilità e traduzione della trama, generate sul telefono.
    private func loadAIExtras() async {
        guard let detail else { return }
        let genres = detail.genres.isEmpty ? (detail.item.tags ?? []) : detail.genres
        if library.taste.compatibility(detail.item, genres: genres) != nil {
            let sig = library.activitySignature
            let similar = WhyRecommend.similarSeen(genres: genres, excluding: detail.item.id, title: detail.item.title, library: library)
            whyText = WhyRecommend.cached(detail.item.id, signature: sig) ?? WhyRecommend.fallback(similar: similar, genres: genres)
            if let ai = await WhyRecommend.generate(item: detail.item, overview: detail.item.overview, genres: genres,
                                                    similar: similar, signature: sig) {
                withAnimation { whyText = ai }
            }
        } else {
            whyText = nil
        }
        if detail.overviewIsEnglish, let text = detail.item.overview {
            translatedOverview = PlotWriter.cachedTranslation(detail.item.id)
            guard translatedOverview == nil, AIText.isAvailable else { return }
            translating = true
            let t = await PlotWriter.translate(id: detail.item.id, text: text)
            translating = false
            if let t { withAnimation { translatedOverview = t } }
        }
    }

    /// "Scarta" per i titoli proposti nelle categorie su misura (o "Ripristina" se scartato).
    @ViewBuilder
    private var suggestionControl: some View {
        let filter = SuggestionFilter.shared
        if filter.isDismissed(current.id) {
            Button { withAnimation { filter.restore(current.id) } } label: {
                Label("Scartato dai consigli · Ripristina", systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondaryText)
        } else if PersonalRows.shared.rows.contains(where: { $0.items.contains { $0.id == current.id } }) {
            Button { withAnimation { filter.dismiss(current) } } label: {
                Label("Non mi interessa: non propormelo più", systemImage: "hand.thumbsdown")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private var whyRow: some View {
        if let whyText {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(app.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Perché te lo consiglio").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondaryText)
                    Text(whyText).font(.system(size: 14)).foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var ratings: some View {
        let match = library.taste.compatibility(current, genres: detail?.genres)
        let hasAny = current.scoreLabel != nil || detail?.imdbRating != nil || match != nil
        if match != nil { whyRow }
        if hasAny {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if let match { MatchBadge(percent: match) }
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
        } else if let link = movieLink {
            PrimaryButton(title: resumeTitle) {
                Playback.playLink(link, as: current, episodeId: nil, episodeLabel: nil, library: library)
            }
        } else if let pair = firstLinkedEpisode, let detail {
            PrimaryButton(title: library.resumeEntry(for: current.id) != nil ? resumeTitle
                          : "Riproduci S\(detail.seasons.first { $0.episodes.contains(pair.0) }?.number ?? 1):E\(pair.0.number)") {
                Playback.playLink(pair.1, as: current, episodeId: pair.0.id, episodeLabel: detail.label(for: pair.0),
                                  library: library)
            }
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
        trailer = TrailerItem(url: url)
    }

    private func primaryAction() {
        previewPaused = true
        if !canStream, let link = movieLink {
            Playback.playLink(link, as: current, episodeId: nil, episodeLabel: nil, library: library)
            return
        }
        if !canStream, let pair = firstLinkedEpisode, let detail {
            Playback.playLink(pair.1, as: current, episodeId: pair.0.id, episodeLabel: detail.label(for: pair.0),
                              library: library)
            return
        }
        if canStream {
            Task { await Playback.play(item: current, app: app, library: library) }
        } else if let trailer = detail?.trailer {
            playTrailer(trailer)
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let text = translatedOverview ?? current.overview {
          VStack(alignment: .leading, spacing: 4) {
            if detail?.overviewIsEnglish == true {
                Label(translatedOverview != nil ? "Trama tradotta con Apple Intelligence" : (translating ? "Traduzione in corso…" : "Trama disponibile solo in inglese"),
                      systemImage: translatedOverview != nil ? "sparkles" : "globe")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(expandedOverview ? nil : 5)
                .onTapGesture { withAnimation { expandedOverview.toggle() } }
          }
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
                downloadButton
                shareButton
                if let link = detail?.watchLink {
                    actionButton("tv", "Dove vederlo") { openURL(link) }
                }
            }
        }
    }

    /// Condivide il link del trailer (WhatsApp, Messaggi, Instagram, ecc.); se non c'è il trailer, il titolo.
    @ViewBuilder
    private var shareButton: some View {
        let style = GlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        if let trailer = detail?.trailer {
            ShareLink(item: trailer,
                      subject: Text("Trailer di \(current.title)"),
                      message: Text("Guarda il trailer di \(current.title)\(current.year.map { " (\($0))" } ?? "") 🎬")) {
                actionLabel("square.and.arrow.up", "Condividi")
            }
            .buttonStyle(style)
        } else {
            ShareLink(item: current.title, message: Text("Trailer non disponibile per \(current.title)")) {
                actionLabel("square.and.arrow.up", "Condividi")
            }
            .buttonStyle(style)
            .disabled(detail == nil)
        }
    }

    @ViewBuilder
    private var watchedButton: some View {
        if current.isSeries {
            seriesWatchedButton
        } else {
            movieWatchedButton
        }
    }

    private var allEpisodes: [Episode] { detail?.seasons.flatMap(\.episodes) ?? [] }

    private var seriesWatchedButton: some View {
        let count = library.watchedEpisodeCount(seriesId: current.id)
        let total = allEpisodes.count
        return Menu {
            Button("Segna tutti gli episodi come visti", systemImage: "eye") {
                library.setEpisodes(allEpisodes, watched: true, item: current, detail: detail)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            .disabled(total == 0)
            if count > 0 || library.isWatched(current.id) {
                Button("Rimuovi tutti gli episodi visti", systemImage: "eye.slash", role: .destructive) {
                    library.unmarkWatched(current.id)
                }
            }
            Button("Tempo davanti alla TV", systemImage: "hourglass") {
                watchSummary = library.watchedList.first { $0.id == current.id }
                    ?? WatchedEntry(item: current, minutes: 0, episodes: 0, estimated: false, date: Date())
            }
        } label: {
            actionLabel(count > 0 ? "eye.fill" : "eye", total > 0 ? "Visti \(count)/\(total)" : "Visti \(count)")
                .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                             tint: count > 0 ? app.accent : nil)
        }
    }

    private var movieWatchedButton: some View {
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
            seasonToggle(seasons[index], detail: detail)
            ForEach(seasons[index].episodes) { episode in
                EpisodeRow(episode: episode, fallbackImage: current.bestWideImage,
                           playable: canStream || episodeLink(episode, in: detail) != nil,
                           download: downloads.record(itemId: current.id, episodeId: episode.id),
                           onDownload: episodeDownloadAction(episode, detail: detail),
                           watched: library.isEpisodeWatched(seriesId: current.id, episodeId: episode.id),
                           toggleWatched: {
                               withAnimation(.snappy) { library.toggleEpisode(episode, item: current, detail: detail) }
                               UIImpactFeedbackGenerator(style: .light).impactOccurred()
                           }) {
                    if !canStream, let link = episodeLink(episode, in: detail) {
                        Playback.playLink(link, as: current, episodeId: episode.id,
                                          episodeLabel: detail.label(for: episode), library: library)
                    } else {
                        Task {
                            await Playback.play(item: current, episode: episode,
                                                episodeLabel: detail.label(for: episode), app: app, library: library)
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func seasonToggle(_ season: Season, detail: MediaDetail) -> some View {
        let seen = season.episodes.filter { library.isEpisodeWatched(seriesId: current.id, episodeId: $0.id) }.count
        let complete = seen == season.episodes.count && seen > 0
        return Button {
            withAnimation(.snappy) {
                library.setEpisodes(season.episodes, watched: !complete, item: current, detail: detail)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: complete ? "checkmark.circle.fill" : "circle.dashed")
                Text(complete ? "\(season.displayTitle) vista" : "Segna \(season.displayTitle.lowercased()) come vista")
                Spacer()
                Text("\(seen)/\(season.episodes.count)").foregroundStyle(Theme.secondaryText)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
        .buttonStyle(GlassButtonStyle(tint: complete ? app.accent : nil))
    }

    private func load() async {
        // Contenuti aggiunti senza scheda: scheda costruita in locale.
        if let local = links.localDetail(for: item) { detail = local; errorMessage = nil; return }
        do {
            detail = try await app.provider.detail(id: item.id)
            errorMessage = nil
            // Tiene aggiornata la scheda salvata offline, se c'è.
            if let detail, DownloadManager.shared.savedDetail(item.id) != nil {
                await DownloadManager.shared.saveInfo(item: detail.item, detail: detail)
            }
        } catch is CancellationError {
        } catch {
            if let saved = DownloadManager.shared.savedDetail(item.id) {
                detail = saved
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Download

    private var seriesHasLinks: Bool { current.isSeries && links.hasLinks(seriesId: current.id) }

    private func episodeDownloadAction(_ episode: Episode, detail: MediaDetail) -> (() -> Void)? {
        let link = canStream ? nil : episodeLink(episode, in: detail)
        guard canStream || link != nil else { return nil }
        return {
            if let r = downloads.record(itemId: current.id, episodeId: episode.id), r.state != .failed {
                downloads.remove(r.id)
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    await downloads.download(item: current, episode: episode,
                                             episodeLabel: detail.label(for: episode), detail: detail,
                                             provider: canStream ? app.provider : nil, directURL: link?.url)
                }
            }
        }
    }

    private var downloads: DownloadManager { DownloadManager.shared }

    private var downloadButton: some View {
        let record = downloads.record(itemId: current.id, episodeId: nil)
        let icon: String
        let title: String
        switch record?.state {
        case .done?: icon = "checkmark.circle.fill"; title = "Scaricato"
        case .downloading?: icon = "arrow.down.circle.dotted"; title = "\(Int((record?.progress ?? 0) * 100))%"
        case .waiting?: icon = "clock"; title = "In attesa"
        case .saved?: icon = "checkmark.circle.fill"; title = "Salvato"
        default:
            icon = "arrow.down.circle"
            if canStream || movieLink != nil { title = "Scarica" }
            else if seriesHasLinks { title = "Scarica episodi" }
            else { title = "Salva offline" }
        }
        return Button {
            if let record, record.state != .failed {
                downloads.remove(record.id)
                return
            }
            guard let detail else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task {
                if let link = movieLink {
                    // Film disponibile da link: si scarica il video, non solo la scheda.
                    await downloads.download(item: current, episode: nil, episodeLabel: nil, detail: detail,
                                             provider: nil, directURL: link.url)
                } else if seriesHasLinks {
                    // Serie: scarica tutti gli episodi disponibili da link.
                    for e in detail.seasons.flatMap(\.episodes) {
                        guard let link = episodeLink(e, in: detail),
                              downloads.record(itemId: current.id, episodeId: e.id) == nil else { continue }
                        await downloads.download(item: current, episode: e, episodeLabel: detail.label(for: e),
                                                 detail: detail, provider: nil, directURL: link.url)
                    }
                } else if canStream && !current.isSeries {
                    await downloads.download(item: current, episode: nil, episodeLabel: nil, detail: detail,
                                             provider: app.provider)
                } else {
                    // Catalogo informativo, o serie (gli episodi si scaricano uno per uno).
                    await downloads.saveInfo(item: current, detail: detail)
                }
            }
        } label: {
            actionLabel(icon, title)
        }
        .buttonStyle(GlassButtonStyle(tint: record?.state == .done || record?.state == .saved ? app.accent : nil,
                                      shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))))
        .disabled(detail == nil && record == nil)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(1, m)) min"
    }
}

struct EpisodeRow: View {
    @Environment(AppState.self) private var app
    let episode: Episode
    let fallbackImage: URL?
    var playable = true
    var download: DownloadRecord? = nil
    var onDownload: (() -> Void)? = nil
    var watched = false
    var toggleWatched: () -> Void = {}
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
                .padding(.trailing, onDownload == nil ? 42 : 82)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) {
                if let onDownload {
                    Button(action: onDownload) {
                        ZStack {
                            if download?.state == .downloading {
                                Circle().trim(from: 0, to: download?.progress ?? 0)
                                    .stroke(app.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "stop.fill").font(.system(size: 8))
                            } else {
                                Image(systemName: download?.state == .done ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(download?.state == .done ? app.accent : .white.opacity(0.55))
                            }
                        }
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scarica episodio")
                }
                Button(action: toggleWatched) {
                    Image(systemName: watched ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(watched ? app.accent : .white.opacity(0.55))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .symbolEffect(.bounce, value: watched)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(watched ? "Episodio visto" : "Segna episodio come visto")
                }
            }
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
            }
        }
        .padding(10)
        .liquidGlassCard(radius: 20, tint: watched ? app.accent.opacity(0.18) : nil)
        .opacity(watched ? 0.85 : 1)
    }
}

struct TrailerItem: Identifiable {
    let id = UUID()
    let url: URL
}
