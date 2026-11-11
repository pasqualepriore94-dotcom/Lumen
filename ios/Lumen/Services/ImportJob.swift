import Foundation
import SwiftUI
import Observation
import UIKit
import UserNotifications
import BackgroundTasks

/// Analisi di un link o di una playlist eseguita in background, indipendente dalle schermate:
/// puoi chiudere il pannello o passare a un'altra app. I risultati compaiono solo a lavoro finito.
@MainActor
@Observable
final class ImportJob {
    static let shared = ImportJob()

    enum Phase: String, Codable { case idle, downloading, mapping, ready }

    private(set) var phase: Phase = .idle
    private(set) var sourceName = ""
    var message: String?
    let mapper = LinkMapper()
    /// API nel formato Lumen trovata al posto di una playlist.
    var providerBase: String?
    var providerTitles = 0

    var selMovies = Set<String>()
    var selSeries = Set<String>()
    var selLives = Set<String>()

    /// Risultati pronti ma non ancora aperti (mostra il banner).
    var unseen = false
    /// Chiede al pannello amministratore di aprire la schermata dei risultati.
    var openRequested = false
    /// Lavoro sospeso dal sistema: riprende appena l'app torna attiva.
    private(set) var paused = false

    private var input: [LinkMedia] = []
    private var linkText: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tmdbConfig: ProviderConfig?

    var isRunning: Bool { phase == .downloading || phase == .mapping }

    var progress: Double {
        guard mapper.total > 0 else { return 0 }
        return Double(mapper.done) / Double(mapper.total)
    }

    var statusText: String {
        switch phase {
        case .downloading: return "Lettura di \(sourceName)…"
        case .mapping: return paused ? "In pausa: riprende quando torni nell'app"
                                     : (mapper.phaseLabel.map { "\($0) \(mapper.done.formatted())/\(mapper.total.formatted())" }
                                        ?? "Ricerca nel catalogo: \(mapper.done.formatted())/\(mapper.total.formatted()) titoli diversi (da \(input.count.formatted()) voci)")
        case .ready: return "\(mapper.movies.count) film · \(mapper.series.count) serie · \(mapper.lives.count) dirette"
        case .idle: return ""
        }
    }

    private init() {
        restore()
        mapper.onProgress = { [weak self] in self?.progressTick() }
    }

    // MARK: Avvio

    func startLink(_ text: String, app: AppState) {
        guard let url = LinkResolver.normalize(text) else { message = "Il link non è valido."; return }
        begin(name: url.host ?? "link", app: app)
        linkText = text
        phase = .downloading
        persist()
        run()
    }

    func startMedia(_ list: [LinkMedia], name: String, app: AppState) {
        guard !list.isEmpty else { message = "La playlist non contiene voci riproducibili."; return }
        begin(name: name, app: app)
        input = list
        phase = .mapping
        saveInput()
        persist(force: true)
        run()
    }

    private func begin(name: String, app: AppState) {
        task?.cancel()
        mapper.reset()
        tmdbConfig = app.config.providers.first { $0.type == .tmdb && $0.isUsable }
        sourceName = name
        message = nil
        providerBase = nil
        input = []
        linkText = nil
        selMovies = []; selSeries = []; selLives = []
        unseen = false
        paused = false
        Self.askNotificationPermission()
    }

    /// Riprende un lavoro interrotto (app sospesa o chiusa). Da chiamare quando l'app torna attiva.
    func resumeIfNeeded(app: AppState) {
        guard restored, isRunning, task == nil || paused else { return }
        if tmdbConfig == nil { tmdbConfig = app.config.providers.first { $0.type == .tmdb && $0.isUsable } }
        paused = false
        run()
    }

    func cancel() {
        mapper.cancel()
        task?.cancel()
        task = nil
        phase = .idle
        input = []
        BackgroundRunner.shared.end(success: false)
        persist()
    }

    /// Chiude i risultati mostrati.
    func clear() {
        cancel()
        mapper.reset()
        unseen = false
        message = nil
        Self.deleteSaved()
    }

    // MARK: Lavoro

    private func run() {
        let tmdb = tmdbConfig.map { TMDBProvider(config: $0) }
        BackgroundRunner.shared.begin(title: "Lumen: analisi contenuti", subtitle: sourceName) { [weak self] in
            // Il sistema sta per sospendere l'app: salva e metti in pausa.
            self?.pause()
        }
        task = Task { [weak self] in
            guard let self else { return }
            if phase == .downloading, let text = linkText {
                await download(text)
                guard phase == .mapping else { finishWithoutResults(); return }
            }
            await mapper.prepare(input, tmdb: tmdb)
            if paused || Task.isCancelled { persist(force: true); return }
            if tmdb != nil && !mapper.isComplete {
                // Alcune ricerche non sono riuscite (rete): riprova una volta dopo una breve attesa.
                try? await Task.sleep(for: .seconds(3))
                if paused || Task.isCancelled { persist(force: true); return }
                await mapper.prepare(input, tmdb: tmdb)
                if paused || Task.isCancelled { persist(force: true); return }
            }
            finish()
        }
    }

