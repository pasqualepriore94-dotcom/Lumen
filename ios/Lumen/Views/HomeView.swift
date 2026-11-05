import SwiftUI

enum HomeFilter: String, CaseIterable, Identifiable {
    case series = "Serie"
    case movies = "Film"
    case new = "Novità del momento"
    var id: String { rawValue }
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library

    @State private var feed: HomeFeed?
    @State private var errorMessage: String?
    @State private var activeFilter: HomeFilter?
    @State private var showLive = false
    @State private var showAssistant = false
    @State private var showCustom = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    chips(proxy: proxy).id("top")

                    if let feed {
                        let heroes = heroItems(feed)
                        if !heroes.isEmpty {
                            HeroCarousel(items: heroes)
                        }
                        if activeFilter == nil && !library.continueWatching.isEmpty {
                            ContinueWatchingRow(entries: library.continueWatching)
                        }
                        if activeFilter == nil && !library.myList.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "La mia lista", actionTitle: "Vedi tutto") {
                                    app.selectedTab = .profile
                                }
                                PosterRow(items: library.myList, layout: .poster)
                            }
                        }
                        ForEach(filteredSections(feed)) { section in
                            SectionRow(section: section).id(section.id)
                        }
                    } else if let errorMessage {
                        ErrorStateView(message: errorMessage) { Task { await load() } }
                            .padding(.top, 80)
                    } else {
                        ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 160)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, Theme.tabBarHeight + 24)
            }
            .scrollIndicators(.hidden)
            .background(alignment: .top) {
                LinearGradient(colors: [app.accent.opacity(0.45), app.accent.opacity(0.12), .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 620)
                    .ignoresSafeArea()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                TabHeader(title: "Home")
                    .background {
                        LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.35), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .top)
                    }
            }
            .refreshable { await load() }
            .scrollsToTop(.home, proxy: proxy, anchor: "top")
        }
        .task(id: app.contentKey) { await load() }
        .sheet(isPresented: $showLive) { LiveChannelsView() }
        .sheet(isPresented: $showAssistant) { AssistantView() }
        .sheet(isPresented: $showCustom) {
            SectionGridView(section: CatalogSection(id: "custom", title: "Altri contenuti", style: nil,
                                                    items: LinkLibrary.shared.customItems))
        }
    }

    // MARK: Filtri

    @ViewBuilder
    private func chips(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if activeFilter == nil {
                    Button { showAssistant = true } label: {
                        Label("Chiedi a Lumen", systemImage: "sparkles").chipStyle()
                    }
                    .buttonStyle(GlassButtonStyle(tint: app.accent.opacity(0.6)))
                }
                if activeFilter != nil {
                    Button {
                        withAnimation(.snappy) { activeFilter = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                }
                ForEach(HomeFilter.allCases.filter { activeFilter == nil || activeFilter == $0 }) { f in
                    Button {
                        withAnimation(.snappy) { activeFilter = (activeFilter == f) ? nil : f }
                    } label: {
                        Text(f.rawValue).chipStyle()
                    }
                    .buttonStyle(GlassButtonStyle(tint: activeFilter == f ? app.accent : nil))
                }
                Menu {
                    if app.provider.capabilities.browse {
                        Button("Esplora tutto il catalogo", systemImage: "square.grid.3x3") { app.showCatalog = true }
                    }
                    if LinkLibrary.shared.matchedItems.keys.contains(where: { $0.hasPrefix("link-") }) {
                        Button("Altri contenuti", systemImage: "square.stack") { showCustom = true }
                    }
                    if LinkLibrary.shared.liveCount > 0 {
                        Button("Dirette (\(LinkLibrary.shared.liveCount))", systemImage: "dot.radiowaves.left.and.right") { showLive = true }
                    }
                    Divider()
                    ForEach(feed?.sections ?? []) { section in
                        Button(section.title) {
                            withAnimation { proxy.scrollTo(section.id, anchor: .top) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Categorie")
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .chipStyle()
                    .liquidGlassCapsule(interactive: true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func matches(_ item: MediaItem) -> Bool {
        switch activeFilter {
        case .none: return true
        case .series: return item.kind == .series
        case .movies: return item.kind != .series
        case .new: return item.badge != nil
        }
    }

    private func filteredSections(_ feed: HomeFeed) -> [CatalogSection] {
        feed.sections.compactMap { section in
            var s = section
            s.items = section.items.filter(matches)
            return s.items.isEmpty ? nil : s
        }
    }

    /// Titoli in evidenza da scorrere: il principale più i primi di ogni categoria, senza doppioni.
    private func heroItems(_ feed: HomeFeed) -> [MediaItem] {
        var out: [MediaItem] = []
        var seen = Set<String>()
        func add(_ i: MediaItem?) {
            guard let i, matches(i), i.bestPosterImage != nil, seen.insert(i.id).inserted else { return }
            out.append(i)
        }
        add(heroItem(feed))
        let sections = filteredSections(feed)
        for depth in 0..<3 {
            for s in sections where s.items.count > depth { add(s.items[depth]); if out.count >= 8 { return out } }
        }
        return out
    }

    private func heroItem(_ feed: HomeFeed) -> MediaItem? {
        if activeFilter == nil { return feed.hero ?? feed.allItems.first }
        return feed.allItems.first(where: matches)
    }

    private func load() async {
        do {
            let result = try await app.provider.home()
            feed = result
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            if feed == nil { errorMessage = error.localizedDescription }
        }
    }
}

private extension View {
    func chipStyle() -> some View {
        self
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 36)
    }
}

// MARK: - Hero

/// Contenuti in evidenza a scorrimento orizzontale, con avanzamento automatico.
struct HeroCarousel: View {
    @Environment(AppState.self) private var app
    let items: [MediaItem]
    @State private var position: Int? = 0
    @State private var lastInteraction = Date()
    @State private var autoAdvancing = false

    private var index: Int { position ?? 0 }
    private var cardHeight: CGFloat { (UIScreen.main.bounds.width - 32) / 0.7 }

    var body: some View {
        VStack(spacing: 10) {
            // Scorrimento a pagine orizzontale (al posto di TabView, che dentro la home
            // a volte si posizionava qualche punto più in basso al primo caricamento).
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        HeroCard(item: item)
                            .containerRelativeFrame(.horizontal)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .frame(height: cardHeight)
            .onChange(of: position) {
                if autoAdvancing { autoAdvancing = false } else { lastInteraction = Date() }
            }

            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? app.accent : .white.opacity(0.35))
                            .frame(width: i == index ? 18 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: index)
                .padding(.top, 6)
            }
        }
        .onChange(of: items.map(\.id)) { position = 0 }
        // Scorre da solo ogni 5 secondi; dopo uno slide manuale aspetta qualche secondo in più.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            guard items.count > 1, Date().timeIntervalSince(lastInteraction) > 4.5 else { return }
            autoAdvancing = true
            withAnimation(.easeInOut(duration: 0.7)) { position = (index + 1) % items.count }
        }
    }
}

struct HeroCard: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    let item: MediaItem

    var body: some View {
        Color.clear
            .aspectRatio(0.7, contentMode: .fit)
            .overlay(RemoteImage(url: item.bestPosterImage))
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                       .init(color: .black.opacity(0.55), location: 0.65),
                                       .init(color: .black.opacity(0.92), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    if let fresh = FreshnessStore.shared.badge(for: item.id) { FreshBadge(kind: fresh) }
                    Text(item.title.uppercased())
                        .font(.system(size: 34, weight: .black, design: .default))
                        .tracking(1)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.6), radius: 8)
                    Text(metaLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    if app.provider.capabilities.streams {
                        PrimaryButton(title: item.isSeries ? "Riproduci serie" : "Riproduci") {
                            Task { await Playback.play(item: item, app: app, library: library) }
                        }
                    } else {
                        PrimaryButton(title: "Scopri di più", icon: "info.circle") { app.detailItem = item }
                    }
                    SecondaryButton(title: "La mia lista", icon: library.contains(item) ? "checkmark" : "plus") {
                        withAnimation { library.toggle(item) }
                    }
                }
                .foregroundStyle(.white)
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05), .white.opacity(0.25)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: app.accent.opacity(0.35), radius: 30, y: 14)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onTapGesture { app.detailItem = item }
    }

    private var metaLine: String {
        var parts = [item.isSeries ? "Serie" : "Film"]
        if let score = item.scoreLabel { parts.append("★ \(score)") }
        return (parts + (item.tags ?? [])).joined(separator: "  •  ")
    }
}

