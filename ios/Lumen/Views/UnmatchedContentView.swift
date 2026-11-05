import SwiftUI

/// Amministrazione → Contenuti non abbinati: voci della playlist senza scheda nel catalogo,
/// divise in film, serie TV e dirette. Si possono abbinare a mano a una scheda o aggiungere al catalogo così come sono.
struct UnmatchedContentView: View {
    enum Tab: String, CaseIterable { case movies = "Film", series = "Serie TV", lives = "Dirette" }

    @Environment(AppState.self) private var app
    @State private var links = LinkLibrary.shared
    @State private var tab: Tab = .lives
    @State private var search = ""
    @State private var loading = true
    @State private var movies: [MovieProposal] = []
    @State private var series: [SeriesProposal] = []
    @State private var lives: [LinkMedia] = []
    @State private var selection = Set<String>()
    @State private var message: String?
    @State private var matching: MatchTarget?

    struct MatchTarget: Identifiable {
        var id: String
        var query: String
        var year: Int?
        var isSeries: Bool
        var movie: MovieProposal?
        var series: SeriesProposal?
    }

    private var importedLives: Set<String> { Set(links.items.filter(\.isLive).map(\.id)) }
    private var q: String { search.trimmingCharacters(in: .whitespaces).lowercased() }
    private var shownMovies: [MovieProposal] { q.isEmpty ? movies : movies.filter { $0.media.title.lowercased().contains(q) } }
    private var shownSeries: [SeriesProposal] { q.isEmpty ? series : series.filter { $0.name.lowercased().contains(q) } }
    private var shownLives: [LinkMedia] {
        q.isEmpty ? lives : lives.filter { ($0.title + " " + ($0.group ?? "")).lowercased().contains(q) }
    }