    /// Scarica la playlist intera (anche molto grande) e la tratta esattamente come un file .m3u caricato.
    private func downloadPlaylist(_ url: URL) async -> (SavedPlaylist, [LinkMedia])? {
        let ext = url.pathExtension.lowercased()
        // Un singolo video non è una playlist.
        guard !["mp4", "m4v", "mov", "mkv", "avi", "webm"].contains(ext) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Lumen", forHTTPHeaderField: "User-Agent")
        guard let pair = try? await URLSession.shared.download(for: request),
              let http = pair.1 as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
        let file = pair.0
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.hasPrefix("video/") { return nil }
        let parsed: (String, [LinkMedia])? = await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), let text = PlaylistStore.decode(data) else { return nil }
            let head = text.prefix(4000)
            // Flusso HLS singolo (varianti o segmenti): non è un elenco di contenuti.
            guard head.contains("#EXTINF") || head.hasPrefix("#EXTM3U") || text.hasPrefix("\u{FEFF}#EXTM3U"),
                  !head.contains("#EXT-X-STREAM-INF"), !head.contains("#EXT-X-TARGETDURATION") else { return nil }
            return (text, PlaylistStore.parse(text, origin: (http.url ?? url).absoluteString))
        }.value
        guard let parsed, !parsed.1.isEmpty else { return nil }
        let text = parsed.0, list = parsed.1
        let name = url.host ?? (url.deletingPathExtension().lastPathComponent)
        let (saved, _) = PlaylistStore.shared.save(name: name, origin: url.absoluteString, text: text)
        return (saved, list)
    }

    private func download(_ text: String) async {
        // 1) Playlist M3U da link: stessa analisi dei file caricati (intera, salvata in "Playlist M3U").
        if let url = LinkResolver.normalize(text), let found = await downloadPlaylist(url) {
            let saved = found.0, list = found.1
            input = list
            sourceName = saved.name
            message = "Playlist da link: \(saved.entries) voci (\(saved.vods) on demand, \(saved.lives) dirette). Salvata in Playlist M3U."
            phase = .mapping
            saveInput()
            persist(force: true)
            return
        }
        // 2) Altri link: video diretto, flusso HLS, API Lumen o pagina web.
        let result = await LinkResolver.resolve(text)
        switch result {
        case .media(let list):
            input = list
            phase = .mapping
            saveInput()
            persist(force: true)
        case .provider(let base, let titles):
            providerBase = base
            providerTitles = titles
            phase = .idle
        case .nothing(let why):
            message = why
            phase = .idle
        }
    }

    private func finishWithoutResults() {
        task = nil
        BackgroundRunner.shared.end(success: true)
        persist()
    }

    private func finish() {
        task = nil
        phase = .ready
        // Pre-selezione: film e serie trovati nel catalogo.
        selMovies = Set(mapper.movies.filter { $0.match != nil }.map(\.id))
        selSeries = Set(mapper.series.filter { $0.match != nil }.map(\.id))
        unseen = true
        mapper.removeImported(LinkLibrary.shared.allLinkedIds)   // già nel catalogo: non riproporli
        selMovies.formIntersection(Set(mapper.movies.map(\.id)))
        selSeries.formIntersection(Set(mapper.series.map(\.id)))
        persist(force: true)
        BackgroundRunner.shared.end(success: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        notifyFinished()
        NotificationStore.shared.post(AppNotification(kind: .analysisDone, title: "Analisi completata",
                                                      body: "\(sourceName): \(statusText). Tocca per scegliere cosa importare.",
                                                      icon: "checkmark.seal.fill"))
    }

    private func pause() {
        guard isRunning else { return }
        paused = true
        mapper.cancel()
        task?.cancel()
        task = nil
        persist(force: true)
        BackgroundRunner.shared.end(success: false)
    }

    private func progressTick() {
        BackgroundRunner.shared.update(done: mapper.done, total: mapper.total, subtitle: statusText)
        persist()
    }

    // MARK: Notifiche

    private static func askNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyFinished() {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Analisi completata"
        content.body = "\(sourceName): \(statusText). Tocca per scegliere cosa importare."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "lumen.import.done", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Salvataggio (per riprendere anche se l'app viene chiusa)
    // Tre file: stato (piccolo, salvato spesso), elenco voci (una volta) e ricerche già fatte
    // (salvate al massimo ogni minuto, fuori dal thread principale: con decine di migliaia di voci
    // salvare tutto a ogni passo rallenterebbe l'analisi).

    private struct State: Codable {
        var version = 2
        var phase: Phase
        var sourceName: String
        var linkText: String?
        var selMovies: Set<String>
        var selSeries: Set<String>
        var unseen: Bool
        var tmdbConfig: ProviderConfig?
    }

    /// Formato della versione 0.11.0 (tutto in un file).
    private struct LegacySaved: Decodable {
        var phase: Phase
        var sourceName: String
        var linkText: String?
        var input: [LinkMedia]
        var cache: [String: CachedMatch]
        var selMovies: Set<String>
        var selSeries: Set<String>
        var unseen: Bool
    }

    private struct Loaded {
        var state: State
        var input: [LinkMedia]
        var cache: [String: CachedMatch]
        var legacy: Bool
    }

    @ObservationIgnored private var lastCacheSave = Date.distantPast
    @ObservationIgnored private var restored = false

    nonisolated private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated private static var stateFile: URL { folder.appendingPathComponent("import-job.json") }
    nonisolated private static var inputFile: URL { folder.appendingPathComponent("import-input.json") }
    nonisolated private static var cacheFile: URL { folder.appendingPathComponent("import-cache.json") }

    /// Risultati visti: il banner "Analisi completata" non ricompare alle prossime aperture.
    func markSeen() {
        guard unseen else { return }
        unseen = false
        persist()
    }

    /// Toglie dai risultati ciò che è già nel catalogo; se non resta nulla da scegliere chiude i risultati.
    func pruneImported() {
        guard phase == .ready else { return }
        mapper.removeImported(LinkLibrary.shared.allLinkedIds)
        selMovies.formIntersection(Set(mapper.movies.map(\.id)))
        selSeries.formIntersection(Set(mapper.series.map(\.id)))
        selLives.formIntersection(Set(mapper.lives.map(\.id)))
        if mapper.movies.isEmpty && mapper.series.isEmpty && mapper.lives.isEmpty {
            clear()
        } else {
            persist()
        }
    }

    private func persist(force: Bool = false) {
        let state = State(phase: phase, sourceName: sourceName, linkText: linkText, selMovies: selMovies,
                          selSeries: selSeries, unseen: unseen, tmdbConfig: tmdbConfig)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateFile, options: .atomic) }
        if force || Date().timeIntervalSince(lastCacheSave) > 60 {
            lastCacheSave = Date()
            let cache = mapper.cache
            let url = Self.cacheFile
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
            }
        }
    }

    private func saveInput() {
        let list = input
        let url = Self.inputFile
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
        }
    }

    private static func deleteSaved() {
        // Le ricerche nel catalogo (cacheFile) restano: servono alle prossime analisi.
        for url in [stateFile, inputFile] { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated private static func load() -> Loaded? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(State.self, from: data) {
            let input = (try? Data(contentsOf: inputFile)).flatMap { try? decoder.decode([LinkMedia].self, from: $0) } ?? []
            let cache = (try? Data(contentsOf: cacheFile)).flatMap { try? decoder.decode([String: CachedMatch].self, from: $0) } ?? [:]
            return Loaded(state: state, input: input, cache: cache, legacy: false)
        }
        if let old = try? decoder.decode(LegacySaved.self, from: data) {
            let state = State(phase: old.phase, sourceName: old.sourceName, linkText: old.linkText,
                              selMovies: old.selMovies, selSeries: old.selSeries, unseen: old.unseen, tmdbConfig: nil)
            return Loaded(state: state, input: old.input, cache: old.cache, legacy: true)
        }
        return nil
    }

    nonisolated private static func loadCache() -> [String: CachedMatch] {
        (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode([String: CachedMatch].self, from: $0) } ?? [:]
    }

    private func restore() {
        Task { [weak self] in
            // Dopo l'animazione di avvio: la ricostruzione dei risultati di playlist enormi è pesante.
            try? await Task.sleep(for: .seconds(3))
            let loaded = await Task.detached(priority: .userInitiated) { ImportJob.load() }.value
            guard let self else { return }
            if loaded == nil, mapper.cache.isEmpty {
                let cache = await Task.detached(priority: .utility) { ImportJob.loadCache() }.value
                if mapper.cache.isEmpty { mapper.cache = cache }
            }
            if let loaded, task == nil, phase == .idle {
                let s = loaded.state
                phase = s.phase
                sourceName = s.sourceName
                linkText = s.linkText
                input = loaded.input
                mapper.cache = loaded.cache
                selMovies = s.selMovies
                selSeries = s.selSeries
                unseen = s.unseen
                tmdbConfig = s.tmdbConfig
                if loaded.legacy { saveInput(); persist(force: true) }
                if phase == .mapping && input.isEmpty { phase = .idle }
                if phase == .ready {
                    await mapper.rebuild(input)
                    await LinkLibrary.shared.loadIfNeeded()
                    pruneImported()   // ciò che hai già importato non viene riproposto
                }
                // Un lavoro rimasto a metà riprende da solo.
                paused = isRunning
            }
            restored = true
            if isRunning, paused, UIApplication.shared.applicationState == .active {
                paused = false
                run()
            }
        }
    }
}

