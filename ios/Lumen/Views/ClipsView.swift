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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if clips.isEmpty {
                if let errorMessage {
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
            }
        }
        .task(id: app.contentKey) { await load() }
    }

    private func load() async {
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

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
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

    var body: some View {
        ZStack {
            Color.black
            if let looping {
                PlayerLayerView(player: looping.player)
                    .onTapGesture { paused.toggle() }
            } else {
                RemoteImage(url: clip.item.bestWideImage)
            }
            if paused {
                Image(systemName: "play.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            overlay
        }
        .clipped()
        .onAppear(perform: syncPlayback)
        .onChange(of: isCurrent) { syncPlayback() }
        .onChange(of: paused) { syncPlayback() }
        .onChange(of: muted) { looping?.player.isMuted = muted }
        .onDisappear {
            looping?.tearDown()
            looping = nil
            paused = false
        }
    }

    private func syncPlayback() {
        if isCurrent {
            if looping == nil { looping = LoopingPlayer(url: clip.video) }
            looping?.player.isMuted = muted
            if paused { looping?.player.pause() } else { looping?.player.play() }
        } else {
            looping?.player.pause()
        }
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if let rating = clip.item.rating {
                    Text(rating)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.top, 60)
            .padding(.horizontal, 16)

            Spacer()

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(clip.item.title).font(.system(size: 22, weight: .bold))
                    if !clip.item.tagLine.isEmpty {
                        Text(clip.item.tagLine).font(.system(size: 12, weight: .semibold))
                    }
                    if let overview = clip.item.overview {
                        Text(overview).font(.system(size: 14)).lineLimit(4)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 18) {
                    circleButton(muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { muted.toggle() }
                    circleButton(library.contains(clip.item) ? "checkmark" : "plus") {
                        withAnimation { library.toggle(clip.item) }
                    }
                    ShareLink(item: clip.item.title) { circleLabel("paperplane") }
                    Button { app.detailItem = clip.item } label: {
                        ImageTile(url: clip.item.bestPosterImage, width: 58, height: 58, corner: 29)
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule().fill(.white).frame(width: geo.size.width * (looping?.progress ?? 0))
                        Circle().fill(.white).frame(width: 8, height: 8)
                            .offset(x: geo.size.width * (looping?.progress ?? 0) - 4)
                    }
                }
                .frame(height: 3)
                Text(formatTime(looping?.remaining ?? 0))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, Theme.tabBarHeight + 10)
        }
        .foregroundStyle(.white)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(icon) }.buttonStyle(.plain)
    }

    private func circleLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: Circle())
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
