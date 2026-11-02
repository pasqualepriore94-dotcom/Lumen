import SwiftUI

/// Elenco delle playlist M3U caricate: sfoglia, rinomina, aggiorna, rianalizza o elimina.
struct PlaylistsView: View {
    @Environment(AppState.self) private var app
    @State private var store = PlaylistStore.shared
    /// Rianalizza la playlist nella schermata di importazione.
    var onAnalyze: (SavedPlaylist, [LinkMedia]) -> Void

    @State private var renaming: SavedPlaylist?
    @State private var newName = ""
    @State private var deleting: SavedPlaylist?
    @State private var refreshing: UUID?
    @State private var message: String?

    var body: some View {
        List {
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if store.playlists.isEmpty {
                ContentUnavailableView("Nessuna playlist", systemImage: "music.note.list",
                                       description: Text("Carica un file .m3u o analizza il link di una playlist."))
            }
            ForEach(store.playlists) { p in
                NavigationLink {
                    PlaylistDetailView(playlist: p, onAnalyze: onAnalyze)
                } label: {
                    row(p)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = p } label: { Label("Elimina", systemImage: "trash") }
                    Button { newName = p.name; renaming = p } label: { Label("Rinomina", systemImage: "pencil") }
                        .tint(.gray)
                }
                .contextMenu { menu(p) }
            }
        }
        .navigationTitle("Playlist M3U")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rinomina playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Salva") { if let p = renaming { store.rename(p, to: newName) }; renaming = nil }
            Button("Annulla", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Eliminare \"\(deleting?.name ?? "")\"?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Elimina playlist e contenuti importati", role: .destructive) {
                if let p = deleting { store.delete(p, withContent: true) }
                deleting = nil
            }
            Button("Elimina solo la playlist", role: .destructive) {
                if let p = deleting { store.delete(p, withContent: false) }
                deleting = nil
            }
            Button("Annulla", role: .cancel) { deleting = nil }
        } message: {
            Text("Puoi tenere nel catalogo i film e le serie già importati da questa playlist, oppure rimuoverli.")
        }
    }

    private func row(_ p: SavedPlaylist) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.isFromFile ? "doc.text.fill" : "link")
                .font(.title3).foregroundStyle(app.accent)
                .frame(width: 40, height: 40)
                .liquidGlassCard(radius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(p.entries) voci · \(p.vods) on demand · \(p.lives) dirette")
                    .font(.caption2).foregroundStyle(.secondary)
                Text((p.isFromFile ? "File" : (URL(string: p.origin)?.host ?? p.origin)) + " · "
                     + p.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if refreshing == p.id { ProgressView() }
        }
    }

    @ViewBuilder
    private func menu(_ p: SavedPlaylist) -> some View {
        Button { onAnalyze(p, store.media(of: p)) } label: { Label("Analizza e importa", systemImage: "wand.and.stars") }
        if !p.isFromFile {
            Button { refresh(p) } label: { Label("Aggiorna dal link", systemImage: "arrow.clockwise") }
        }
        Button { newName = p.name; renaming = p } label: { Label("Rinomina", systemImage: "pencil") }
        Button(role: .destructive) { deleting = p } label: { Label("Elimina", systemImage: "trash") }
    }

    private func refresh(_ p: SavedPlaylist) {
        refreshing = p.id
        Task {
            let result = await store.refresh(p)
            refreshing = nil
            message = result.map { "\"\($0.0.name)\" aggiornata: \($0.0.entries) voci." } ?? "Impossibile aggiornare \"\(p.name)\" dal link."
        }
    }
}

/// Contenuto di una playlist: voci divise in on demand e dirette, con ricerca e riproduzione.
struct PlaylistDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    let playlist: SavedPlaylist
    var onAnalyze: (SavedPlaylist, [LinkMedia]) -> Void

    @State private var media: [LinkMedia] = []
    @State private var filter = ""
    @State private var showLive = false
    @State private var links = LinkLibrary.shared

    private var visible: [LinkMedia] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return media.filter { $0.isLive == showLive && (q.isEmpty || ($0.title + " " + ($0.group ?? "")).lowercased().contains(q)) }
    }

    /// Voci raggruppate per categoria (group-title).
    private var groups: [(String, [LinkMedia])] {
        var order: [String] = []
        var map: [String: [LinkMedia]] = [:]
        for m in visible {
            let g = m.group ?? "Senza categoria"
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(m)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    onAnalyze(playlist, media)
                } label: {
                    Label("Analizza e importa nel catalogo", systemImage: "wand.and.stars").font(.body.weight(.semibold))
                }
                let imported = links.importedCount(Set(media.map(\.id)))
                LabeledContent("Già importati", value: "\(imported)")
                Picker("Tipo", selection: $showLive) {
                    Text("On demand (\(media.filter { !$0.isLive }.count))").tag(false)
                    Text("Dirette (\(media.filter(\.isLive).count))").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("Cerca nella playlist", text: $filter).textInputAutocapitalization(.never)
            }
            ForEach(groups.prefix(60), id: \.0) { group, items in
                Section("\(group) (\(items.count))") {
                    ForEach(items.prefix(300)) { m in
                        HStack(spacing: 12) {
                            ImageTile(url: m.poster, width: 44, height: 44, corner: 6)
                                .overlay { if m.poster == nil { Image(systemName: m.isLive ? "dot.radiowaves.left.and.right" : "film").foregroundStyle(.secondary) } }
                            Text(m.title).font(.subheadline).lineLimit(2)
                            Spacer()
                            Button { Playback.playLink(m, app: app, library: library) } label: {
                                Image(systemName: "play.fill").frame(width: 30, height: 30)
                            }
                            .buttonStyle(GlassButtonStyle(tint: app.accent, shape: AnyShape(Circle())))
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { media = PlaylistStore.shared.media(of: playlist) }
    }
}
