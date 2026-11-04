import UIKit
import AVKit
import MobileVLCKit

/// Player basato su VLC per i formati che il player di iOS non legge (MKV, AVI, WebM, FLV, WMV…).
/// Supporta più tracce audio e sottotitoli integrati.
final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    static let formats: Set<String> = ["mkv", "avi", "webm", "flv", "wmv", "mpg", "mpeg", "ogv", "divx", "xvid", "3gp", "vob"]

    /// Formati che il player di iOS riproduce da solo; tutto il resto (MKV, flussi .ts delle dirette,
    /// indirizzi senza estensione…) passa da VLC.
    static let nativeFormats: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "aac"]

    static func needsVLC(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if formats.contains(ext) { return true }
        if url.absoluteString.lowercased().contains(".m3u8") { return false }
        return !nativeFormats.contains(ext)
    }

    private let url: URL
    private let titleText: String
    private let startAt: Double
    var onProgress: ((Double, Double) -> Void)?
    var onClose: (() -> Void)?
    /// Passa al player di iOS (che supporta AirPlay) con la versione HLS dello stesso flusso.
    var onAirPlayNative: ((URL) -> Void)?

    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private let controls = UIView()
    private let titleLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let slider = UISlider()
    private let currentLabel = UILabel()
    private let remainingLabel = UILabel()
    private let tracksButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private var hideTimer: Timer?
    private var isScrubbing = false
    private var didSeekToStart = false
    private var lastSaved = Date.distantPast

    init(url: URL, title: String, startAt: Double) {
        self.url = url
        self.titleText = title
        self.startAt = startAt
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        buildControls()

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        videoView.addGestureRecognizer(tap)

        player.drawable = videoView
        player.delegate = self
        let media = VLCMedia(url: url)
        // Avvio più rapido sui flussi in rete: buffer iniziale ridotto e riconnessione automatica.
        media.addOptions([
            "network-caching": 1000,
            "http-reconnect": true,
            "http-user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Lumen"
        ])
        player.media = media
        player.play()
        // Lo schermo non si spegne da solo durante la riproduzione (utile anche con Duplica schermo).
        UIApplication.shared.isIdleTimerDisabled = true
        scheduleHide()
    }

    /// true mentre il video è ridotto a icona (mini player): chiudere la schermata non ferma la riproduzione.
    var isMinimized = false
    var isPlaying: Bool { player.isPlaying }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hideTimer?.invalidate()
        if isMinimized { return }
        finishPlayback()
    }

    /// Ferma la riproduzione, salva l'avanzamento e libera lo schermo.
    func finishPlayback() {
        saveProgress(force: true)
        player.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        onClose?()
        onClose = nil
    }

    /// Sposta il video in un'altra vista (mini player) o lo riporta a schermo intero.
    func attachVideo(to view: UIView?) {
        player.drawable = view ?? videoView
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        updatePlayIcon(playing: !player.isPlaying)
    }

    @objc private func minimizeTapped() {
        MiniPlayer.shared.minimize(self)
    }

    // MARK: Interfaccia

    private func buildControls() {
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let shade = CAGradientLayer()
        shade.colors = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.clear.cgColor,
                        UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        shade.locations = [0, 0.25, 0.7, 1]
        controls.layer.addSublayer(shade)
        controls.layer.setValue(shade, forKey: "shade")

        func glassButton(_ symbol: String, size: CGFloat, action: Selector) -> UIButton {
            // Sfondo sfocato gestito dalla configurazione del pulsante: l'icona resta sempre sopra
            // (prima lo sfondo inserito a mano copriva l'icona e si vedeva solo un cerchio grigio).
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
            config.baseForegroundColor = .white
            config.cornerStyle = .capsule
            config.background.visualEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            config.background.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            config.background.cornerRadius = 22
            let b = UIButton(configuration: config)
            b.tintColor = .white
            b.addTarget(self, action: action, for: .touchUpInside)
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        let close = glassButton("xmark", size: 15, action: #selector(closeTapped))
        // Va aggiunto subito: i vincoli dei pulsanti vicini lo usano come riferimento
        // (senza, l'app si chiudeva all'apertura del player VLC).
        controls.addSubview(close)
        let airplay = glassButton("airplayvideo", size: 17, action: #selector(airPlayTapped))
        controls.addSubview(airplay)
        let mini = glassButton("pip.enter", size: 16, action: #selector(minimizeTapped))
        controls.addSubview(mini)
        NSLayoutConstraint.activate([
            mini.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 8),
            mini.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            mini.widthAnchor.constraint(equalToConstant: 44), mini.heightAnchor.constraint(equalToConstant: 44),
        ])
        miniButton = mini
        airplayButton = airplay
        controls.addSubview(close)

        titleLabel.text = titleText
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(titleLabel)

        tracksButton.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        tracksButton.tintColor = .white
        tracksButton.showsMenuAsPrimaryAction = true
        tracksButton.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(tracksButton)

        playButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)), for: .normal)
        playButton.tintColor = .white
        playButton.addTarget(self, action: #selector(playPause), for: .touchUpInside)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(playButton)

        let back = glassButton("gobackward.10", size: 20, action: #selector(skipBack))
        let forward = glassButton("goforward.10", size: 20, action: #selector(skipForward))
        controls.addSubview(back)
        controls.addSubview(forward)

        for l in [currentLabel, remainingLabel] {
            l.textColor = .white
            l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            l.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(l)
        }
        currentLabel.text = "0:00"
        remainingLabel.text = "--:--"

        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(UIImage(systemName: "circle.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal), for: .normal)
        slider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(slider)

        let g = controls.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            close.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 64),
            titleLabel.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: airplay.leadingAnchor, constant: -12),
            airplay.trailingAnchor.constraint(equalTo: tracksButton.leadingAnchor, constant: -8),
            airplay.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            airplay.widthAnchor.constraint(equalToConstant: 44), airplay.heightAnchor.constraint(equalToConstant: 44),
            tracksButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            tracksButton.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            tracksButton.widthAnchor.constraint(equalToConstant: 44), tracksButton.heightAnchor.constraint(equalToConstant: 44),

            playButton.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 72), playButton.heightAnchor.constraint(equalToConstant: 72),
            back.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            back.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -36),
            back.widthAnchor.constraint(equalToConstant: 52), back.heightAnchor.constraint(equalToConstant: 52),
            forward.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            forward.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 36),
            forward.widthAnchor.constraint(equalToConstant: 52), forward.heightAnchor.constraint(equalToConstant: 52),

            currentLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            currentLabel.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -14),
            remainingLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            remainingLabel.centerYAnchor.constraint(equalTo: currentLabel.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: currentLabel.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: currentLabel.centerYAnchor),
        ])
        [back, forward].forEach { $0.layer.cornerRadius = 26 }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (controls.layer.value(forKey: "shade") as? CAGradientLayer)?.frame = controls.bounds
    }

    private func refreshTracksMenu() {
        var sections: [UIMenuElement] = []
        let audioNames = (player.audioTrackNames as? [String]) ?? []
        let audioIdx = (player.audioTrackIndexes as? [NSNumber]) ?? []
        if audioNames.count > 1 {
            let actions = zip(audioNames, audioIdx).map { name, idx in
                UIAction(title: name, state: player.currentAudioTrackIndex == idx.int32Value ? .on : .off) { [weak self] _ in
                    self?.player.currentAudioTrackIndex = idx.int32Value
                }
            }
            sections.append(UIMenu(title: "Audio", options: .displayInline, children: actions))
        }
        let subNames = (player.videoSubTitlesNames as? [String]) ?? []
        let subIdx = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        if !subNames.isEmpty {
            let actions = zip(subNames, subIdx).map { name, idx in
                UIAction(title: name, state: player.currentVideoSubTitleIndex == idx.int32Value ? .on : .off) { [weak self] _ in
                    self?.player.currentVideoSubTitleIndex = idx.int32Value
                }
            }
            sections.append(UIMenu(title: "Sottotitoli", options: .displayInline, children: actions))
        }
        // Sincronizzazione audio: con Duplica schermo o casse AirPlay l'audio può arrivare in ritardo.
        let current = Self.savedAudioDelay
        let options: [(String, Int)] = [("Anticipa di 2 s", -2000), ("Anticipa di 1,5 s", -1500), ("Anticipa di 1 s", -1000),
                                        ("Anticipa di 0,5 s", -500), ("Anticipa di 0,25 s", -250), ("Nessuna correzione", 0),
                                        ("Ritarda di 0,25 s", 250), ("Ritarda di 0,5 s", 500)]
        let syncActions = options.map { title, ms in
            UIAction(title: title, state: current == ms ? .on : .off) { [weak self] _ in
                Self.savedAudioDelay = ms
                self?.applyAudioDelay()
                self?.refreshTracksMenu()
            }
        }
        sections.append(UIMenu(title: "Sincronizzazione audio", image: UIImage(systemName: "waveform"), children: syncActions))
        tracksButton.isHidden = false
        tracksButton.menu = UIMenu(title: "", children: sections)
    }

    /// Correzione audio scelta dall'utente (millisecondi; negativo = audio anticipato), ricordata per le prossime volte.
    static var savedAudioDelay: Int {
        get { UserDefaults.standard.integer(forKey: "lumen.vlc.audioDelay") }
        set { UserDefaults.standard.set(newValue, forKey: "lumen.vlc.audioDelay") }
    }

    private func applyAudioDelay() {
        player.currentAudioPlaybackDelay = Self.savedAudioDelay * 1000   // microsecondi
    }

    @objc private func toggleControls() {
        UIView.animate(withDuration: 0.25) { self.controls.alpha = self.controls.alpha > 0 ? 0 : 1 }
        if controls.alpha > 0 { scheduleHide() }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.player.isPlaying, !self.isScrubbing else { return }
            UIView.animate(withDuration: 0.3) { self.controls.alpha = 0 }
        }
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    private weak var airplayButton: UIButton?
    private weak var miniButton: UIButton?

    /// AirPlay: VLC non può inviare il video ad AirPlay, il player di iOS sì (con flussi HLS).
    /// Se il fornitore offre la stessa diretta in HLS (.m3u8) si passa a quel player e si apre la scelta del dispositivo;
    /// altrimenti si suggerisce Duplica schermo.
    @objc private func airPlayTapped() {
        scheduleHide()
        airplayButton?.isEnabled = false
        spinner.startAnimating()
        let source = url
        Task { @MainActor in
            let hls = await Self.hlsVariant(of: source)
            self.spinner.stopAnimating()
            self.airplayButton?.isEnabled = true
            if let hls, let switchTo = self.onAirPlayNative {
                self.player.stop()
                self.dismiss(animated: true) { switchTo(hls) }
                return
            }
            let alert = UIAlertController(
                title: "AirPlay",
                message: "Questo flusso è in un formato che AirPlay non riceve direttamente. Per vederlo sulla TV apri il Centro di Controllo e scegli Duplica schermo: Lumen verrà mostrata sulla TV a tutto schermo.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Invia solo l'audio", style: .default) { _ in Self.showRoutePicker(in: self.view) })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            self.present(alert, animated: true)
        }
    }

    /// Prova la versione HLS dello stesso indirizzo (molti fornitori IPTV offrono sia .ts sia .m3u8).
    static func hlsVariant(of url: URL) async -> URL? {
        var candidates: [URL] = []
        if url.absoluteString.lowercased().contains(".m3u8") { return url }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { candidates.append(url.deletingPathExtension().appendingPathExtension("m3u8")) }
        else { candidates.append(url.appendingPathExtension("m3u8")) }
        for c in candidates {
            var r = URLRequest(url: c, timeoutInterval: 8)
            r.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
            r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Lumen", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: r),
                  let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { continue }
            let head = String(decoding: data.prefix(64), as: UTF8.self)
            if head.contains("#EXTM3U") { return http.url ?? c }
        }
        return nil
    }

    /// Apre la scelta del dispositivo AirPlay (come il pulsante di sistema).
    static func showRoutePicker(in view: UIView) {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.alpha = 0.02
        view.addSubview(picker)
        for case let b as UIButton in picker.subviews { b.sendActions(for: .touchUpInside) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { picker.removeFromSuperview() }
    }

    @objc private func playPause() {
        if player.isPlaying { player.pause() } else { player.play() }
        updatePlayIcon(playing: !player.isPlaying)
        scheduleHide()
    }

    private func updatePlayIcon(playing: Bool) {
        let name = playing ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)), for: .normal)
    }

    @objc private func skipBack() { player.jumpBackward(10); scheduleHide() }
    @objc private func skipForward() { player.jumpForward(10); scheduleHide() }

    @objc private func scrubStart() { isScrubbing = true; hideTimer?.invalidate() }
    @objc private func scrubChanged() {
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        currentLabel.text = Self.format(Double(slider.value) * length)
    }
    @objc private func scrubEnd() {
        player.position = slider.value
        isScrubbing = false
        scheduleHide()
    }

    // MARK: Delegato VLC

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .playing:
            spinner.stopAnimating()
            updatePlayIcon(playing: true)
            applyAudioDelay()
            refreshTracksMenu()
            if !didSeekToStart, startAt > 5 {
                didSeekToStart = true
                player.time = VLCTime(int: Int32(startAt * 1000))
            }
        case .buffering, .opening:
            if !player.isPlaying { spinner.startAnimating() }
        case .error:
            spinner.stopAnimating()
            let alert = UIAlertController(title: "Impossibile riprodurre", message: "Il file non è leggibile o il server non risponde.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.dismiss(animated: true) })
            present(alert, animated: true)
        case .ended, .stopped:
            updatePlayIcon(playing: false)
        case .paused:
            updatePlayIcon(playing: false)
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        spinner.stopAnimating()
        let now = Double(player.time.intValue) / 1000
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if !isScrubbing {
            slider.value = player.position
            currentLabel.text = Self.format(now)
            remainingLabel.text = length > 0 ? "-" + Self.format(max(0, length - now)) : "--:--"
        }
        saveProgress(force: false)
    }

    private func saveProgress(force: Bool) {
        guard force || Date().timeIntervalSince(lastSaved) > 10 else { return }
        lastSaved = Date()
        let now = Double(player.time.intValue) / 1000
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length > 0 { onProgress?(now, length) }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}


