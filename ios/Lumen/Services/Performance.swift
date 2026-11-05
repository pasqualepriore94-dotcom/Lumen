import SwiftUI
import UIKit
import ImageIO

// Ottimizzazioni: immagini in memoria già decodificate, Home e schede pronte subito.

// MARK: - Immagini

/// Scarica, riduce e decodifica le immagini fuori dal thread principale e le tiene in memoria:
/// le locandine non vengono più ridecodificate a ogni scorrimento (prima: scatti e locandine che "lampeggiavano").
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 500
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()
    private let lock = NSLock()
    private var running: [String: Task<UIImage?, Never>] = [:]

    private func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    /// Immagine già pronta in memoria (controllo immediato, senza accessi al disco).
    func cached(_ url: URL, maxPixel: Int) -> UIImage? {
        memory.object(forKey: key(url, maxPixel) as NSString)
    }

    func image(_ url: URL, maxPixel: Int) async -> UIImage? {
        let k = key(url, maxPixel)
        if let img = memory.object(forKey: k as NSString) { return img }
        lock.lock()
        if let task = running[k] { lock.unlock(); return await task.value }
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let data: Data?
            let offline = ImageStore.file(for: url)
            if FileManager.default.fileExists(atPath: offline.path) {
                data = try? Data(contentsOf: offline)
            } else {
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                data = try? await URLSession.shared.data(for: request).0
            }
            guard let data else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        running[k] = task
        lock.unlock()
        let img = await task.value
        lock.lock(); running[k] = nil; lock.unlock()
        if let img {
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
            memory.setObject(img, forKey: k as NSString, cost: cost)
        }
        return img
    }

    /// Prepara in anticipo le immagini che stanno per comparire.
    func prefetch(_ urls: [URL], maxPixel: Int = ImagePipeline.posterPixels) {
        for url in urls.prefix(24) where cached(url, maxPixel: maxPixel) == nil {
            Task.detached(priority: .utility) { _ = await self.image(url, maxPixel: maxPixel) }
        }
    }

    static let posterPixels = 520
    static let widePixels = 1200

    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return UIImage(data: data) }
        let thumb = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                     kCGImageSourceCreateThumbnailWithTransform: true,
                     kCGImageSourceShouldCacheImmediately: true,   // decodifica qui, non sul thread principale
                     kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Home pronta subito

/// Ultima Home scaricata, salvata sul telefono: all'apertura compare subito e si aggiorna in background.
enum HomeFeedCache {
    private struct Saved: Codable {
        struct Section: Codable {
            var id: String
            var title: String
            var style: String?
            var items: [MediaItem]
            var path: String?
            var query: [String: String]?
            var kind: MediaKind?
            var badge: String?
        }
        var hero: MediaItem?
        var sections: [Section]
    }

    private static func file(_ provider: String) -> URL {
        let safe = provider.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("home-\(safe).json")
    }

    static func load(provider: String) async -> HomeFeed? {
        let url = file(provider)
        return await Task.detached(priority: .userInitiated) { () -> HomeFeed? in
            guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
            let sections = s.sections.map { x -> CatalogSection in
                var c = CatalogSection(id: x.id, title: x.title, style: x.style, items: x.items)
                if let path = x.path { c.source = SectionSource(path: path, query: x.query ?? [:], kind: x.kind, badge: x.badge) }
                return c
            }
            return sections.isEmpty ? nil : HomeFeed(hero: s.hero, sections: sections)
        }.value
    }

    static func save(_ feed: HomeFeed, provider: String) {
        let saved = Saved(hero: feed.hero, sections: feed.sections.map {
            .init(id: $0.id, title: $0.title, style: $0.style, items: $0.items, path: $0.source?.path,
                  query: $0.source?.query, kind: $0.source?.kind, badge: $0.source?.badge)
        })
        let url = file(provider)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }
}
