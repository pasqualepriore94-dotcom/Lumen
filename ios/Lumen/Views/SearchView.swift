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
    /// Ricerca con Apple Intelligence (al posto di quella classica, quando disponibile).
    @State private var assistant = LumenAssistant()
    private var aiSearch: Bool { LumenAssistant.unavailableReason == nil }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "Cerca", showsLogo: false)
            searchBar
            ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("search-top")
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    recommendedList
                } else {
                    resultsGrid
                }
            }
            .scrollsToTop(.search, proxy: proxy, anchor: "search-top")
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollIndicators(.hidden)
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: app.contentKey) {
            recommended = (try? await app.provider.home().allItems) ?? []
        }
        .task(id: query + app.contentKey) {
            if aiSearch {
                // Aspetta che tu finisca di scrivere, poi cerca con Apple Intelligence
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(850))
                guard !Task.isCancelled else { return }
                await assistant.ask(q, app: app, library: library)
            } else {
                await runSearch()
            }
        }
        .onAppear { if aiSearch { assistant.prewarm(library: library) } }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                TextField("", text: $query, prompt: Text(LumenAssistant.unavailableReason == nil ? "Un titolo o cosa ti va di vedere…" : "Cerca serie, film…").foregroundColor(Theme.secondaryText))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .liquidGlassCapsule()

            if focused || !query.isEmpty {
                Button {
                    query = ""
                    focused = false
                } label: {
                    Text("Annulla").font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 46)
                }
                .buttonStyle(GlassButtonStyle())
                .foregroundStyle(.white)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.2), value: focused)
    }

    private var recommendedList: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if app.provider.capabilities.browse {
                Button { app.showCatalog = true } label: {
                    Label("Esplora tutto il catalogo", systemImage: "square.grid.3x3")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(GlassButtonStyle(tint: app.accent))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            Text("Serie TV e film consigliati")
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            ForEach(recommended) { item in
                HStack(spacing: 12) {
                    Button { app.detailItem = item } label: {
                        HStack(spacing: 12) {
                            ImageTile(url: item.bestWideImage, width: 132, height: 74, corner: 12)
                                .overlay(alignment: .bottomLeading) {
                                    if let fresh = FreshnessStore.shared.badge(for: item.id) { FreshBadge(kind: fresh, compact: true).padding(4) }
                                    else if let badge = item.badge { PillBadge(text: badge).padding(4).scaleEffect(0.85, anchor: .bottomLeading) }
                                }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    if let score = item.scoreLabel {
                                        Label(score, systemImage: "star.fill").labelStyle(.titleAndIcon)
                                    }
                                    if let year = item.year { Text(String(year)) }
                                    Text(item.isSeries ? "Serie" : "Film")
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    Button {
                        if app.provider.capabilities.streams {
                            Task { await Playback.play(item: item, app: app, library: library) }
                        } else {
                            app.detailItem = item
                        }
                    } label: {
                        Image(systemName: app.provider.capabilities.streams ? "play.fill" : "info")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                }
                .padding(.trailing, 16)
            }
        }
        .padding(.bottom, Theme.tabBarHeight + 20)
    }

    @ViewBuilder
    private var resultsGrid: some View {
        if aiSearch {
            aiResults
        } else {
            classicResults
        }
    }

    @ViewBuilder
    private var aiResults: some View {
        switch assistant.state {
        case .idle, .thinking where !assistant.hasResults:
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Cerco con Apple Intelligence…").font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, 60)
        case .failed(let message):
            VStack(spacing: 8) {
                Text("Nessun risultato").font(.headline)
                Text(message).font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
            .padding(32)
        default:
            AssistantResults(assistant: assistant) { app.detailItem = $0 }
                .padding(.horizontal, 16)
                .padding(.bottom, Theme.tabBarHeight + 20)
        }
    }

    @ViewBuilder
    private var classicResults: some View {
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
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            let local = LinkLibrary.shared.customItems.filter { $0.title.localizedCaseInsensitiveContains(q) }
            results = local + (try await app.provider.search(q))
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
