import SwiftUI

/// Elenco di video scaricati e schede salvate, consultabili anche senza connessione.
struct DownloadsView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var manager = DownloadManager.shared
    @State private var selected: MediaItem?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    if manager.list.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 48)).foregroundStyle(Theme.secondaryText)
                            Text("Nessun download").font(.headline)
                            Text("Apri un film o una serie e tocca \"Scarica\": i video delle sorgenti video vengono salvati sull'iPhone, mentre per i titoli del catalogo informativo viene salvata la scheda completa (trama, cast, episodi, immagini).")
                                .font(.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(28)
                        .liquidGlassCard(radius: 26)
                    }
                    ForEach(manager.list) { r in row(r) }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(AuroraBackground(accent: app.accent).opacity(0.5))
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
                if !manager.list.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Elimina tutto", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Eliminare tutti i download?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Elimina tutto", role: .destructive) { withAnimation { manager.removeAll() } }
            }
            .sheet(item: $selected) { DetailView(item: $0) }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    private var summary: some View {
        let videos = manager.list.filter { $0.state == .done }.count
        let infos = manager.list.filter(\.infoOnly).count
        return HStack(spacing: 14) {
            Image(systemName: "internaldrive").font(.title2).foregroundStyle(app.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: manager.totalBytes, countStyle: .file))
                    .font(.headline)
                Text("\(videos) video · \(infos) schede salvate").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(16)
        .liquidGlassCard(radius: 22)
    }

    private func row(_ r: DownloadRecord) -> some View {
        HStack(spacing: 12) {
            ImageTile(url: r.item.bestPosterImage, width: 52, height: 78, corner: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let label = r.episodeLabel {
                    Text(label).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                status(r)
            }
            Spacer(minLength: 4)
            actions(r)
        }
        .padding(10)
        .liquidGlassCard(radius: 20)
        .contentShape(Rectangle())
        .onTapGesture { selected = r.item }
    }

    @ViewBuilder
    private func status(_ r: DownloadRecord) -> some View {
        switch r.state {
        case .waiting:
            Label("In attesa…", systemImage: "clock").font(.caption).foregroundStyle(Theme.secondaryText)
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: r.progress).tint(app.accent)
                Text("\(Int(r.progress * 100))% · \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))")
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        case .done:
            Label("Disponibile offline · \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(app.accent)
        case .saved:
            Label("Scheda salvata (senza video)", systemImage: "doc.text.image").font(.caption).foregroundStyle(Theme.secondaryText)
        case .failed:
            Label(r.error ?? "Errore", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    @ViewBuilder
    private func actions(_ r: DownloadRecord) -> some View {
        HStack(spacing: 8) {
            if r.state == .done {
                Button {
                    Task {
                        let episode = r.episodeId.flatMap { manager.savedDetail(r.item.id)?.episode(id: $0) }
                        await Playback.play(item: r.item, episode: episode, episodeLabel: r.episodeLabel,
                                            app: app, library: library)
                    }
                } label: {
                    Image(systemName: "play.fill").frame(width: 38, height: 38)
                }
                .buttonStyle(GlassButtonStyle(tint: app.accent, shape: AnyShape(Circle())))
            }
            Button {
                withAnimation {
                    if r.state == .downloading || r.state == .waiting { manager.cancel(r.id) } else { manager.remove(r.id) }
                }
            } label: {
                Image(systemName: r.state == .downloading ? "xmark" : "trash").font(.footnote.bold()).frame(width: 38, height: 38)
            }
            .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
        }
        .foregroundStyle(.white)
    }
}
