import SwiftUI
import UIKit

/// Pannello amministratore → "Aggiungi da link": incolla un link, l'app divide film, serie e dirette,
/// li abbina per nome al catalogo e ti propone cosa importare.
struct LinkImportView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @State private var links = LinkLibrary.shared
    @State private var mapper = LinkMapper()

    @State private var input = ""
    @State private var analyzing = false
    @State private var providerBase: String?
    @State private var providerTitles = 0
    @State private var message: String?
    @State private var tab = 0
    @State private var filterText = ""
    @State private var selMovies = Set<String>()
    @State private var selSeries = Set<String>()
    @State private var selLives = Set<String>()
    @State private var onlyMatched = false

    private var tmdb: TMDBProvider? {
        app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }
    }

    var body: some View {
        List {
            inputSection

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }

            if let base = providerBase { providerSection(base) }

            if hasResults {
                summarySection
                switch tab {
                case 0: moviesSection
                case 1: seriesSection
                default: livesSection
                }
            }

            Section {
                NavigationLink {
                    LinkedContentView()
                } label: {
                    Label("Gestisci e rimuovi contenuti caricati (\(links.matchedItems.count + links.items.count))",
                          systemImage: "list.bullet.rectangle")
                }
            }

            if !links.items.isEmpty {
                Section {
                    ForEach(links.items.prefix(200)) { m in savedRow(m) }
                        .onDelete { idx in idx.map { links.items[$0] }.forEach(links.remove) }
                } header: {
                    Text("Dirette e non abbinati (\(links.items.count))")
                } footer: {
                    Text("Contenuti importati che non hanno una scheda nel catalogo. Scorri a sinistra per eliminarli.")
                }
            }
        }
        .navigationTitle("Aggiungi da link")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if input.isEmpty, let s = UIPasteboard.general.string, s.lowercased().hasPrefix("http") { input = s }
        }
        .onDisappear { mapper.cancel() }
    }

    private var hasResults: Bool { !mapper.movies.isEmpty || !mapper.series.isEmpty || !mapper.lives.isEmpty }

    // MARK: Link

    private var inputSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("https://…", text: $input)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { analyze() }
                Button {
                    if let s = UIPasteboard.general.string { input = s; analyze() }
                } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.borderless)
            }
            Button { analyze() } label: {
                HStack {
                    Label("Analizza link", systemImage: "wand.and.stars")
                    Spacer()
                    if analyzing { ProgressView() }
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || analyzing || mapper.isMapping)
        } header: {
            Text("Link")
        } footer: {
            Text("Riconosce video MP4/MKV/MOV, flussi HLS, playlist M3U, API nel formato Lumen e pagine che pubblicano il video in modo aperto. Usa solo contenuti che hai il diritto di guardare.")
        }
    }

    private func providerSection(_ base: String) -> some View {
        Section("API trovata") {
            LabeledContent("Indirizzo", value: base).font(.footnote)
            LabeledContent("Titoli nella home", value: "\(providerTitles)").font(.footnote)
            Button {
                var p = ProviderConfig.newCustom()
                p.name = URL(string: base)?.host ?? "Nuova API"
                p.baseURL = base
                app.upsert(p)
                app.setActiveProvider(p.id)
                message = "Sorgente aggiunta e impostata come attiva."
                providerBase = nil
            } label: {
                Label("Aggiungi come sorgente e usala", systemImage: "plus.circle.fill")
            }
        }
    }

    // MARK: Riepilogo

    private var summarySection: some View {
        Section {
            HStack(spacing: 10) {
                countTile("Film", mapper.movies.count, matched: mapper.movies.filter { $0.match != nil }.count, icon: "film")
                countTile("Serie", mapper.series.count, matched: mapper.series.filter { $0.match != nil }.count, icon: "tv")
                countTile("Live", mapper.lives.count, matched: nil, icon: "dot.radiowaves.left.and.right")
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))

            if mapper.isMapping {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(mapper.done), total: Double(max(1, mapper.total))).tint(app.accent)
                    HStack {
                        Text("Abbinamento al catalogo: \(mapper.done)/\(mapper.total)").font(.caption)
                        Spacer()
                        Button("Interrompi") { mapper.cancel() }.font(.caption.bold()).buttonStyle(.borderless)
                    }
                }
            }

            Picker("Mostra", selection: $tab) {
                Text("Film (\(mapper.movies.count))").tag(0)
                Text("Serie (\(mapper.series.count))").tag(1)
                Text("Live (\(mapper.lives.count))").tag(2)
            }
            .pickerStyle(.segmented)

            TextField("Filtra per nome", text: $filterText).textInputAutocapitalization(.never)
            if tab != 2 {
                Toggle("Mostra solo quelli trovati nel catalogo", isOn: $onlyMatched).font(.footnote)
            }

            Button {
                importAll()
            } label: {
                Label("Importa film e serie selezionati (\(selMovies.count + selSeries.count))",
                      systemImage: "tray.and.arrow.down.fill")
                    .font(.body.weight(.semibold))
            }
            .disabled(selMovies.isEmpty && selSeries.isEmpty || mapper.isMapping)
        } header: {
            Text("Contenuti trovati")
        } footer: {
            Text("Film, serie e dirette sono separati automaticamente. Gli episodi sono raggruppati per serie e ogni titolo è già abbinato al catalogo: controlla l'abbinamento prima di importare.")
        }
    }

    private func countTile(_ title: String, _ count: Int, matched: Int?, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(app.accent)
            Text("\(count)").font(.title3.bold())
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if let matched {
                Text("\(matched) abbinati").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .liquidGlassCard(radius: 16)
    }

    // MARK: Film

    private var visibleMovies: [MovieProposal] {
        mapper.movies.filter { (!onlyMatched || $0.match != nil) && matchesFilter($0.media.title + " " + ($0.match?.title ?? "")) }
    }

    private var moviesSection: some View {
        Section {
            ForEach(visibleMovies.prefix(400)) { p in
                proposalRow(selected: selMovies.contains(p.id),
                            toggle: { toggle(&selMovies, p.id) },
                            sourceTitle: p.media.title,
                            sourceDetail: p.media.group,
                            match: p.match,
                            pending: mapper.isMapping && p.match == nil,
                            preview: { Playback.playLink(p.media, app: app, library: library) })
            }
        } header: {
            selectionHeader("Film", ids: Set(visibleMovies.map(\.id)), selection: $selMovies)
        }
    }

    // MARK: Serie

    private var visibleSeries: [SeriesProposal] {
        mapper.series.filter { (!onlyMatched || $0.match != nil) && matchesFilter($0.name + " " + ($0.match?.title ?? "")) }
    }

    private var seriesSection: some View {
        Section {
            ForEach(visibleSeries.prefix(400)) { s in
                proposalRow(selected: selSeries.contains(s.id),
                            toggle: { toggle(&selSeries, s.id) },
                            sourceTitle: s.name,
                            sourceDetail: "\(s.episodes.count) episodi · stagioni \(s.seasons.map(String.init).joined(separator: ", "))",
                            match: s.match,
                            pending: mapper.isMapping && s.match == nil,
                            preview: nil)
            }
            if mapper.series.isEmpty {
                Text("Nessun episodio riconosciuto (nomi tipo \"Serie S01E02\").").foregroundStyle(.secondary)
            }
        } header: {
            selectionHeader("Serie", ids: Set(visibleSeries.map(\.id)), selection: $selSeries)
        }
    }

    // MARK: Live

    private var visibleLives: [LinkMedia] { mapper.lives.filter { matchesFilter($0.title + " " + ($0.group ?? "")) } }

    private var livesSection: some View {
        Group {
            Section {
                Button {
                    let chosen = mapper.lives.filter { selLives.contains($0.id) }
                    links.add(chosen)
                    message = "\(chosen.count) dirette salvate nel pannello."
                    selLives = []
                } label: {
                    Label("Importa solo le live selezionate (\(selLives.count))", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(selLives.isEmpty)
            } footer: {
                Text("Le dirette non hanno una scheda nel catalogo: restano nell'elenco del pannello, da cui le avvii.")
            }
            Section {
                ForEach(visibleLives.prefix(400)) { m in
                    HStack(spacing: 10) {
                        checkButton(selLives.contains(m.id)) { toggle(&selLives, m.id) }
                        savedRow(m)
                    }
                }
            } header: {
                selectionHeader("Dirette", ids: Set(visibleLives.map(\.id)), selection: $selLives)
            }
        }
    }

    // MARK: Righe

    private func proposalRow(selected: Bool, toggle: @escaping () -> Void, sourceTitle: String, sourceDetail: String?,
                             match: MediaItem?, pending: Bool, preview: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            checkButton(selected, action: toggle)
            ImageTile(url: match?.bestPosterImage, width: 40, height: 60, corner: 6)
                .overlay {
                    if match == nil {
                        Image(systemName: pending ? "hourglass" : "questionmark").foregroundStyle(.secondary)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                if let match {
                    Text(match.title + (match.year.map { " (\($0))" } ?? ""))
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                } else {
                    Text(pending ? "Ricerca nel catalogo…" : "Non trovato nel catalogo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(pending ? Color.secondary : Color.orange)
                }
                Text("dal link: \(sourceTitle)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let sourceDetail { Text(sourceDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let preview {
                Button(action: preview) { Image(systemName: "play.fill").frame(width: 32, height: 32) }
                    .buttonStyle(GlassButtonStyle(tint: app.accent, shape: AnyShape(Circle())))
                    .foregroundStyle(.white)
            }
        }
    }

    private func savedRow(_ m: LinkMedia) -> some View {
        HStack(spacing: 12) {
            ImageTile(url: m.poster, width: 56, height: 36, corner: 6)
                .overlay { if m.poster == nil { Image(systemName: m.isLive ? "dot.radiowaves.left.and.right" : "film").foregroundStyle(.secondary) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([m.group, m.isLive ? "in diretta" : "on demand"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { Playback.playLink(m, app: app, library: library) } label: {
                Image(systemName: "play.fill").frame(width: 32, height: 32)
            }
            .buttonStyle(GlassButtonStyle(tint: app.accent, shape: AnyShape(Circle())))
            .foregroundStyle(.white)
        }
    }

    private func checkButton(_ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(on ? app.accent : .secondary)
        }
        .buttonStyle(.borderless)
    }

    private func selectionHeader(_ title: String, ids: Set<String>, selection: Binding<Set<String>>) -> some View {
        let all = !ids.isEmpty && ids.isSubset(of: selection.wrappedValue)
        return HStack {
            Text("\(title) (\(ids.count))")
            Spacer()
            Button(all ? "Nessuno" : "Tutti") {
                if all { selection.wrappedValue.subtract(ids) } else { selection.wrappedValue.formUnion(ids) }
            }
            .font(.caption.bold())
            .textCase(nil)
        }
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func matchesFilter(_ text: String) -> Bool {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || text.lowercased().contains(q)
    }

    // MARK: Azioni

    private func importAll() {
        let movies = mapper.movies.filter { selMovies.contains($0.id) }
        let series = mapper.series.filter { selSeries.contains($0.id) }
        links.applyMapping(movies: movies, series: series, lives: [])
        let mFound = movies.filter { $0.match != nil }.count
        let sFound = series.filter { $0.match != nil }.count
        let eps = series.filter { $0.match != nil }.reduce(0) { $0 + $1.episodes.count }
        message = "Importati \(mFound) film e \(sFound) serie (\(eps) episodi) nel catalogo. "
            + "I non trovati (\(movies.count - mFound + series.count - sFound)) sono nell'elenco del pannello."
        selMovies.subtract(movies.map(\.id))
        selSeries.subtract(series.map(\.id))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func analyze() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        analyzing = true
        message = nil
        providerBase = nil
        mapper.reset()
        selMovies = []; selSeries = []; selLives = []
        Task {
            let result = await LinkResolver.resolve(text)
            analyzing = false
            switch result {
            case .media(let list):
                Task {
                    await mapper.prepare(list, tmdb: tmdb)
                    // Pre-selezione: film e serie trovati nel catalogo.
                    selMovies = Set(mapper.movies.filter { $0.match != nil }.map(\.id))
                    selSeries = Set(mapper.series.filter { $0.match != nil }.map(\.id))
                }
                tab = 0
            case .provider(let base, let titles):
                providerBase = base
                providerTitles = titles
            case .nothing(let why):
                message = why
            }
        }
    }
}
