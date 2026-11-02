import Foundation
import AVFoundation
import Observation
import CryptoKit
import UIKit

// MARK: - Immagini salvate per l'uso offline

enum ImageStore {
    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func file(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash)
    }

    static func cachedImage(for url: URL) -> UIImage? {
        let f = file(for: url)
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return UIImage(contentsOfFile: f.path)
    }

    static func save(_ urls: [URL?]) async {
        for case let url? in urls where url.scheme?.hasPrefix("http") == true {
            let f = file(for: url)
            if FileManager.default.fileExists(atPath: f.path) { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                try? data.write(to: f)
            }
        }
    }

    static func remove(_ urls: [URL?]) {
        for case let url? in urls { try? FileManager.default.removeItem(at: file(for: url)) }
    }
}

// MARK: - Download

struct DownloadRecord: Codable, Identifiable, Hashable {
    enum State: String, Codable { case waiting, downloading, done, failed, saved }

    var id: String
    var item: MediaItem
    var episodeId: String?
    var episodeLabel: String?
    var isHLS: Bool
    /// Percorso relativo alla cartella home dell'app (i percorsi assoluti cambiano dopo gli aggiornamenti).
    var relativePath: String?
    var state: State
    var progress: Double
    var bytes: Int64
    var error: String?
    var date: Date

    /// true = solo scheda (trama, cast, immagini) senza video.
    var infoOnly: Bool { state == .saved }

    var localURL: URL? {
        guard let relativePath else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)
    }

    static func key(itemId: String, episodeId: String?) -> String {
        episodeId.map { "\(itemId)|\($0)" } ?? itemId
    }
}

