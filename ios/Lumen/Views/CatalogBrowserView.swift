import SwiftUI

/// Tutto il catalogo della sorgente attiva, con filtri e scorrimento infinito.
struct CatalogBrowserView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var kind: MediaKind = .movie
    @State private var genre: Genre?
    @State private var sort: BrowseSort = .popular
    @State private var genres: [Genre] = []
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selected: MediaItem?

    private let columns = [GridItem(.adaptive(minimum: 106), spacing: 10)]
    private var filterKey: String { "\(kind.rawValue)|\(genre?.id ?? "")|\(sort.rawValue)|\(app.contentKey)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filters
                    if let errorMessage, items.isEmpty {
                        ErrorStateView(message: errorMessage) { Task { await reload() } }
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(items) { item in
                            Button { selected = item } label: { cell(item) }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if item.id == items.last?.id { Task { await loadMore() } }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    if loading {
                        ProgressView().tint(.white).frame(maxWidth: .infinity).padding()
                    } else if !items.isEmpty && page >= totalPages {
                        Text("Hai visto tutto: \(items.count) titoli.")
                            .font(.footnote).foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity).padding()
                    }
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(AuroraBackground(accent: app.accent).opacity(0.5))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Tutto il catalogo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } }
            }
            .sheet(item: $selected) { DetailView(item: $0) }
        }
        .preferredColorScheme(.dark)
        .task(id: kind) { genres = (try? await app.provider.genres(kind: kind)) ?? [] }
        .task(id: filterKey) { await reload() }
    }

    private var filters: some View {
        VStack(spacing: 12) {
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    kindButton(.movie, "Film")
                    kindButton(.series, "Serie TV")
                }
            }
            HStack(spacing: 10) {
                Menu {
                    Button("Tutti i generi") { genre = nil }
                    ForEach(genres) { g in Button(g.name) { genre = g } }
                } label: {
                    menuLabel(icon: "square.grid.2x2", text: genre?.name ?? "Tutti i generi")
                }
                Menu {
                    ForEach(BrowseSort.allCases) { s in
                        Button { sort = s } label: {
                            if s == sort { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                        }
                    }
                } label: {
                    menuLabel(icon: "arrow.up.arrow.down", text: sort.label)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func kindButton(_ k: MediaKind, _ title: String) -> some View {
        Button {
            withAnimation(.snappy) { kind = k; genre = nil }
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(GlassButtonStyle(tint: kind == k ? app.accent : nil))
    }

    private func menuLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.bold())
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .liquidGlassCapsule(interactive: true)
    }

    private func cell(_ item: MediaItem) -> some View {
        let match = library.taste.compatibility(item)
        return Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay(RemoteImage(url: item.bestPosterImage))
            .overlay(alignment: .bottomLeading) {
                if item.bestPosterImage == nil {
                    Text(item.title).font(.caption.bold()).padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let score = item.scoreLabel {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill").font(.system(size: 8))
                        Text(score).font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .liquidGlassCapsule()
                    .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if let match { MatchBadge(percent: match, compact: true).padding(5) }
            }
            .overlay(alignment: .bottom) {
                if let fresh = FreshnessStore.shared.badge(for: item.id) { FreshBadge(kind: fresh, compact: true).padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(item.title)
    }

    private func reload() async {
        items = []
        page = 0
        totalPages = 1
        errorMessage = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, page < totalPages else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await app.provider.browse(kind: kind, genre: genre?.id, sort: sort, page: page + 1)
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            page = result.page
            totalPages = result.totalPages
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            totalPages = page
        }
    }
}