// MARK: - Righe

struct SectionRow: View {
    let section: CatalogSection
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: section.title, actionTitle: "Mostra tutto") { showAll = true }
            PosterRow(items: section.items, layout: section.layout)
        }
        .sheet(isPresented: $showAll) { SectionGridView(section: section) }
    }
}

struct PosterRow: View {
    @Environment(AppState.self) private var app
    let items: [MediaItem]
    let layout: SectionLayout

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: layout == .top10 ? 14 : 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { app.detailItem = item } label: { cell(item, index: index) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func cell(_ item: MediaItem, index: Int) -> some View {
        switch layout {
        case .poster:
            PosterCard(item: item)
        case .large:
            PosterCard(item: item, width: 168, aspect: 0.62)
        case .top10:
            HStack(alignment: .bottom, spacing: -22) {
                Text("\(item.rank ?? index + 1)")
                    .font(.system(size: 110, weight: .black))
                    .foregroundStyle(.black)
                    .shadow(color: .white.opacity(0.9), radius: 0.8)
                    .shadow(color: .white.opacity(0.9), radius: 0.8)
                    .offset(y: 18)
                PosterCard(item: item)
            }
        case .wide:
            VStack(alignment: .leading, spacing: 6) {
                ImageTile(url: item.bestWideImage, width: 220, height: 124)
                    .overlay(alignment: .bottomLeading) {
                        if let fresh = FreshnessStore.shared.badge(for: item.id) { FreshBadge(kind: fresh).padding(6) }
                        else if let badge = item.badge { PillBadge(text: badge).padding(6) }
                    }
                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1).frame(width: 220, alignment: .leading)
            }
        }
    }
}

