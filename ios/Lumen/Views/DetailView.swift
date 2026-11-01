import SwiftUI

struct DetailView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem
    @State private var detail: MediaDetail?
    @State private var errorMessage: String?
    @State private var seasonIndex = 0

    private var current: MediaItem { detail?.item ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                backdrop
                VStack(alignment: .leading, spacing: 14) {
                    Text(current.title).font(.system(size: 26, weight: .bold))
                    metaRow
                    PrimaryButton(title: resumeTitle) {
                        Task { await Playback.play(item: current, app: app, library: library) }
                    }
                    if let p = library.resumeEntry(for: current.id) {
                        progressInfo(p)
                    }
                    if let overview = current.overview {
                        Text(overview).font(.subheadline).foregroundStyle(.white.opacity(0.9))
                    }
                    if let cast = detail?.cast, !cast.isEmpty {
                        Text("Cast: ").foregroundColor(Theme.secondaryText) + Text(cast.joined(separator: ", "))
                    }
                    actions
                    if let detail, !detail.seasons.isEmpty {
                        episodes(detail)
                    } else if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
                .font(.footnote)
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color(white: 0.08).ignoresSafeArea())
        .foregroundStyle(.white)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.6), in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(12)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(.black)
        .preferredColorScheme(.dark)
        .playbackHUD()
        .task(id: app.contentKey) { await load() }
    }

    private var backdrop: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(RemoteImage(url: current.bestWideImage))
            .overlay(LinearGradient(colors: [.clear, Color(white: 0.08)], startPoint: .center, endPoint: .bottom))
            .overlay {
                Button {
                    Task { await Playback.play(item: current, app: app, library: library) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24))
                        .frame(width: 58, height: 58)
                        .background(.black.opacity(0.5), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            .clipped()
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            if let year = current.year { Text(String(year)) }
            if let rating = current.rating {
                Text(rating)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 3))
            }
            if let seasons = detail?.seasons, current.isSeries, !seasons.isEmpty {
                Text(seasons.count == 1 ? "1 stagione" : "\(seasons.count) stagioni")
            } else if let d = detail?.duration, d > 0 {
                Text(formatDuration(d))
            }
            Text("HD")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.6)))
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.secondaryText)
    }

    private var resumeTitle: String {
        guard let p = library.resumeEntry(for: current.id) else { return "Riproduci" }
        if let label = p.episodeLabel, let code = label.components(separatedBy: " ").first {
            return "Riprendi \(code)"
        }
        return "Riprendi"
    }

    private func progressInfo(_ p: WatchProgress) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: p.fraction).tint(app.accent)
            Text("\(formatTime(max(0, p.duration - p.position))) rimanenti")
                .font(.caption).foregroundStyle(Theme.secondaryText)
        }
    }

    private var actions: some View {
        HStack(spacing: 40) {
            actionButton(library.contains(current) ? "checkmark" : "plus", "La mia lista") {
                withAnimation { library.toggle(current) }
            }
            ShareLink(item: current.title, message: Text(current.overview ?? "")) {
                actionLabel("paperplane", "Condividi")
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 12)
    }

    private func actionButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon, title) }.buttonStyle(.plain)
    }

    private func actionLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 22))
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
        .foregroundStyle(.white)
    }

    // MARK: Episodi

    @ViewBuilder
    private func episodes(_ detail: MediaDetail) -> some View {
        let seasons = detail.seasons
        let index = min(seasonIndex, seasons.count - 1)
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(app.accent).frame(width: 70, height: 3)
            Text("Episodi").font(.headline)
            if seasons.count > 1 {
                Menu {
                    ForEach(Array(seasons.enumerated()), id: \.element.id) { i, s in
                        Button(s.displayTitle) { seasonIndex = i }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(seasons[index].displayTitle)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                }
            }
            ForEach(seasons[index].episodes) { episode in
                EpisodeRow(episode: episode, fallbackImage: current.bestWideImage) {
                    Task {
                        await Playback.play(item: current, episode: episode,
                                            episodeLabel: detail.label(for: episode), app: app, library: library)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func load() async {
        do {
            detail = try await app.provider.detail(id: item.id)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(1, m)) min"
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let fallbackImage: URL?
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ImageTile(url: episode.still ?? fallbackImage, width: 130, height: 74, corner: 4)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                                .frame(width: 32, height: 32)
                                .background(.black.opacity(0.5), in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 1))
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(episode.number). \(episode.title)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if let d = episode.durationLabel {
                            Text(d).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if let overview = episode.overview {
                Text(overview).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
            }
        }
    }
}
