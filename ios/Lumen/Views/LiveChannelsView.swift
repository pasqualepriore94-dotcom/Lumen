import SwiftUI

extension LinkLibrary {
    /// Dirette importate dalle playlist (categoria "Dirette").
    var lives: [LinkMedia] { items.filter(\.isLive) }
}

/// Riga "Dirette" della home: canali importati, avvio con un tocco.
struct LiveChannelsRow: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    let channels: [LinkMedia]
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Dirette", actionTitle: "Mostra tutto") { showAll = true }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(channels.prefix(40)) { m in
                        Button { Playback.playLink(m, app: app, library: library) } label: { LiveTile(channel: m) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showAll) { LiveChannelsView() }
    }
}

struct LiveTile: View {
    @Environment(AppState.self) private var app
    let channel: LinkMedia
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                LinearGradient(colors: [app.accent.opacity(0.35), Color.white.opacity(0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let logo = channel.poster {
                    // Loghi dei canali: interi, senza ritaglio
                    AsyncImage(url: logo) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFit() }
                        else { initials }
                    }
                    .padding(14)
                } else {
                    initials
                }
            }
            .frame(width: width, height: width * 0.56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.6))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("LIVE").font(.system(size: 8, weight: .heavy))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
            }
            Text(channel.title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }

    private var initials: some View {
        Text(channel.title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(.system(size: 22, weight: .heavy))
            .foregroundStyle(.white.opacity(0.8))
    }
}

/// Categoria "Dirette": tutti i canali, divisi per gruppo della playlist, con ricerca.
struct LiveChannelsView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var links = LinkLibrary.shared
    @State private var search = ""
    @State private var group: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    private var groups: [String] {
        var seen = Set<String>(), out: [String] = []
        for m in links.lives { let g = m.group ?? "Altri canali"; if seen.insert(g).inserted { out.append(g) } }
        return out
    }

    private var visible: [LinkMedia] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return links.lives.filter {
            (group == nil || ($0.group ?? "Altri canali") == group) && (q.isEmpty || $0.title.lowercased().contains(q))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if groups.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                chip("Tutti", selected: group == nil) { group = nil }
                                ForEach(groups, id: \.self) { g in chip(g, selected: group == g) { group = g } }
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.hidden)
                    }
                    if visible.isEmpty {
                        ContentUnavailableView("Nessuna diretta", systemImage: "dot.radiowaves.left.and.right",
                                               description: Text(links.lives.isEmpty
                                                                 ? "Importa le dirette da Amministrazione → Aggiungi da link o file."
                                                                 : "Nessun canale corrisponde alla ricerca."))
                            .padding(.top, 40)
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(visible.prefix(1500)) { m in
                            Button { Playback.playLink(m, app: app, library: library) } label: {
                                LiveTile(channel: m, width: 104)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Guarda", systemImage: "play.fill") { Playback.playLink(m, app: app, library: library) }
                                if auth.isAdmin {
                                    Button("Rimuovi dalle dirette", systemImage: "trash", role: .destructive) {
                                        withAnimation { links.remove(m) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    Text("\(visible.count) canali").font(.footnote).foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity).padding(.bottom, 20)
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca una diretta")
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Dirette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(GlassButtonStyle(tint: selected ? app.accent : nil))
        .foregroundStyle(.white)
    }
}
