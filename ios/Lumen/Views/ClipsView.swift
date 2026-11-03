import SwiftUI
import AVFoundation
import Observation

/// Feed verticale di clip a schermo intero, con scorrimento a pagina.
struct ClipsView: View {
    @Environment(AppState.self) private var app
    let isActive: Bool

    @State private var clips: [Clip] = []
    @State private var currentId: String?
    @State private var muted = false
    @State private var errorMessage: String?
    @State private var links = LinkLibrary.shared
    @State private var fromPlaylist = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if clips.isEmpty {
                if !app.provider.capabilities.clips && !ClipFeed.hasLinkContent {
                    VStack(spacing: 14) {
                        Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 44))
                        Text("Clip non disponibili").font(.title3.bold())
                        Text("La sorgente attiva è un catalogo informativo senza video. Le clip compaiono quando l'amministratore attiva una sorgente video (demo o API personalizzata).")
                            .font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                    }
                    .padding(28)
                    .liquidGlassCard(radius: 30)
                    .padding(24)
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(clips) { clip in
                            ClipPage(clip: clip,
                                     isCurrent: isActive && currentId == clip.id,
                                     muted: $muted)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(clip.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentId)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    if fromPlaylist {
                        Button {
                            withAnimation { clips = ClipFeed.build(taste: library.taste); currentId = clips.first?.id }
                        } label: {
                            Label("Dalla tua playlist · Mescola", systemImage: "shuffle")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(GlassButtonStyle())
                        .foregroundStyle(.white)
                        .padding(.top, 56).padding(.leading, 16)
                    }
                }
            }
        }
        .task(id: "\(app.contentKey)|\(links.matchedItems.count)|\(links.items.count)") { await load() }
    }

    @Environment(Library.self) private var library

    private func load() async {
        // Prima i contenuti della playlist caricata, proposti in base ai gusti.
        let fromLinks = ClipFeed.build(taste: library.taste)
        if !fromLinks.isEmpty {
            fromPlaylist = true
            clips = fromLinks
            if currentId == nil || !fromLinks.contains(where: { $0.id == currentId }) { currentId = fromLinks.first?.id }
            errorMessage = nil
            return
        }
        fromPlaylist = false
        guard app.provider.capabilities.clips else { clips = []; return }
        do {
            let result = try await app.provider.clips()
            clips = result
            if currentId == nil || !result.contains(where: { $0.id == currentId }) {
                currentId = result.first?.id
            }
            errorMessage = result.isEmpty ? "Nessuna clip disponibile per questa sorgente." : nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class LoopingPlayer {
    @ObservationIgnored let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper? = nil
    @ObservationIgnored private var timeToken: Any? = nil
    var progress: Double = 0
    var remaining: Double = 0
    @ObservationIgnored var wantsPlay = false

    /// `preview`: per film ed episodi interi riproduce in loop un estratto (da circa un quarto della durata).
    init(url: URL, preview: Bool = false) {
        if preview {
            Task { @MainActor [weak self] in
                let asset = AVURLAsset(url: url)
                let duration = (try? await asset.load(.duration))?.seconds ?? 0
                guard let self, self.timeToken != nil else { return }
                let item = AVPlayerItem(asset: asset)
                if duration.isFinite, duration > 120 {
                    let start = CMTime(seconds: duration * 0.25, preferredTimescale: 600)
                    let length = CMTime(seconds: min(90, duration * 0.1), preferredTimescale: 600)
                    self.looper = AVPlayerLooper(player: self.player, templateItem: item,
                                                 timeRange: CMTimeRange(start: start, duration: length))
                } else {
                    self.looper = AVPlayerLooper(player: self.player, templateItem: item)
                }
                if self.wantsPlay { self.player.play() }
            }
        } else {
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                   queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let duration = self.player.currentItem?.duration.seconds,
                      duration.isFinite, duration > 0 else { return }
                self.progress = min(1, time.seconds / duration)
                self.remaining = max(0, duration - time.seconds)
            }
        }
    }

    func tearDown() {
        player.pause()
        if let timeToken { player.removeTimeObserver(timeToken) }
        timeToken = nil
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

struct ClipPage: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library

    let clip: Clip
    let isCurrent: Bool
    @Binding var muted: Bool

    @State private var looping: LoopingPlayer?
    @State private var paused = false
    @State private var trailerId: String?
    @State private var trailerPlaying = false
    @State private var info: MediaDetail?

    private var item: MediaItem { info?.item ?? clip.item }
    private var sheetOpen: Bool { app.detailItem != nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.25),
                                       .init(color: .clear, location: 0.45), .init(color: .black.opacity(0.92), location: 0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                overlay
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear(perform: syncPlayback)
        .onChange(of: isCurrent) { syncPlayback() }
        .onChange(of: paused) { syncPlayback() }
        .onChange(of: trailerId) { syncPlayback() }
        .onChange(of: muted) { looping?.player.isMuted = muted }
        .onChange(of: sheetOpen) { syncPlayback() }
        .task(id: isCurrent) { if isCurrent { await loadTrailer() } }
        .onDisappear {
            looping?.tearDown()
            looping = nil
            paused = false
        }
    }

    // MARK: Sfondo: trailer, estratto del video o immagine

    @ViewBuilder
    private var background: some View {
        ZStack {
            Color.clear
                .overlay(RemoteImage(url: item.bestPosterImage ?? item.bestWideImage))
                .clipped()
                .blur(radius: trailerId != nil ? 30 : 0)
                .allowsHitTesting(false)
                .scaleEffect(isCurrent && looping == nil && trailerId == nil ? 1.12 : 1)
                .animation(.easeInOut(duration: 12).repeatForever(autoreverses: true), value: isCurrent)
                .overlay(Color.black.opacity(trailerId != nil ? 0.35 : 0))
            if let trailerId {
                VStack {
                    Spacer().frame(height: 110)
                    ZStack {
                        Color.clear.overlay(RemoteImage(url: item.bestWideImage)).clipped()
                        if isCurrent {
                            TrailerPreview(videoId: trailerId, muted: muted, paused: paused || sheetOpen,
                                           controls: false, playing: $trailerPlaying)
                                .opacity(trailerPlaying ? 1 : 0)
                                .animation(.easeInOut(duration: 0.5), value: trailerPlaying)
                                .allowsHitTesting(false)
                        }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.6))
                    .overlay {
                        if paused {
                            Image(systemName: "play.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { paused.toggle() }
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    .padding(.horizontal, 12)
                    Spacer()
                }
            } else if let looping {
                // Estratto del video: si mette in pausa toccando il video (non i testi o i pulsanti).
                PlayerLayerView(player: looping.player)
                    .contentShape(Rectangle())
                    .onTapGesture { paused.toggle() }
            }
            if paused && trailerId == nil && looping != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Trailer dalla scheda del catalogo (se il titolo è abbinato e il trailer esiste).
    private func loadTrailer() async {
        guard clip.hasDetail, trailerId == nil else { return }
        if let cached = ClipFeed.trailerCache[clip.item.id] {
            trailerId = cached
            return
        }
        guard let d = try? await app.provider.detail(id: clip.item.id) else { return }
        info = d
        let id = d.trailer.flatMap { TrailerPlayerView.videoId(from: $0) }
        ClipFeed.trailerCache[clip.item.id] = id
        trailerId = id
    }

    /// I formati che iOS non riproduce in linea (MKV, AVI…) mostrano l'immagine e il pulsante Riproduci.
    private var inlinePlayable: Bool { !VLCPlayerViewController.needsVLC(clip.video) }

    private func syncPlayback() {
        // Con il trailer disponibile non serve l'estratto del video.
        if trailerId != nil {
            looping?.tearDown()
            looping = nil
            return
        }
        guard inlinePlayable else { return }
        if isCurrent && !sheetOpen {
            if looping == nil { looping = LoopingPlayer(url: clip.video, preview: clip.link != nil) }
            looping?.player.isMuted = muted
            looping?.wantsPlay = !paused
            if paused { looping?.player.pause() } else { looping?.player.play() }
        } else {
            looping?.wantsPlay = false
            looping?.player.pause()
        }
    }

    private func playFull() {
        paused = true
        if let link = clip.link {
            if clip.hasDetail {
                Playback.playLink(link, as: clip.item, episodeId: clip.episodeId, episodeLabel: clip.episodeLabel, library: library)
            } else {
                Playback.playLink(link, app: app, library: library)
            }
        } else {
            app.detailItem = clip.item
        }
    }

    // MARK: Informazioni e azioni

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                circleButton(muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { muted.toggle() }
            }
            .padding(.top, 56)
            .padding(.horizontal, 16)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 28, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                HStack(spacing: 8) {
                    if let match = library.taste.compatibility(item, genres: info?.genres) {
                        MatchBadge(percent: match, compact: true)
                    }
                    if let year = item.year { Text(String(year)) }
                    Text(item.isSeries ? "Serie TV" : "Film")
                    if let score = item.scoreLabel {
                        Label(score, systemImage: "star.fill").labelStyle(.titleAndIcon)
                    }
                    if let ep = clip.episodeLabel { Text(ep) }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                if !item.tagLine.isEmpty {
                    Text(item.tagLine).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                if let overview = item.overview, !overview.isEmpty, clip.hasDetail {
                    Text(overview).font(.system(size: 14)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.white.opacity(0.85))
                }

                HStack(spacing: 10) {
                    Button { playFull() } label: {
                        Label(clip.link == nil ? "Dettagli" : "Riproduci", systemImage: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(GlassButtonStyle(tint: app.accent))

                    Button { withAnimation { library.toggle(clip.item) } } label: {
                        Label(library.contains(clip.item) ? "In lista" : "La mia lista",
                              systemImage: library.contains(clip.item) ? "checkmark" : "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(GlassButtonStyle())

                    if clip.hasDetail {
                        Button { paused = true; app.detailItem = clip.item } label: {
                            Image(systemName: "info.circle").font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                    }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, Theme.tabBarHeight + 16)
        }
        .foregroundStyle(.white)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(icon) }.buttonStyle(.plain)
    }

    private func circleLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .liquidGlass(in: Circle(), interactive: true)
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}


/// Feed delle clip costruito dai contenuti della playlist M3U: film ed episodi abbinati al catalogo,
/// ordinati in base ai gusti (con un po' di casualità), oppure le voci on demand delle playlist caricate.
@MainActor
enum ClipFeed {
    /// id titolo → id YouTube del trailer (nil = nessun trailer)
    static var trailerCache: [String: String?] = [:]
    static var hasLinkContent: Bool {
        !LinkLibrary.shared.matchedItems.isEmpty || !PlaylistStore.shared.playlists.isEmpty
    }

    static func build(taste: TasteProfile, limit: Int = 80) -> [Clip] {
        let lib = LinkLibrary.shared
        var out: [(Clip, Double)] = []
        func score(_ item: MediaItem) -> Double {
            Double(taste.compatibility(item) ?? 60) + Double.random(in: 0...35)
        }
        // Campione casuale per non lavorare su decine di migliaia di titoli.
        for item in lib.matchedMovies.shuffled().prefix(600) {
            if let m = lib.link(forItem: item.id) { out.append((Clip(item: item, link: m), score(item))) }
        }
        for item in lib.matchedSeries.shuffled().prefix(300) {
            guard let eps = lib.episodeLinks[item.id], !eps.isEmpty else { continue }
            // Primo episodio disponibile (stagione ed episodio più bassi)
            let parsed = eps.keys.compactMap { k -> (Int, Int, String)? in
                let nums = k.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                return nums.count == 2 ? (nums[0], nums[1], k) : nil
            }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            guard let first = parsed.first, let m = eps[first.2] else { continue }
            let clip = Clip(item: item, link: m, episodeId: "\(item.id)-s\(first.0)e\(first.1)",
                            episodeLabel: "S\(first.0) E\(first.1)")
            out.append((clip, score(item)))
        }
        if out.isEmpty {
            let store = PlaylistStore.shared
            for p in store.playlists {
                for m in store.media(of: p).filter({ !$0.isLive }).shuffled().prefix(200) {
                    out.append((Clip(item: m.asItem, link: m), Double.random(in: 0...100)))
                }
                if out.count >= 400 { break }
            }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