/// Tiene viva l'app mentre lavora in background.
/// - iOS 26: attività "continua" di sistema (BGContinuedProcessingTask), con avanzamento visibile
///   e senza limite fisso di tempo finché l'utente non la ferma.
/// - Versioni precedenti: tempo extra concesso da iOS (circa 30 secondi); poi il lavoro va in pausa
///   e riprende da dove era rimasto quando torni nell'app.
@MainActor
final class BackgroundRunner {
    static let shared = BackgroundRunner()

    private var legacyId: UIBackgroundTaskIdentifier = .invalid
    private var continued: AnyObject?
    private var onExpire: (@MainActor () -> Void)?
    private var lastDone = 0
    private var lastTotal = 0
    private var title = "Lumen"

    func begin(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) {
        self.onExpire = onExpire
        self.title = title
        if legacyId == .invalid {
            legacyId = UIApplication.shared.beginBackgroundTask(withName: "Lumen import") { [weak self] in
                MainActor.assumeIsolated {
                    // Se c'è un'attività continua attiva, il lavoro prosegue lì.
                    guard let self else { return }
                    let hasContinued = self.continued != nil
                    self.endLegacy()
                    if !hasContinued { self.expire() }
                }
            }
        }
        if continued == nil { submitContinued(title: title, subtitle: subtitle) }
    }

