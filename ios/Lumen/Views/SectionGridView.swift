import SwiftUI

/// "Mostra tutto": il catalogo completo di una categoria della home, a griglia e con scorrimento infinito.
struct SectionGridView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let section: CatalogSection

    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selected: MediaItem?

    private let columns = [GridItem(.adaptive(minimum: 106), spacing: 10)]

    private var tmdb: TMDBProvider? {
        guard section.source != nil else { return nil }
        return app.provider as? TMDBProvider
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
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
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(AuroraBackground(accent: app.accent).opacity(0.5))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } }
            }
            .sheet(item: $selected) { DetailView(item: $0) }
        }
        .preferredColorScheme(.dark)
        .task { await reload() }
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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(item.title)
    }

    private func reload() async {
        errorMessage = nil
        guard tmdb != nil else {
            // Sorgente senza paginazione: mostra tutti i titoli della riga.
            items = section.items.map { var i = $0; i.rank = nil; return i }
            page = 1; totalPages = 1
            return
        }
        items = []
        page = 0
        totalPages = 1
        await loadMore()
    }

    private func loadMore() async {
        guard let tmdb, let source = section.source, !loading, page < totalPages else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await tmdb.sectionPage(source, page: page + 1)
            let known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            page = result.page
            totalPages = result.totalPages
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