@MainActor
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    private(set) var records: [String: DownloadRecord] = [:]
    private(set) var details: [String: MediaDetail] = [:]

    @ObservationIgnored private var fileSession: URLSession!
    @ObservationIgnored private var hlsSession: AVAssetDownloadURLSession!
    @ObservationIgnored private var hlsLocations: [String: URL] = [:]

    private static var stateFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloads.json")
    }
    private static var detailsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offline-details.json")
    }
    static var videoFolder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Download", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    override private init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.stateFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.stateFile),
           let saved = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) {
            // I download interrotti dalla chiusura dell'app ripartono da capo.
            records = saved.mapValues { r in
                var r = r
                if r.state == .downloading || r.state == .waiting { r.state = .failed; r.error = "Interrotto" }
                return r
            }
        }
        if let data = try? Data(contentsOf: Self.detailsFile),
           let saved = try? JSONDecoder().decode([String: MediaDetail].self, from: data) {
            details = saved
        }
        let fileConfig = URLSessionConfiguration.background(withIdentifier: "app.lumen.downloads.files")
        fileConfig.sessionSendsLaunchEvents = true
        fileSession = URLSession(configuration: fileConfig, delegate: self, delegateQueue: .main)
        let hlsConfig = URLSessionConfiguration.background(withIdentifier: "app.lumen.downloads.hls")
        hlsSession = AVAssetDownloadURLSession(configuration: hlsConfig, assetDownloadDelegate: self, delegateQueue: .main)
    }

    // MARK: Stato

    var list: [DownloadRecord] { records.values.sorted { $0.date > $1.date } }
    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    func record(itemId: String, episodeId: String?) -> DownloadRecord? {
        records[DownloadRecord.key(itemId: itemId, episodeId: episodeId)]
    }

    /// File locale pronto da riprodurre, se presente.
    func localFile(itemId: String, episodeId: String?) -> URL? {
        guard let r = record(itemId: itemId, episodeId: episodeId), r.state == .done,
              let url = r.localURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func savedDetail(_ id: String) -> MediaDetail? { details[id] }

    // MARK: Azioni

    /// Salva la scheda (trama, cast, episodi, immagini) per consultarla senza connessione.
    func saveInfo(item: MediaItem, detail: MediaDetail) async {
        details[item.id] = detail
        persistDetails()
        if records[item.id] == nil {
            records[item.id] = DownloadRecord(id: item.id, item: item, episodeId: nil, episodeLabel: nil, isHLS: false,
                                              relativePath: nil, state: .saved, progress: 1, bytes: 0, error: nil, date: Date())
            persist()
        }
        var images: [URL?] = [item.poster, item.backdrop]
        images += detail.cast.prefix(15).map(\.photo)
        images += detail.seasons.flatMap(\.episodes).prefix(60).map(\.still)
        images += detail.watchProviders.map(\.logo)
        await ImageStore.save(images)
    }

    /// Scarica il video (film o episodio) dalla sorgente attiva.
    func download(item: MediaItem, episode: Episode?, episodeLabel: String?, detail: MediaDetail?,
                  provider: ContentProvider) async {
        let key = DownloadRecord.key(itemId: item.id, episodeId: episode?.id)
        if let existing = records[key], existing.state == .downloading || existing.state == .done { return }
        var record = DownloadRecord(id: key, item: item, episodeId: episode?.id, episodeLabel: episodeLabel,
                                    isHLS: false, relativePath: nil, state: .waiting, progress: 0, bytes: 0,
                                    error: nil, date: Date())
        records[key] = record
        if let detail { await saveInfo(item: item, detail: detail); records[key] = record }

        do {
            let sources = try await provider.streams(id: item.id, episodeId: episode?.id)
            guard let source = sources.first else { throw ProviderError.noStreams }
            let isHLS = source.url.pathExtension.lowercased() == "m3u8" || source.url.absoluteString.contains(".m3u8")
            record.isHLS = isHLS
            record.state = .downloading
            records[key] = record
            if isHLS {
                var options: [String: Any] = [:]
                if let h = source.headers, !h.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = h }
                let asset = AVURLAsset(url: source.url, options: options)
                guard let task = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: episodeLabel ?? item.title,
                                                                  assetArtworkData: nil, options: nil) else {
                    throw ProviderError.notSupported
                }
                task.taskDescription = key
                task.resume()
            } else {
                var request = URLRequest(url: source.url)
                source.headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                let task = fileSession.downloadTask(with: request)
                task.taskDescription = key
                task.resume()
            }
            persist()
        } catch {
            record.state = .failed
            record.error = error.localizedDescription
            records[key] = record
            persist()
        }
    }

    func cancel(_ key: String) {
        for session in [fileSession as URLSession, hlsSession as URLSession] {
            session.getAllTasks { tasks in
                tasks.filter { $0.taskDescription == key }.forEach { $0.cancel() }
            }
        }
        remove(key)
    }

    func remove(_ key: String) {
        if let r = records[key] {
            if let url = r.localURL { try? FileManager.default.removeItem(at: url) }
            if r.episodeId == nil, let d = details[r.item.id] {
                // Le immagini restano se ci sono ancora episodi scaricati della stessa serie.
                let others = records.values.contains { $0.item.id == r.item.id && $0.id != key }
                if !others {
                    ImageStore.remove([r.item.poster, r.item.backdrop] + d.cast.map(\.photo))
                    details[r.item.id] = nil
                    persistDetails()
                }
            }
        }
        records[key] = nil
        persist()
    }

    func removeAll() {
        for key in records.keys { remove(key) }
    }

    private func update(_ key: String, _ change: (inout DownloadRecord) -> Void) {
        guard var r = records[key] else { return }
        change(&r)
        records[key] = r
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: Self.stateFile) }
    }

    private func persistDetails() {
        if let data = try? JSONEncoder().encode(details) { try? data.write(to: Self.detailsFile) }
    }

    fileprivate func relativeToHome(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home) ? String(path.dropFirst(home.count + 1)) : path
    }

    fileprivate func finishFile(key: String, temp: URL, suggestedName: String?) {
        let ext = (suggestedName as NSString?)?.pathExtension.isEmpty == false ? (suggestedName! as NSString).pathExtension : "mp4"
        let safe = key.replacingOccurrences(of: "|", with: "_").replacingOccurrences(of: "/", with: "_")
        let dest = Self.videoFolder.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: temp, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            update(key) { $0.relativePath = relativeToHome(dest); $0.state = .done; $0.progress = 1; $0.bytes = size }
        } catch {
            update(key) { $0.state = .failed; $0.error = error.localizedDescription }
        }
        persist()
    }

    fileprivate func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - Delegati di rete (chiamati sulla coda principale)

extension DownloadManager: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated {
            update(key) {
                $0.bytes = totalBytesWritten
                if totalBytesExpectedToWrite > 0 { $0.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        // Il file temporaneo va spostato prima che il metodo ritorni.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: temp)
        let name = downloadTask.response?.suggestedFilename
        MainActor.assumeIsolated { finishFile(key: key, temp: temp, suggestedName: name) }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                                timeRangeExpectedToLoad: CMTimeRange) {
        guard let key = assetDownloadTask.taskDescription else { return }
        let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
        let expected = timeRangeExpectedToLoad.duration.seconds
        MainActor.assumeIsolated {
            update(key) { if expected > 0 { $0.progress = min(1, loaded / expected) } }
        }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let key = assetDownloadTask.taskDescription else { return }
        MainActor.assumeIsolated { hlsLocations[key] = location }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let isAsset = task is AVAssetDownloadTask
        MainActor.assumeIsolated {
            if let error {
                if (error as NSError).code == NSURLErrorCancelled { return }
                update(key) { $0.state = .failed; $0.error = error.localizedDescription }
            } else if isAsset, let location = hlsLocations[key] {
                let size = folderSize(location)
                update(key) { $0.relativePath = relativeToHome(location); $0.state = .done; $0.progress = 1; $0.bytes = size }
                hlsLocations[key] = nil
            }
            persist()
        }
    }
}
