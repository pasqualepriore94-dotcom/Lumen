import Foundation
import Vision
import ImageIO

/// Abbinamento per locandina: cerca nel catalogo dei candidati (anche con titoli parziali) e confronta
/// la locandina della playlist con le loro locandine.
/// - Se la playlist usa direttamente un'immagine di TMDB, il confronto è esatto (stesso file).
/// - Altrimenti si confrontano le immagini con Vision (impronta visiva), con una soglia prudente.
enum PosterMatcher {
    /// Distanza massima tra le impronte perché due locandine siano considerate la stessa.
    static let threshold: Float = 0.42

    static func tmdbFile(_ url: URL?) -> String? {
        guard let url, url.host?.contains("tmdb.org") == true else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Possibili ricerche: titolo intero, poi le prime parole (per titoli scritti male o troncati).
    static func queries(for title: String) -> [String] {
        let words = title.split(separator: " ").map(String.init)
        var out: [String] = [title]
        if words.count > 3 { out.append(words.prefix(3).joined(separator: " ")) }
        if words.count > 2 { out.append(words.prefix(2).joined(separator: " ")) }
        if let first = words.first, first.count >= 5, words.count > 1 { out.append(first) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    static func match(title: String, isSeries: Bool, poster: URL?, tmdb: TMDBProvider) async -> MediaItem? {
        guard let poster else { return nil }
        // Candidati dal catalogo
        var candidates: [MediaItem] = []
        var ids = Set<String>()
        for q in queries(for: title).prefix(3) where q.count >= 2 {
            guard let found = try? await tmdb.search(q) else { continue }
            for item in found where item.isSeries == isSeries && item.bestPosterImage != nil && ids.insert(item.id).inserted {
                candidates.append(item)
            }
            if candidates.count >= 24 { break }
        }
        guard !candidates.isEmpty else { return nil }

        // 1) Stessa immagine TMDB
        if let file = tmdbFile(poster) {
            if let exact = candidates.first(where: { $0.poster?.lastPathComponent == file || $0.backdrop?.lastPathComponent == file }) {
                return exact
            }
        }
        // 2) Confronto visivo
        guard let source = await featurePrint(poster) else { return nil }
        var best: (MediaItem, Float)?
        for c in candidates.prefix(12) {
            guard let url = c.poster ?? c.bestPosterImage, let other = await featurePrint(url) else { continue }
            var d: Float = .greatestFiniteMagnitude
            guard (try? source.computeDistance(&d, to: other)) != nil else { continue }
            if d < (best?.1 ?? .greatestFiniteMagnitude) { best = (c, d) }
        }
        if let best, best.1 <= threshold { return best.0 }
        return nil
    }

    /// Impronta visiva di un'immagine (scaricata in piccolo).
    static func featurePrint(_ url: URL) async -> VNFeaturePrintObservation? {
        var small = url
        // Locandine TMDB in formato ridotto: più veloci da scaricare
        if url.host?.contains("tmdb.org") == true, url.pathComponents.count >= 4 {
            small = URL(string: "https://image.tmdb.org/t/p/w185/" + url.lastPathComponent) ?? url
        }
        var request = URLRequest(url: small, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 Lumen", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 300,
              ] as CFDictionary) else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([req])) != nil else { return nil }
        return req.results?.first as? VNFeaturePrintObservation
    }
}