struct ContinueWatchingRow: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    let entries: [WatchProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Continua a guardare")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(entries) { entry in card(entry) }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func card(_ entry: WatchProgress) -> some View {
        VStack(spacing: 0) {
            Button {
                Task { await Playback.play(item: entry.item, app: app, library: library) }
            } label: {
                ZStack {
                    ImageTile(url: entry.item.bestPosterImage, width: 112, height: 150, corner: 0)
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
                .overlay(alignment: .bottom) {
                    if let label = entry.episodeLabel {
                        Text(label.components(separatedBy: " ").first ?? label)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.bottom, 4)
                            .shadow(radius: 3)
                    }
                }
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25))
                    Rectangle().fill(app.accent).frame(width: geo.size.width * entry.fraction)
                }
            }
            .frame(height: 3)

            HStack {
                Button { app.detailItem = entry.item } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 44, height: 36, alignment: .leading)
                        .contentShape(Rectangle())
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Dettagli", systemImage: "info.circle") { app.detailItem = entry.item }
                    Button("Rimuovi dalla riga", systemImage: "xmark", role: .destructive) {
                        withAnimation { library.removeProgress(entry.item.id) }
                    }
                } label: {
                    // Area di tocco ampia: non serve centrare i puntini.
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                        .frame(width: 52, height: 36, alignment: .trailing)
                        .contentShape(Rectangle())
                }
            }
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 36)
            .background(.ultraThinMaterial)
        }
        .frame(width: 112)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.6))
    }
}
