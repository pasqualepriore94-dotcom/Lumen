import SwiftUI

/// Piattaforma di streaming (Netflix, Prime Video, Disney+…) con il suo id TMDB/JustWatch per l'Italia.
struct StreamingPlatform: Identifiable, Hashable, Codable {
    var id: Int
    var name: String
    var logo: URL?
}

/// Elenco delle piattaforme disponibili in Italia, preso da TMDB (dati JustWatch) e salvato sul telefono.
@MainActor
@Observable
final class PlatformCatalog {
    static let shared = PlatformCatalog()
    private static let cacheKey = "lumen.platforms.it"

    /// Piattaforme in abbonamento più diffuse, nell'ordine in cui compaiono.
    private static let wanted: [(match: String, name: String)] = [
        ("netflix", "Netflix"), ("amazon prime video", "Prime Video"), ("disney plus", "Disney+"),
        ("apple tv", "Apple TV"), ("now", "NOW"), ("paramount plus", "Paramount+"),
        ("rai play", "RaiPlay"), ("mediaset infinity", "Mediaset Infinity"), ("timvision", "TIMVISION"),
        ("discovery", "discovery+"), ("crunchyroll", "Crunchyroll"), ("mubi", "MUBI")
    ]
    /// Se TMDB non risponde: id noti delle principali.
    private static let fallback: [StreamingPlatform] = [
        .init(id: 8, name: "Netflix"), .init(id: 119, name: "Prime Video"), .init(id: 337, name: "Disney+"),
        .init(id: 350, name: "Apple TV"), .init(id: 39, name: "NOW"), .init(id: 531, name: "Paramount+")
    ]

    private(set) var platforms: [StreamingPlatform] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let list = try? JSONDecoder().decode([StreamingPlatform].self, from: data) {
            platforms = list
        }
    }

    func load(tmdb: TMDBProvider?) async {
        guard let tmdb else { if platforms.isEmpty { platforms = Self.fallback }; return }
        guard let json = try? await tmdb.get("/watch/providers/movie", ["watch_region": "IT"]),
              let results = json["results"] as? [[String: Any]] else {
            if platforms.isEmpty { platforms = Self.fallback }
            return
        }
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "+", with: " plus")
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        var found: [StreamingPlatform] = []
        for w in Self.wanted {
            // Il nome esatto o che inizia così, scartando le varianti ("with Ads", "Channel", "Store"…)
            let candidates = results.filter { r in
                let n = norm(r["provider_name"] as? String ?? "")
                let bad = ["ads", "channel", "store", "kids", "amazon channel", "standard"].contains { n.contains($0) }
                return !bad && (n == w.match || n.hasPrefix(w.match + " ") || (w.match == "apple tv" && n.hasPrefix("apple tv")))
            }
            guard let r = candidates.first, let id = r["provider_id"] as? Int, !found.contains(where: { $0.id == id }) else { continue }
            let logo = (r["logo_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w154\($0)") }
            found.append(StreamingPlatform(id: id, name: w.name, logo: logo))
        }
        guard !found.isEmpty else { if platforms.isEmpty { platforms = Self.fallback }; return }
        platforms = found
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }
}

/// Riga "Piattaforme" della Home: i loghi dei servizi, toccandone uno si apre il suo catalogo.
struct PlatformsRow: View {
    @Environment(AppState.self) private var app
    var initialKind: MediaKind = .movie
    @State private var selected: StreamingPlatform?
    private var catalog: PlatformCatalog { PlatformCatalog.shared }

    var body: some View {
        if !catalog.platforms.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Piattaforme")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(catalog.platforms) { p in
                            Button { selected = p } label: { PlatformTile(platform: p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
            .sheet(item: $selected) { PlatformView(platform: $0, kind: initialKind) }
        }
    }
}

struct PlatformTile: View {
    let platform: StreamingPlatform
    var size: CGFloat = 76

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceHigh)
                if let logo = platform.logo {
                    RemoteImage(url: logo, maxPixel: 300)
                } else {
                    Text(platform.name).font(.caption.bold()).multilineTextAlignment(.center).padding(6)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.6))
            Text(platform.name).font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                .frame(width: size + 8)
        }
    }
}

/// Catalogo di una piattaforma in Italia: film o serie, ordinati per popolarità, novità o voto.
struct PlatformView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let platform: StreamingPlatform
    @State var kind: MediaKind

    enum Sort: String, CaseIterable, Identifiable {
        case popular = "Popolari", recent = "Novità", rated = "Più votati"
        var id: String { rawValue }
    }
    @State private var sort: Sort = .popular
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selected: MediaItem?

    private let columns = [GridItem(.adaptive(minimum: 106), spacing: 10)]
    private var tmdb: TMDBProvider? {
        app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }
    }

    private var source: SectionSource {
        var q = ["with_watch_providers": String(platform.id), "watch_region": "IT",
                 "with_watch_monetization_types": "flatrate"]
        let isMovie = kind == .movie
        switch sort {
        case .popular: q["sort_by"] = "popularity.desc"
        case .recent:
            q["sort_by"] = isMovie ? "primary_release_date.desc" : "first_air_date.desc"
            q[isMovie ? "primary_release_date.lte" : "first_air_date.lte"] = Date().formatted(.iso8601.year().month().day())
            q["vote_count.gte"] = "5"
        case .rated:
            q["sort_by"] = "vote_average.desc"
            q["vote_count.gte"] = "300"
        }
        return SectionSource(path: isMovie ? "/discover/movie" : "/discover/tv", query: q, kind: kind)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        PlatformTile(platform: platform, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(platform.name).font(.title2.bold())
                            Text("Incluso nell'abbonamento in Italia").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    Picker("Tipo", selection: $kind) {
                        Text("Film").tag(MediaKind.movie)
                        Text("Serie TV").tag(MediaKind.series)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    Picker("Ordine", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if let errorMessage, items.isEmpty {
                        ErrorStateView(message: errorMessage) { Task { await reload() } }
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(items) { item in
                            Button { selected = item } label: {
                                Color.clear
                                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                    .overlay(RemoteImage(url: item.bestPosterImage, maxPixel: ImagePipeline.posterPixels))
                .watchedMark(item)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                        }
                    }
                    .padding(.horizontal, 16)
                    if loading {
                        ProgressView().tint(.white).padding()
                    } else if !items.isEmpty && page >= totalPages {
                        Text("Hai visto tutto: \(items.count) titoli.").font(.footnote).foregroundStyle(Theme.secondaryText).padding()
                    }
                    Text("Disponibilità in Italia da JustWatch tramite TMDB: può arrivare con qualche giorno di ritardo.")
                        .font(.caption2).foregroundStyle(Theme.secondaryText).padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(platform.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } } }
            .sheet(item: $selected) { DetailView(item: $0) }
        }
        .preferredColorScheme(.dark)
        .task(id: "\(kind)-\(sort)") { await reload() }
    }

    private func reload() async {
        items = []; page = 0; totalPages = 1; errorMessage = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, page < totalPages else { return }
        guard let tmdb else { errorMessage = "Serve il catalogo TMDB."; return }
        loading = true
        defer { loading = false }
        do {
            let result = try await tmdb.sectionPage(source, page: page + 1)
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            page = result.page
            totalPages = result.totalPages
        } catch {
            errorMessage = "Non riesco a caricare il catalogo. Riprova."
        }
    }
}
