import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library

    @State private var query = ""
    @State private var recommended: [MediaItem] = []
    @State private var results: [MediaItem] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "Cerca", showsLogo: false)
            searchBar
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    recommendedList
                } else {
                    resultsGrid
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollIndicators(.hidden)
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: app.contentKey) {
            recommended = (try? await app.provider.home().allItems) ?? []
        }
        .task(id: query + app.contentKey) { await runSearch() }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                TextField("", text: $query, prompt: Text("Cerca serie, film…").foregroundColor(Theme.secondaryText))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10))

            if focused || !query.isEmpty {
                Button("Annulla") {
                    query = ""
                    focused = false
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .animation(.snappy(duration: 0.2), value: focused)
    }

    private var recommendedList: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            Text("Serie TV e film consigliati")
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            ForEach(recommended) { item in
                HStack(spacing: 12) {
                    Button { app.detailItem = item } label: {
                        HStack(spacing: 12) {
                            ImageTile(url: item.bestWideImage, width: 132, height: 74, corner: 4)
                                .overlay(alignment: .bottomLeading) {
                                    if let badge = item.badge { PillBadge(text: badge).padding(4).scaleEffect(0.85, anchor: .bottomLeading) }
                                }
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await Playback.play(item: item, app: app, library: library) }
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 16)
            }
        }
        .padding(.bottom, Theme.tabBarHeight + 20)
    }

    @ViewBuilder
    private var resultsGrid: some View {
        if searching && results.isEmpty {
            ProgressView().tint(.white).padding(.top, 60)
        } else if let errorMessage {
            Text(errorMessage).foregroundStyle(Theme.secondaryText).padding(32)
        } else if results.isEmpty {
            VStack(spacing: 8) {
                Text("Nessun risultato").font(.headline)
                Text("Prova con un altro titolo, genere o parola chiave.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Risultati").font(.system(size: 18, weight: .bold))
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results) { item in
                        Button { app.detailItem = item } label: {
                            Color.clear
                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .overlay(RemoteImage(url: item.bestPosterImage))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel(item.title)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, Theme.tabBarHeight + 20)
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        searching = true
        defer { searching = false }
        do {
            try await Task.sleep(for: .milliseconds(300))
            results = try await app.provider.search(q)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