/// Mini player per i contenuti riprodotti con VLC (dirette, MKV…): il video resta in un riquadro
/// mobile sopra l'app mentre sfogli il catalogo. Tocca per tornare a schermo intero.
@MainActor
final class MiniPlayer {
    static let shared = MiniPlayer()

    private var window: PassthroughWindow?
    private var vlc: VLCPlayerViewController?
    private weak var card: UIView?
    private weak var playButton: UIButton?

    func minimize(_ controller: VLCPlayerViewController) {
        close()   // un solo mini player alla volta
        vlc = controller
        controller.isMinimized = true
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }

        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .statusBar - 1
        w.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        w.rootViewController = root

        let width: CGFloat = 220, height: CGFloat = width * 9 / 16
        let bounds = scene.screen.bounds
        let card = UIView(frame: CGRect(x: bounds.width - width - 14, y: bounds.height - height - 130, width: width, height: height))
        card.backgroundColor = .black
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        card.layer.borderWidth = 0.6
        let shadowHost = UIView(frame: card.frame)
        shadowHost.layer.shadowColor = UIColor.black.cgColor
        shadowHost.layer.shadowOpacity = 0.5
        shadowHost.layer.shadowRadius = 14
        shadowHost.layer.shadowOffset = CGSize(width: 0, height: 6)
        card.frame = shadowHost.bounds
        shadowHost.addSubview(card)
        root.view.addSubview(shadowHost)
        w.passthroughTarget = shadowHost

