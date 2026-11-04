import AVKit
import UIKit

/// Recupera il flusso dal provider attivo e lo apre nel player nativo a schermo intero.
@MainActor
enum Playback {
    static func play(item: MediaItem, episode: Episode? = nil, episodeLabel: String? = nil,
                     app: AppState, library: Library) async {
        guard !app.isPreparingPlayback else { return }
        app.isPreparingPlayback = true
        defer { app.isPreparingPlayback = false }

        do {
            let provider = app.provider
            var episode = episode
            var label = episodeLabel

            // Serie senza episodio scelto: riprende da dove eri rimasto o parte dal primo.
            if item.isSeries && episode == nil {
                let detail: MediaDetail
                if let fetched = try? await provider.detail(id: item.id) {
                    detail = fetched
                } else if let saved = DownloadManager.shared.savedDetail(item.id) {
                    detail = saved
                } else {
                    detail = try await provider.detail(id: item.id)
                }
                let resume = library.resumeEntry(for: item.id)
                if let e = detail.episode(id: resume?.episodeId) ?? detail.firstEpisode {
                    episode = e
                    label = detail.label(for: e)
                }
            }

            // Se il video è stato scaricato si riproduce dal file locale, anche senza connessione.
            if let local = DownloadManager.shared.localFile(itemId: item.id, episodeId: episode?.id) {
                present(url: local, headers: nil, item: item, episodeId: episode?.id, episodeLabel: label, library: library)
                return
            }
            let sources = try await provider.streams(id: item.id, episodeId: episode?.id)
            guard let source = sources.first else { throw ProviderError.noStreams }
            present(url: source.url, headers: source.headers, item: item, episodeId: episode?.id,
                    episodeLabel: label, library: library)
        } catch is CancellationError {
            return
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Riproduce direttamente un video trovato da un link (pannello amministratore, "I miei link").
    static func playLink(_ media: LinkMedia, app: AppState, library: Library) {
        if media.isLive {
            // Dirette: sempre con VLC (flussi MPEG-TS/HLS dei canali), senza salvare l'avanzamento.
            let now = EPGStore.shared.now(for: media).map { " · \($0.title)" } ?? ""
            let vlc = VLCPlayerViewController(url: media.url, title: media.title + now, startAt: 0)
            vlc.onAirPlayNative = { hls in presentLiveNative(hls, title: media.title + now) }
            MiniPlayer.shared.close()   // una sola riproduzione alla volta
            presentOnTop(vlc)
            return
        }
        present(url: media.url, headers: nil, item: media.asItem, episodeId: nil, episodeLabel: nil, library: library)
    }

    /// Riproduce un video da link abbinato a un titolo del catalogo (avanzamento salvato sul titolo).
    static func playLink(_ media: LinkMedia, as item: MediaItem, episodeId: String?, episodeLabel: String?,
                         library: Library) {
        if let local = DownloadManager.shared.localFile(itemId: item.id, episodeId: episodeId) {
            present(url: local, headers: nil, item: item, episodeId: episodeId, episodeLabel: episodeLabel, library: library)
            return
        }
        present(url: media.url, headers: nil, item: item, episodeId: episodeId, episodeLabel: episodeLabel, library: library)
    }

    /// Diretta nel player di iOS (versione HLS), con AirPlay: si apre subito la scelta del dispositivo.
    private static func presentLiveNative(_ url: URL, title: String) {
        let item = AVPlayerItem(url: url)
        item.externalMetadata = metadata(title: title, subtitle: "In diretta")
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        let controller = LumenPlayerViewController()
        controller.player = player
        controller.modalPresentationStyle = .fullScreen
        controller.onClose = { [weak player] in player?.pause() }
        presentOnTop(controller) {
            player.play()
            VLCPlayerViewController.showRoutePicker(in: controller.view)
        }
    }

    private static func present(url: URL, headers: [String: String]?, item: MediaItem, episodeId: String?,
                                episodeLabel: String?, library: Library) {
        // MKV, AVI, WebM e altri formati non supportati da iOS → player VLC.
        if VLCPlayerViewController.needsVLC(url) {
            let start = library.resumePosition(itemId: item.id, episodeId: episodeId)
            let vlc = VLCPlayerViewController(url: url, title: episodeLabel ?? item.title, startAt: start)
            vlc.onProgress = { position, duration in
                library.update(item: item, episodeId: episodeId, episodeLabel: episodeLabel,
                               position: position, duration: duration)
            }
            vlc.onAirPlayNative = { hls in
                present(url: hls, headers: headers, item: item, episodeId: episodeId, episodeLabel: episodeLabel, library: library)
            }
            MiniPlayer.shared.close()
            presentOnTop(vlc)
            return
        }
        var options: [String: Any] = [:]
        if let headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.externalMetadata = metadata(title: episodeLabel ?? item.title, subtitle: episodeLabel == nil ? nil : item.title)
        // Parte appena c'è un minimo di dati invece di riempire prima il buffer.
        playerItem.preferredForwardBufferDuration = 4
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible

        let start = library.resumePosition(itemId: item.id, episodeId: episodeId)
        if start > 5 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }

        let controller = LumenPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.modalPresentationStyle = .fullScreen

        let save: () -> Void = { [weak player] in
            guard let player, let current = player.currentItem else { return }
            let position = player.currentTime().seconds
            let duration = current.duration.seconds
            library.update(item: item, episodeId: episodeId, episodeLabel: episodeLabel,
                           position: position, duration: duration)
        }

        let token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                   queue: .main) { _ in
            MainActor.assumeIsolated { save() }
        }

        controller.onClose = { [weak player] in
            save()
            player?.pause()
            player?.removeTimeObserver(token)
        }

        MiniPlayer.shared.close()
        presentOnTop(controller) { player.play() }
    }

