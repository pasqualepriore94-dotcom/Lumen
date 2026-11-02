import SwiftUI
import UIKit

/// Pannello amministratore → "Aggiungi da link": incolla un link, l'app trova i video e propone il play.
struct LinkImportView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @State private var links = LinkLibrary.shared

    @State private var input = ""
    @State private var analyzing = false
    @State private var found: [LinkMedia] = []
    @State private var providerBase: String?
    @State private var providerTitles = 0
    @State private var message: String?
    @State private var selected = Set<String>()
    @State private var matchCatalog = true
    @State private var filterText = ""
    @State private var tab = 0

    var body: some View {
        List {
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
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    analyze()
                } label: {
                    HStack {
                        Label("Analizza link", systemImage: "wand.and.stars")
                        Spacer()
                        if analyzing { ProgressView() }
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || analyzing)
            } header: {
                Text("Link")
            } footer: {
                Text("Riconosce video MP4/MOV, flussi HLS (.m3u8), playlist M3U, API nel formato Lumen e pagine che pubblicano il video in modo aperto. Usa solo contenuti che hai il diritto di guardare.")
            }

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }

            if let base = providerBase {
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

            if links.isMatching {
                Section("Abbinamento al catalogo") {
                    ProgressView(value: Double(links.matchDone), total: Double(max(1, links.matchTotal)))
                        .tint(app.accent)
                    Text("\(links.matchDone)/\(links.matchTotal) analizzati · \(links.matchFound) abbinati")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Interrompi", role: .destructive) { links.stopMatching() }
                }
            }

            if !found.isEmpty {
                // Riepilogo e scelta separata di cosa importare
                Section {
                    HStack(spacing: 10) {
                        countTile("Film", vodMovies.count, "film")
                        countTile("Episodi", vodEpisodes.count, "tv")
                        countTile("Live", lives.count, "dot.radiowaves.left.and.right")
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))

                    Picker("Mostra", selection: $tab) {
                        Text("VOD (\(vods.count))").tag(0)
                        Text("Live (\(lives.count))").tag(1)
                    }
                    .pickerStyle(.segmented)

                    if found.count > 8 {
                        TextField("Filtra per nome o categoria", text: $filterText)
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Trovati \(found.count) contenuti")
                } footer: {
                    Text("L'app separa da sola i contenuti on demand (film ed episodi di serie) dalle dirette. Puoi importare solo i VOD, solo le live, oppure scegliere voce per voce.")
                }

                if tab == 0 {
                    Section {
                        Toggle("Abbina al catalogo (Riproduci nella scheda)", isOn: $matchCatalog)
                            .font(.footnote)
                        importButton(title: "Importa solo i VOD", items: vods.filter { selected.contains($0.id) },
                                     icon: "film.stack")
                    }
                    if !vodMovies.isEmpty { group(title: "Film", icon: "film", items: vodMovies) }
                    if !vodEpisodes.isEmpty { group(title: "Episodi di serie", icon: "tv", items: vodEpisodes) }
                    if vods.isEmpty {
                        Section { Text("Nessun contenuto on demand in questo link.").foregroundStyle(.secondary) }
                    }
                } else {
                    Section {
                        importButton(title: "Importa solo le live", items: lives.filter { selected.contains($0.id) },
                                     icon: "dot.radiowaves.left.and.right")
                    } footer: {
                        Text("Le dirette non hanno una scheda nel catalogo: restano nell'elenco qui sotto, da cui le avvii.")
                    }
                    if !lives.isEmpty { group(title: "Dirette", icon: "dot.radiowaves.left.and.right", items: lives) }
                    else { Section { Text("Nessuna diretta in questo link.").foregroundStyle(.secondary) } }
                }
            }

            if !links.items.isEmpty {
                Section {
                    ForEach(links.items) { m in mediaRow(m, saved: true) }
                        .onDelete { idx in idx.map { links.items[$0] }.forEach(links.remove) }
                } header: {
                    Text("I miei link (\(links.items.count))")
                } footer: {
                    Text("Dirette e VOD non abbinati al catalogo. Scorri a sinistra per eliminarli.")
                }
            }
        }
        .navigationTitle("Aggiungi da link")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if input.isEmpty, let s = UIPasteboard.general.string, s.lowercased().hasPrefix("http") { input = s }
        }
    }

    private var vods: [LinkMedia] { visibleFound.filter { !$0.isLive } }
    private var vodEpisodes: [LinkMedia] { vods.filter { ParsedTitle.parse($0.title).isEpisode } }
    private var vodMovies: [LinkMedia] { vods.filter { !ParsedTitle.parse($0.title).isEpisode } }

    private func countTile(_ title: String, _ count: Int, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(app.accent)
            Text("\(count)").font(.title3.bold())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .liquidGlassCard(radius: 16)
    }

    private func importButton(title: String, items: [LinkMedia], icon: String) -> some View {
        Button {
            let chosen = items
            Task {
                let tmdb = app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }
                await links.importAndMatch(chosen, tmdb: matchCatalog ? tmdb : nil)
                let vodCount = chosen.filter { !$0.isLive }.count
                let liveCount = chosen.count - vodCount
                var parts: [String] = []
                if vodCount > 0 {
                    parts.append(matchCatalog ? "\(links.matchFound) VOD su \(vodCount) abbinati al catalogo"
                                              : "\(vodCount) VOD salvati nel pannello")
                }
                if liveCount > 0 { parts.append("\(liveCount) dirette salvate nel pannello") }
                message = parts.joined(separator: " · ") + "."
            }
        } label: {
            HStack {
                Label("\(title) (\(items.count))", systemImage: icon).font(.body.weight(.semibold))
                Spacer()
                if links.isMatching { ProgressView() }
            }
        }
        .disabled(items.isEmpty || links.isMatching)
    }
    private var lives: [LinkMedia] { visibleFound.filter(\.isLive) }

    @ViewBuilder
    private func group(title: String, icon: String, items: [LinkMedia]) -> some View {
        let ids = Set(items.map(\.id))
        let allSelected = ids.isSubset(of: selected)
        Section {
            ForEach(items.prefix(300)) { m in
                HStack(spacing: 10) {
                    Button {
                        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
                    } label: {
                        Image(systemName: selected.contains(m.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected.contains(m.id) ? app.accent : .secondary)
                    }
                    .buttonStyle(.borderless)
                    mediaRow(m, saved: links.contains(m))
                }
            }
            if items.count > 300 {
                Text("… e altri \(items.count - 300) (inclusi nella selezione)").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Label("\(title) (\(items.count))", systemImage: icon)
                Spacer()
                Button(allSelected ? "Nessuno" : "Tutti") {
                    if allSelected { selected.subtract(ids) } else { selected.formUnion(ids) }
                }
                .font(.caption.bold())
                .textCase(nil)
            }
        }
    }

    private var visibleFound: [LinkMedia] {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return found }
        return found.filter { $0.title.lowercased().contains(q) || ($0.group?.lowercased().contains(q) ?? false) }
    }

    private func mediaRow(_ m: LinkMedia, saved: Bool) -> some View {
        HStack(spacing: 12) {
            ImageTile(url: m.poster, width: 64, height: 40, corner: 6)
                .overlay { if m.poster == nil { Image(systemName: m.isLive ? "dot.radiowaves.left.and.right" : "film").foregroundStyle(.secondary) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([m.group, m.source, m.isLive ? "in diretta" : "on demand"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                Playback.playLink(m, app: app, library: library)
            } label: {
                Image(systemName: "play.fill").frame(width: 34, height: 34)
            }
            .buttonStyle(GlassButtonStyle(tint: app.accent, shape: AnyShape(Circle())))
            if !saved {
                Button {
                    links.add([m])
                } label: {
                    Image(systemName: "plus").frame(width: 34, height: 34)
                }
                .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
            }
        }
        .foregroundStyle(.white)
    }

    private func analyze() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        analyzing = true
        message = nil
        found = []
        providerBase = nil
        Task {
            let result = await LinkResolver.resolve(text)
            analyzing = false
            switch result {
            case .media(let list):
                found = list
                // Di partenza sono selezionati solo i VOD.
                selected = Set(list.filter { !$0.isLive }.map(\.id))
                if list.count == 1 {
                    message = "Trovato un video: tocca ▶︎ per guardarlo o + per salvarlo."
                }
            case .provider(let base, let titles):
                providerBase = base
                providerTitles = titles
            case .nothing(let why):
                message = why
            }
        }
    }
}




