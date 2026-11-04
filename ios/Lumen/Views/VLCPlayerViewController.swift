import UIKit
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
        scheduleHide()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveProgress(force: true)
        player.stop()
        hideTimer?.invalidate()
        if isBeingDismissed { onClose?() }
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
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)), for: .normal)
            b.tintColor = .white
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            blur.isUserInteractionEnabled = false
            blur.layer.cornerRadius = 22
            blur.clipsToBounds = true
            blur.translatesAutoresizingMaskIntoConstraints = false
            b.insertSubview(blur, at: 0)
            NSLayoutConstraint.activate([
                blur.leadingAnchor.constraint(equalTo: b.leadingAnchor), blur.trailingAnchor.constraint(equalTo: b.trailingAnchor),
                blur.topAnchor.constraint(equalTo: b.topAnchor), blur.bottomAnchor.constraint(equalTo: b.bottomAnchor),
            ])
            b.addTarget(self, action: action, for: .touchUpInside)
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        let close = glassButton("xmark", size: 15, action: #selector(closeTapped))
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
            titleLabel.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: tracksButton.leadingAnchor, constant: -12),
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
        tracksButton.isHidden = sections.isEmpty
        tracksButton.menu = UIMenu(title: "", children: sections)
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
