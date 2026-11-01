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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    chips(proxy: proxy).id("top")

                    if let feed {
                        if let hero = heroItem(feed) {
                            HeroCard(item: hero)
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
                    .background(.ultraThinMaterial.opacity(0.9))
                    .background(Color.black.opacity(0.35))
            }
            .refreshable { await load() }
        }
        .task(id: app.contentKey) { await load() }
    }

    // MARK: Filtri

    @ViewBuilder
    private func chips(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if activeFilter != nil {
                    Button {
                        withAnimation(.snappy) { activeFilter = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(.white.opacity(0.5)))
                    }
                }
                ForEach(HomeFilter.allCases.filter { activeFilter == nil || activeFilter == $0 }) { f in
                    Button {
                        withAnimation(.snappy) { activeFilter = (activeFilter == f) ? nil : f }
                    } label: {
                        Text(f.rawValue).chipStyle(selected: activeFilter == f)
                    }
                }
                Menu {
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
                    .chipStyle(selected: false)
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
    func chipStyle(selected: Bool) -> some View {
        self
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(selected ? Color.white.opacity(0.25) : Color.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(selected ? 0.0 : 0.35), lineWidth: 0.8))
    }
}

// MARK: - Hero

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
                    PrimaryButton(title: item.isSeries ? "Riproduci serie" : "Riproduci") {
                        Task { await Playback.play(item: item, app: app, library: library) }
                    }
                    SecondaryButton(title: "La mia lista", icon: library.contains(item) ? "checkmark" : "plus") {
                        withAnimation { library.toggle(item) }
                    }
                }
                .foregroundStyle(.white)
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onTapGesture { app.detailItem = item }
    }

    private var metaLine: String {
        let kind = item.isSeries ? "Serie" : "Film"
        return ([kind] + (item.tags ?? [])).joined(separator: "  •  ")
    }
}

// MARK: - Righe

struct SectionRow: View {
    let section: CatalogSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: section.title)
            PosterRow(items: section.items, layout: section.layout)
        }
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
                        if let badge = item.badge { PillBadge(text: badge).padding(6) }
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
                }
                Spacer()
                Menu {
                    Button("Dettagli", systemImage: "info.circle") { app.detailItem = entry.item }
                    Button("Rimuovi dalla riga", systemImage: "xmark", role: .destructive) {
                        withAnimation { library.removeProgress(entry.item.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                }
            }
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Theme.surface)
        }
        .frame(width: 112)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