        let video = UIView(frame: card.bounds)
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        video.isUserInteractionEnabled = false
        card.addSubview(video)

        func button(_ symbol: String, _ action: @escaping () -> Void) -> UIButton {
            var c = UIButton.Configuration.plain()
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
            c.baseForegroundColor = .white
            c.background.visualEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            c.background.cornerRadius = 15
            c.cornerStyle = .capsule
            let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
            b.frame.size = CGSize(width: 30, height: 30)
            return b
        }
        let closeButton = button("xmark") { [weak self] in self?.close() }
        closeButton.frame.origin = CGPoint(x: 6, y: 6)
        let play = button(controller.isPlaying ? "pause.fill" : "play.fill") { [weak self] in self?.togglePlay() }
        play.frame.origin = CGPoint(x: width - 36, y: 6)
        let expand = button("arrow.up.left.and.arrow.down.right") { [weak self] in self?.expand() }
        expand.frame.origin = CGPoint(x: width - 36, y: height - 36)
        card.addSubview(closeButton)
        card.addSubview(play)
        card.addSubview(expand)
        playButton = play

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        shadowHost.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        shadowHost.addGestureRecognizer(pan)

        w.isHidden = false
        window = w
        self.card = shadowHost
        controller.attachVideo(to: video)
        controller.dismiss(animated: true)
    }

    private func togglePlay() {
        guard let vlc else { return }
        vlc.togglePlay()
        var c = playButton?.configuration
        c?.image = UIImage(systemName: vlc.isPlaying ? "play.fill" : "pause.fill",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        playButton?.configuration = c
    }

    @objc private func tapped() { expand() }

    /// Torna a schermo intero.
    func expand() {
        guard let vlc else { return }
        window?.isHidden = true
        window = nil
        self.vlc = nil
        vlc.isMinimized = false
        vlc.attachVideo(to: nil)
        Playback.presentOnTop(vlc)
    }

    /// Chiude il mini player e ferma la riproduzione.
    func close() {
        guard let vlc else { return }
        vlc.isMinimized = false
        vlc.finishPlayback()
        window?.isHidden = true
        window = nil
        self.vlc = nil
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let card, let host = card.superview else { return }
        let t = g.translation(in: host)
        card.center = CGPoint(x: card.center.x + t.x, y: card.center.y + t.y)
        g.setTranslation(.zero, in: host)
        if g.state == .ended || g.state == .cancelled {
            // Si aggancia al bordo più vicino
            let b = host.bounds.inset(by: host.safeAreaInsets).insetBy(dx: 12, dy: 12)
            let x = card.center.x < host.bounds.midX ? b.minX + card.bounds.width / 2 : b.maxX - card.bounds.width / 2
            let y = min(max(card.center.y, b.minY + card.bounds.height / 2), b.maxY - card.bounds.height / 2 - 80)
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                card.center = CGPoint(x: x, y: y)
            }
        }
    }
}

/// Finestra che riceve i tocchi solo sul mini player: il resto passa all'app sotto.
final class PassthroughWindow: UIWindow {
    weak var passthroughTarget: UIView?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = passthroughTarget else { return nil }
        let p = convert(point, to: target)
        return target.bounds.contains(p) ? super.hitTest(point, with: event) : nil
    }
}
