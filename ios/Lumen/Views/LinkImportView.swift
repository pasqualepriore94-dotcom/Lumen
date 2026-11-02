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
                    HStack {
                        Button(selected.count == visibleFound.count ? "Deseleziona tutti" : "Seleziona tutti") {
                            if selected.count == visibleFound.count { selected = [] }
                            else { selected = Set(visibleFound.map(\.id)) }
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Text("\(selected.count) selezionati").font(.footnote).foregroundStyle(.secondary)
                    }
                    if found.count > 8 {
                        TextField("Filtra per nome o categoria", text: $filterText)
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("Abbina al catalogo TMDB (Riproduci nella scheda)", isOn: $matchCatalog)
                        .font(.footnote)
                    Button {
                        let chosen = found.filter { selected.contains($0.id) }
                        Task {
                            let tmdb = app.config.providers.first { $0.type == .tmdb && $0.isUsable }.map { TMDBProvider(config: $0) }
                            await links.importAndMatch(chosen, tmdb: matchCatalog ? tmdb : nil)
                            message = matchCatalog
                                ? "\(chosen.count) aggiunti · \(links.matchFound) abbinati al catalogo."
                                : "\(chosen.count) contenuti aggiunti a \"I miei link\"."
                        }
                    } label: {
                        Label("Aggiungi selezionati (\(selected.count))", systemImage: "tray.and.arrow.down.fill")
                    }
                    .disabled(selected.isEmpty || links.isMatching)
                    ForEach(visibleFound) { m in
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
                } header: {
                    Text("Contenuti trovati (\(found.count))")
                } footer: {
                    Text("I contenuti on demand (film ed episodi) vengono cercati per nome nel catalogo: se il titolo esiste, nella sua scheda compare \"Riproduci\". Le dirette restano in \"I miei link\".")
                }
            }

            if !links.items.isEmpty {
                Section {
                    ForEach(links.items) { m in mediaRow(m, saved: true) }
                        .onDelete { idx in idx.map { links.items[$0] }.forEach(links.remove) }
                } header: {
                    Text("I miei link (\(links.items.count))")
                } footer: {
                    Text("Compaiono anche in Home nella riga \"I miei link\". Scorri a sinistra per eliminarli.")
                }
            }
        }
        .navigationTitle("Aggiungi da link")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if input.isEmpty, let s = UIPasteboard.general.string, s.lowercased().hasPrefix("http") { input = s }
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
                selected = Set(list.map(\.id))
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

/// Riga "I miei link" in Home.
struct MyLinksRow: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @State private var links = LinkLibrary.shared

    var body: some View {
        if !links.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "I miei link")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(links.items) { m in
                            Button { Playback.playLink(m, app: app, library: library) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack {
                                        ImageTile(url: m.poster, width: 200, height: 112, corner: 14)
                                        Image(systemName: "play.fill").font(.system(size: 16))
                                            .frame(width: 40, height: 40)
                                            .liquidGlass(in: Circle())
                                    }
                                    Text(m.title).font(.footnote.weight(.semibold)).lineLimit(1).frame(width: 200, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rimuovi", systemImage: "trash", role: .destructive) { links.remove(m) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

/// Riga "Pronti da guardare": titoli del catalogo per cui esiste un video da link.
struct ReadyToWatchRow: View {
    @State private var links = LinkLibrary.shared

    var body: some View {
        let items = Array(links.matchedItems.values).sorted { $0.title < $1.title }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Pronti da guardare")
                PosterRow(items: items, layout: .poster)
            }
        }
    }
}
