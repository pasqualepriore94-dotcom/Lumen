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

            if !found.isEmpty {
                Section {
                    ForEach(found) { m in mediaRow(m, saved: links.contains(m)) }
                    if found.count > 1 {
                        Button {
                            links.add(found)
                            message = "\(found.count) contenuti aggiunti a \"I miei link\"."
                        } label: {
                            Label("Aggiungi tutti a I miei link", systemImage: "tray.and.arrow.down.fill")
                        }
                    }
                } header: {
                    Text("Contenuti trovati (\(found.count))")
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

    private func mediaRow(_ m: LinkMedia, saved: Bool) -> some View {
        HStack(spacing: 12) {
            ImageTile(url: m.poster, width: 64, height: 40, corner: 6)
                .overlay { if m.poster == nil { Image(systemName: m.isLive ? "dot.radiowaves.left.and.right" : "film").foregroundStyle(.secondary) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(m.source + (m.isLive ? " · in diretta" : "")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
