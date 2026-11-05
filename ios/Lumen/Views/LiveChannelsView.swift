import SwiftUI
import UIKit

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
                    ChannelLogo(url: logo) { initials }
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
            if let now = EPGStore.shared.now(for: channel) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(now.title).font(.system(size: 10)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    ProgressView(value: now.progress).tint(app.accent).scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
                .frame(width: width, alignment: .leading)
            }
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
    @State private var epg = EPGStore.shared
    @State private var showEPGSettings = false
    @State private var guideChannel: LinkMedia?

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
                                Button("Guida del canale", systemImage: "list.bullet.rectangle") { guideChannel = m }
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showEPGSettings = true } label: {
                        if epg.isUpdating { ProgressView() } else { Label("Guida TV", systemImage: "calendar.day.timeline.left") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } }
            }
            .sheet(isPresented: $showEPGSettings) { EPGSettingsView() }
            .sheet(item: $guideChannel) { ChannelGuideView(channel: $0) }
        }
        .preferredColorScheme(.dark)
        .task { await epg.refreshIfNeeded(channels: links.lives) }
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


/// Programmi di un canale (guida TV).
struct ChannelGuideView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let channel: LinkMedia

    var body: some View {
        NavigationStack {
            List {
                let list = EPGStore.shared.upcoming(for: channel)
                if list.isEmpty {
                    ContentUnavailableView("Guida non disponibile", systemImage: "calendar.badge.exclamationmark",
                                           description: Text("Per questo canale non ci sono programmi nella guida TV."))
                }
                ForEach(list, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(p.start.formatted(date: .omitted, time: .shortened) + " – " + p.stop.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit()).foregroundStyle(p.isNow ? app.accent : .secondary)
                            if p.isNow {
                                Text("IN ONDA").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2).background(.red, in: Capsule())
                            }
                            Spacer()
                            if !Calendar.current.isDateInToday(p.start) {
                                Text(p.start.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "it_IT"))))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(p.title).font(.subheadline.weight(p.isNow ? .bold : .semibold))
                        if let d = p.desc { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        if p.isNow { ProgressView(value: p.progress).tint(app.accent) }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(channel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Guarda", systemImage: "play.fill") {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            Playback.playLink(channel, app: app, library: library)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

/// Impostazioni della guida TV: indirizzo XMLTV (trovato nella playlist o inserito a mano) e aggiornamento.
struct EPGSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var epg = EPGStore.shared
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/guide.xml.gz", text: $draft)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        epg.url = draft.trimmingCharacters(in: .whitespaces)
                        Task { await epg.refresh(channels: LinkLibrary.shared.lives) }
                    } label: {
                        HStack {
                            Label("Salva e aggiorna la guida", systemImage: "arrow.clockwise")
                            Spacer()
                            if epg.isUpdating { ProgressView() }
                        }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || epg.isUpdating)
                } header: {
                    Text("Indirizzo della guida (XMLTV)")
                } footer: {
                    Text("Se la playlist indica una guida (url-tvg) viene inserita in automatico. I canali vengono abbinati per tvg-id o per nome. La guida si aggiorna da sola ogni 12 ore.")
                }
                Section("Stato") {
                    if let status = epg.status { Text(status).font(.footnote) }
                    if let last = epg.lastUpdate {
                        LabeledContent("Ultimo aggiornamento", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Canali con guida", value: "\(epg.programs.values.filter { !$0.isEmpty }.count)")
                }
            }
            .navigationTitle("Guida TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .onAppear { draft = epg.url }
        }
        .preferredColorScheme(.dark)
    }
}

/// Logo del canale (dalla memoria se già scaricato), con le iniziali finché non c'è.
struct ChannelLogo<Fallback: View>: View {
    let url: URL
    @ViewBuilder var fallback: () -> Fallback
    @State private var image: UIImage?

    var body: some View {
        if let img = image ?? ImagePipeline.shared.cached(url, maxPixel: 300) {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            fallback()
                .task(id: url) { image = await ImagePipeline.shared.image(url, maxPixel: 300) }
        }
    }
}