    func update(done: Int, total: Int, subtitle: String) {
        lastDone = done
        lastTotal = total
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(max(total, 1))
            task.progress.completedUnitCount = Int64(done)
            task.updateTitle(title, subtitle: subtitle)
        }
        #endif
    }

    func end(success: Bool) {
        onExpire = nil
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        #endif
        continued = nil
        endLegacy()
    }

    private func expire() {
        let handler = onExpire
        onExpire = nil
        handler?()
    }

    private func endLegacy() {
        if legacyId != .invalid {
            UIApplication.shared.endBackgroundTask(legacyId)
            legacyId = .invalid
        }
    }

    /// Prefisso degli identificativi consentiti in Info.plist (voce che termina con ".*").
    private static var wildcardPrefix: String? {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return ids.first { $0.hasSuffix(".*") }.map { String($0.dropLast()) }
    }

    private func submitContinued(title: String, subtitle: String) {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), let prefix = Self.wildcardPrefix else { return }
        let identifier = prefix + UUID().uuidString.prefix(8).lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard self.onExpire != nil else {
                    // Il lavoro è già finito prima che l'attività partisse.
                    task.setTaskCompleted(success: true)
                    return
                }
                self.continued = task
                task.progress.totalUnitCount = Int64(max(self.lastTotal, 1))
                task.progress.completedUnitCount = Int64(self.lastDone)
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        self?.continued = nil
                        self?.expire()
                    }
                }
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Non disponibile (ad es. identificativo non accettato): resta il tempo extra standard.
        }
        #endif
    }
}

/// Banner in alto: avanzamento dell'analisi e avviso quando i contenuti sono pronti da scegliere.
struct ImportJobBanner: View {
    @Environment(AppState.self) private var app
    @Environment(AuthStore.self) private var auth
    @State private var job = ImportJob.shared

    var body: some View {
        if job.phase == .ready, job.unseen, !app.showAdmin, !app.showMyContent {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(app.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Analisi completata").font(.subheadline.weight(.semibold))
                    Text(job.statusText).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    job.markSeen()
                    app.showMyContent = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        job.openRequested = true
                    }
                } label: {
                    Text("Scegli").font(.footnote.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(GlassButtonStyle(tint: app.accent))
                Button { withAnimation { job.markSeen() } } label: {
                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 28, height: 28)
                }
                .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
            }
            .foregroundStyle(.white)
            .padding(12)
            .liquidGlassCard(radius: 24)
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if job.isRunning, !app.showAdmin, !app.showMyContent {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(job.phase == .downloading ? "Lettura playlist…" : "Analisi \(Int(job.progress * 100))%")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .liquidGlassCard(radius: 16)
            .transition(.opacity)
        }
    }
}