    private static func metadata(title: String, subtitle: String?) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        var list = [item(.commonIdentifierTitle, title)]
        if let subtitle { list.append(item(.iTunesMetadataTrackSubTitle, subtitle)) }
        return list
    }

    static func showError(_ message: String) {
        let alert = UIAlertController(title: "Impossibile riprodurre", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topViewController()?.present(alert, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // Solo la finestra principale dell'app: mai quella (anche nascosta) del mini player.
        let windows = (scene?.windows ?? []).filter { !$0.isHidden && !($0 is PassthroughWindow) && $0.rootViewController != nil }
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Presenta un player sopra tutto, riprovando se in quel momento un'altra schermata si sta chiudendo
    /// (altrimenti iOS ignora la richiesta e "non succede nulla").
    static func presentOnTop(_ controller: UIViewController, attempt: Int = 0, completion: (() -> Void)? = nil) {
        guard let top = topViewController() else { return }
        if top.presentedViewController != nil || top.isBeingDismissed || top.view.window == nil {
            guard attempt < 8 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                presentOnTop(controller, attempt: attempt + 1, completion: completion)
            }
            return
        }
        top.present(controller, animated: true, completion: completion)
    }
}

final class LumenPlayerViewController: AVPlayerViewController {
    var onClose: (() -> Void)?
    /// true mentre il video è in Picture in Picture: la schermata chiusa non ferma la riproduzione.
    var inPiP = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Riduci a icona (Picture in Picture), anche in automatico uscendo dall'app.
        allowsPictureInPicturePlayback = true
        canStartPictureInPictureAutomaticallyFromInline = true
        delegate = PiPCoordinator.shared
        player?.allowsExternalPlayback = true
        // Con AirPlay o in PiP la riproduzione continua anche a telefono bloccato.
        player?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true
        // Con AirPlay serve un buffer pieno: l'avvio rapido (buffer ridotto) su AirPlay causa scatti
        // e audio fuori sincrono. Si torna alla gestione automatica di iOS finché la TV è collegata.
        externalObserver = player?.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { p, _ in
            DispatchQueue.main.async {
                let external = p.isExternalPlaybackActive
                p.automaticallyWaitsToMinimizeStalling = external
                p.currentItem?.preferredForwardBufferDuration = external ? 0 : 4
            }
        }
    }

    private var externalObserver: NSKeyValueObservation?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if inPiP { return }
        if isBeingDismissed || presentingViewController == nil { finish() }
    }

    func finish() {
        UIApplication.shared.isIdleTimerDisabled = false
        onClose?()
        onClose = nil
    }
}

/// Gestisce il Picture in Picture: tiene vivo il player mentre è ridotto a icona e lo riapre a schermo intero.
final class PiPCoordinator: NSObject, AVPlayerViewControllerDelegate {
    static let shared = PiPCoordinator()
    private var active: LumenPlayerViewController?

    func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
        MainActor.assumeIsolated {
            guard let c = controller as? LumenPlayerViewController else { return }
            c.inPiP = true
            active = c
        }
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ controller: AVPlayerViewController) -> Bool { true }

    func playerViewController(_ controller: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard controller.presentingViewController == nil, let top = Playback.topViewController() else { completion(true); return }
            top.present(controller, animated: true) { completion(true) }
        }
    }

    func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
        MainActor.assumeIsolated {
            guard let c = controller as? LumenPlayerViewController else { return }
            c.inPiP = false
            // Chiuso dal riquadro senza tornare a schermo intero: fine della riproduzione.
            if c.presentingViewController == nil {
                c.player?.pause()
                c.finish()
            }
            if active === c { active = nil }
        }
    }
}