    private var visibleIds: [String] {
        switch tab {
        case .movies: return shownMovies.map(\.id)
        case .series: return shownSeries.map(\.id)
        case .lives: return shownLives.filter { !importedLives.contains($0.id) }.map(\.id)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Tipo", selection: $tab) {
                    Text("Film (\(movies.count))").tag(Tab.movies)
                    Text("Serie (\(series.count))").tag(Tab.series)
                    Text("Dirette (\(lives.count))").tag(Tab.lives)
                }
                .pickerStyle(.segmented)
                TextField("Cerca", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text(footer)
            }

            if loading {
                Section { HStack { ProgressView(); Text("Lettura dei contenuti…").foregroundStyle(.secondary) } }
            } else {
                switch tab {
                case .movies: moviesSection
                case .series: seriesSection
                case .lives: livesSection
                }
            }
        }
        .navigationTitle("Contenuti non abbinati")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { actionBar }
        .onChange(of: tab) { selection = [] }
        .sheet(item: $matching) { target in
            ManualMatchSheet(query: target.query, year: target.year, isSeries: target.isSeries) { item in
                if let m = target.movie {
                    links.matchManually(movie: m.media, to: item)
                    movies.removeAll { $0.id == m.id }
                } else if let s = target.series {
                    links.matchManually(series: s.episodes, to: item)
                    series.removeAll { $0.id == s.id }
                }
                message = "Abbinato a \(item.title)."
            }
        }
        .task { await load() }
    }

    private var footer: String {
        switch tab {
        case .movies, .series:
            return "Voci senza scheda nel catalogo. \"Abbina\" ti fa scegliere la scheda giusta; \"Aggiungi al catalogo\" le inserisce così come sono, in Home → Categorie → Altri contenuti."
        case .lives:
            return "Tutte le dirette delle playlist caricate. Quelle aggiunte compaiono in Home → Categorie → Dirette."
        }
    }

    // MARK: Sezioni

    private var moviesSection: some View {
        Section("Film senza scheda") {
            ForEach(shownMovies.prefix(500)) { m in
                row(id: m.id, title: m.parsed.title, subtitle: m.media.title, poster: m.media.poster) {
                    matching = MatchTarget(id: m.id, query: m.parsed.title, year: m.parsed.year, isSeries: false, movie: m)
                }
            }
            if shownMovies.count > 500 { Text("Mostrati 500 di \(shownMovies.count). \"Tutti\" li seleziona tutti.").font(.caption) }
        }
    }

    private var seriesSection: some View {
        Section("Serie senza scheda") {
            ForEach(shownSeries.prefix(500)) { s in
                row(id: s.id, title: s.name, subtitle: "\(s.episodes.count) episodi · \(s.seasons.count) stagioni", poster: s.poster) {
                    matching = MatchTarget(id: s.id, query: s.name, year: s.year, isSeries: true, series: s)
                }
            }
            if shownSeries.count > 500 { Text("Mostrate 500 di \(shownSeries.count).").font(.caption) }
        }
    }

    private var livesSection: some View {
        let imported = importedLives
        return Section("Dirette") {
            ForEach(shownLives.prefix(800)) { m in
                let added = imported.contains(m.id)
                HStack(spacing: 12) {
                    checkbox(m.id, disabled: added)
                    ImageTile(url: m.poster, width: 40, height: 40, corner: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).font(.subheadline).lineLimit(1)
                        Text(m.group ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if added {
                        Text("Nelle Dirette").font(.caption2.bold()).foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if !added { toggle(m.id) } }
            }
            if shownLives.count > 800 { Text("Mostrate 800 di \(shownLives.count). \"Tutti\" le seleziona tutte.").font(.caption) }
        }
    }

    private func row(id: String, title: String, subtitle: String, poster: URL?, match: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            checkbox(id, disabled: false)
            ImageTile(url: poster, width: 40, height: 56, corner: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Abbina", action: match).font(.caption.bold()).buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(id) }
    }

    private func checkbox(_ id: String, disabled: Bool) -> some View {
        Image(systemName: disabled ? "checkmark.circle.fill" : (selection.contains(id) ? "checkmark.circle.fill" : "circle"))
            .foregroundStyle(disabled ? Color.green.opacity(0.6) : (selection.contains(id) ? app.accent : .secondary))
            .font(.title3)
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    // MARK: Azioni

    private var actionBar: some View {
        let all = Set(visibleIds)
        let allSelected = !all.isEmpty && all.isSubset(of: selection)
        return HStack(spacing: 10) {
            Button(allSelected ? "Nessuno" : "Tutti (\(all.count))") {
                if allSelected { selection.subtract(all) } else { selection.formUnion(all) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .buttonStyle(GlassButtonStyle())
            Button {
                addSelected()
            } label: {
                Text(tab == .lives ? "Aggiungi alle Dirette (\(selection.count))" : "Aggiungi al catalogo (\(selection.count))")
                    .font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(GlassButtonStyle(tint: app.accent))
            .disabled(selection.isEmpty)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func addSelected() {
        let chosen = selection
        switch tab {
        case .movies:
            let list = movies.filter { chosen.contains($0.id) }
            links.addCustomMovies(list.map(\.media))
            movies.removeAll { chosen.contains($0.id) }
            message = "\(list.count) film aggiunti al catalogo (Categorie → Altri contenuti)."
        case .series:
            let list = series.filter { chosen.contains($0.id) }
            links.addCustomSeries(list.map { (name: $0.name, year: $0.year, poster: $0.poster, episodes: $0.episodes) })
            series.removeAll { chosen.contains($0.id) }
            message = "\(list.count) serie aggiunte al catalogo (Categorie → Altri contenuti)."
        case .lives:
            let list = lives.filter { chosen.contains($0.id) }
            links.add(list)
            message = "\(list.count) dirette aggiunte (Categorie → Dirette)."
        }
        selection = []
    }

    private func load() async {
        loading = true
        await links.loadIfNeeded()
        let unmatched = links.items.filter { !$0.isLive }
        let grouped = await Task.detached(priority: .userInitiated) { LinkMapper.group(unmatched) }.value
        movies = grouped.movies
        series = grouped.series
        // Dirette: quelle già aggiunte più tutte quelle delle playlist caricate
        var all = links.items.filter(\.isLive)
        var known = Set(all.map(\.id))
        for p in PlaylistStore.shared.playlists {
            for m in await PlaylistStore.shared.mediaAsync(of: p) where m.isLive && known.insert(m.id).inserted { all.append(m) }
        }
        lives = all
        loading = false
    }
}

/// Ricerca nel catalogo per scegliere a mano la scheda giusta di un contenuto.
struct ManualMatchSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var query: String
    let year: Int?
    let isSeries: Bool
    var onPick: (MediaItem) -> Void
    @State private var results: [MediaItem] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Titolo", text: $query).autocorrectionDisabled()
                        .onSubmit { Task { await run() } }
                    Button("Cerca") { Task { await run() } }
                }
                if searching { ProgressView() }
                ForEach(results) { item in
                    Button {
                        onPick(item)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ImageTile(url: item.bestPosterImage, width: 46, height: 69, corner: 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Text([item.year.map(String.init), item.isSeries ? "Serie TV" : "Film"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Abbina a una scheda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } } }
            .task { await run() }
        }
        .preferredColorScheme(.dark)
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        let found = (try? await app.provider.search(q)) ?? []
        // Prima quelli del tipo giusto e dell'anno indicato
        results = found.sorted {
            let a = ($0.isSeries == isSeries ? 0 : 1, year != nil && $0.year == year ? 0 : 1)
            let b = ($1.isSeries == isSeries ? 0 : 1, year != nil && $1.year == year ? 0 : 1)
            return a < b
        }
    }
}
