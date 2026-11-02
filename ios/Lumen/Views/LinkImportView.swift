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
                Section {
                    if found.count > 8 {
                        TextField("Filtra per nome o categoria", text: $filterText)
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("Abbina i VOD al catalogo (Riproduci nella scheda)", isOn: $matchCatalog)
                        .font(.footnote)
                    Button {
                        let chosen = found.filter { selected.contains($0.id) }
                        Task {
                            let tmdb = app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }
                            await links.importAndMatch(chosen, tmdb: matchCatalog ? tmdb : nil)
                            let vodCount = chosen.filter { !$0.isLive }.count
                            let liveCount = chosen.count - vodCount
                            var parts: [String] = []
                            if vodCount > 0 { parts.append("\(links.matchFound) VOD su \(vodCount) abbinati al catalogo") }
                            if liveCount > 0 { parts.append("\(liveCount) dirette salvate nel pannello") }
                            message = parts.joined(separator: " · ") + "."
                        }
                    } label: {
                        Label("Importa selezionati (\(selected.count))", systemImage: "tray.and.arrow.down.fill")
                    }
                    .disabled(selected.isEmpty || links.isMatching)
                } header: {
                    Text("Trovati \(found.count): \(vods.count) VOD · \(lives.count) live")
                } footer: {
                    Text("L'app divide da sola i contenuti on demand (film ed episodi) dalle dirette. I VOD vengono cercati per nome nel catalogo: se il titolo esiste, nella sua scheda compare \"Riproduci\".")
                }

                if !vods.isEmpty { group(title: "VOD · film ed episodi", icon: "film.stack", items: vods) }
                if !lives.isEmpty { group(title: "Live · dirette", icon: "dot.radiowaves.left.and.right", items: lives) }
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




