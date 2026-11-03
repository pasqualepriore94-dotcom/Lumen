import SwiftUI

/// Gestione dei contenuti caricati tramite link: film e serie abbinati al catalogo, dirette e non abbinati.
struct LinkedContentView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @State private var links = LinkLibrary.shared
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmAll = false
    @State private var confirmSelected = false

    private func filtered(_ items: [MediaItem]) -> [MediaItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.title.lowercased().contains(q) }
    }

    private var others: [LinkMedia] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? links.items : links.items.filter { $0.title.lowercased().contains(q) }
    }

    private var total: Int { links.matchedMovies.count + links.matchedSeries.count + links.items.count }

    var body: some View {
        List(selection: $selection) {
            if total == 0 {
                Section {
                    Text("Nessun contenuto caricato da link.").foregroundStyle(.secondary)
                }
            }

            let movies = filtered(links.matchedMovies)
            if !movies.isEmpty {
                Section {
                    ForEach(movies) { item in
                        row(item, detail: "Riproduci attivo nella scheda")
                            .tag("m:" + item.id)
                            .swipeActions { removeButton { links.removeMatch(itemId: item.id) } }
                    }
                } header: {
                    sectionHeader("Film nel catalogo", tags: Set(movies.map { "m:" + $0.id }))
                }
            }

            let series = filtered(links.matchedSeries)
            if !series.isEmpty {
                Section {
                    ForEach(series) { item in
                        row(item, detail: "\(links.episodeCount(seriesId: item.id)) episodi collegati")
                            .tag("s:" + item.id)
                            .swipeActions { removeButton { links.removeMatch(itemId: item.id) } }
                    }
                } header: {
                    sectionHeader("Serie nel catalogo", tags: Set(series.map { "s:" + $0.id }))
                }
            }

            if !others.isEmpty {
                Section {
                    ForEach(others.prefix(500)) { m in
                        HStack(spacing: 12) {
                            ImageTile(url: m.poster, width: 40, height: 40, corner: 6)
                                .overlay { if m.poster == nil { Image(systemName: m.isLive ? "dot.radiowaves.left.and.right" : "film").foregroundStyle(.secondary) } }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(m.isLive ? "Diretta" : "Non abbinato al catalogo").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .tag("l:" + m.id)
                        .swipeActions { removeButton { links.remove(m) } }
                    }
                } header: {
                    sectionHeader("Dirette e non abbinati", tags: Set(others.map { "l:" + $0.id }))
                } footer: {
                    if others.count > 500 {
                        Text("Mostrati i primi 500 di \(others.count). \"Tutti\" seleziona anche quelli non mostrati.")
                    }
                }
            }

            if total > 0 {
                Section {
                    Button("Rimuovi tutti i contenuti da link", role: .destructive) { confirmAll = true }
                } footer: {
                    Text("Togli solo i collegamenti ai video: le schede del catalogo restano, ma senza Riproduci. I file già scaricati restano in Download.")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .searchable(text: $search, prompt: "Cerca tra i contenuti")
        .navigationTitle("Contenuti da link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Fine" : "Seleziona") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                        selection = []
                    }
                }
                .disabled(total == 0)
            }
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    let all = allTags
                    Button(!all.isEmpty && all.isSubset(of: selection) ? "Deseleziona" : "Seleziona tutti") {
                        withAnimation {
                            if !all.isEmpty && all.isSubset(of: selection) { selection = [] } else { selection = all }
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Rimuovi selezionati (\(selection.count))", role: .destructive) { confirmSelected = true }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .sheet(item: $shown) { DetailView(item: $0) }
        .confirmationDialog("Rimuovere tutti i contenuti caricati da link?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Rimuovi tutto", role: .destructive) { withAnimation { links.removeAll() } }
        }
        .confirmationDialog("Rimuovere \(selection.count) contenuti?", isPresented: $confirmSelected, titleVisibility: .visible) {
            Button("Rimuovi", role: .destructive) { removeSelected() }
        }
    }

    private func row(_ item: MediaItem, detail: String) -> some View {
        HStack(spacing: 12) {
            ImageTile(url: item.bestPosterImage, width: 40, height: 60, corner: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title + (item.year.map { " (\($0))" } ?? "")).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !editMode.isEditing {
                Button { openDetail(item) } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Tutti i contenuti visibili con la ricerca attuale (anche oltre i primi 500 dell'elenco).
    private var allTags: Set<String> {
        Set(filtered(links.matchedMovies).map { "m:" + $0.id })
            .union(filtered(links.matchedSeries).map { "s:" + $0.id })
            .union(others.map { "l:" + $0.id })
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, tags: Set<String>) -> some View {
        HStack {
            Text("\(title) (\(tags.count))")
            Spacer()
            if editMode.isEditing {
                let all = !tags.isEmpty && tags.isSubset(of: selection)
                Button(all ? "Nessuno" : "Tutti") {
                    withAnimation { if all { selection.subtract(tags) } else { selection.formUnion(tags) } }
                }
                .font(.caption.bold())
                .textCase(nil)
            }
        }
    }

    @State private var shown: MediaItem?
    private func openDetail(_ item: MediaItem) { shown = item }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive) { withAnimation { action() } } label: {
            Label("Rimuovi", systemImage: "trash")
        }
    }

    private func removeSelected() {
        var matchIds: [String] = []
        var linkIds = Set<String>()
        for tag in selection {
            if tag.hasPrefix("m:") || tag.hasPrefix("s:") {
                matchIds.append(String(tag.dropFirst(2)))
            } else if tag.hasPrefix("l:") {
                linkIds.insert(String(tag.dropFirst(2)))
            }
        }
        // Rimozione in blocco (un solo salvataggio anche con migliaia di voci).
        links.removeLinks(linkIds)
        links.removeMatches(matchIds)
        selection = []
        withAnimation { editMode = .inactive }
    }
}
