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

    private static func present(url: URL, headers: [String: String]?, item: MediaItem, episodeId: String?,
                                episodeLabel: String?, library: Library) {
        var options: [String: Any] = [:]
        if let headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.externalMetadata = metadata(title: episodeLabel ?? item.title, subtitle: episodeLabel == nil ? nil : item.title)
        let player = AVPlayer(playerItem: playerItem)

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

        guard let top = topViewController() else { return }
        top.present(controller, animated: true) { player.play() }
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
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

final class LumenPlayerViewController: AVPlayerViewController {
    var onClose: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onClose?()
            onClose = nil
        }
    }
}
