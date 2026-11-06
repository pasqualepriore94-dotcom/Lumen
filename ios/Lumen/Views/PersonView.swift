import SwiftUI

/// Pagina di un attore: foto, biografia, dati e tutti i suoi film e serie.
struct PersonView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var close
    let member: CastMember

    @State private var person: PersonDetail?
    @State private var errorMessage: String?
    @State private var bioExpanded = false
    @State private var translatedBio: String?
    @State private var selected: MediaItem?
    @State private var showAllMovies = false

    private var links: LinkLibrary { LinkLibrary.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let person {
                    facts(person)
                    biography(person)
                    let available = (person.movies + person.series).filter(isAvailable)
                    if !available.isEmpty { row("Da guardare in Lumen", items: available, badge: "play.fill") }
                    if !person.knownFor.isEmpty { row("Conosciuto per", items: person.knownFor) }
                    if !person.movies.isEmpty { row("Film (\(person.movies.count))", items: person.movies, showAll: true) }
                    if !person.series.isEmpty { row("Serie TV (\(person.series.count))", items: person.series) }
                    if !person.directed.isEmpty { row("Come regista", items: person.directed) }
                } else if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Theme.secondaryText).padding(.horizontal, 18)
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack {
                Color.black
                RemoteImage(url: person?.photo ?? member.photo, maxPixel: 600).blur(radius: 60).opacity(0.4)
                LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topTrailing) {
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.6))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18).padding(.trailing, 16)
        }
        .sheet(item: $selected) { DetailView(item: $0) }
        .sheet(isPresented: $showAllMovies) {
            if let person {
                SectionGridView(section: CatalogSection(id: "person-\(person.id)", title: "Film con \(person.name)",
                                                        style: nil, items: person.movies))
            }
        }
        .task { await load() }
        .preferredColorScheme(.dark)
    }

    // MARK: Parti

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ImageTile(url: person?.photo ?? member.photo, width: 120, height: 170, corner: 14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.2), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(person?.name ?? member.name).font(.system(size: 28, weight: .heavy)).lineLimit(3)
                    .minimumScaleFactor(0.7)
                if let character = member.character {
                    Text("Qui è \(character)").font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
                if let dept = person?.department {
                    Text(Self.department(dept)).font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.14), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 70)
    }

    @ViewBuilder
    private func facts(_ p: PersonDetail) -> some View {
        let raw: [(String, String)?] = [
            p.birthday.map { b in
                let age = Calendar.current.dateComponents([.year], from: b, to: p.deathday ?? Date()).year ?? 0
                return ("Nascita", Self.date(b) + (p.deathday == nil ? " (\(age) anni)" : ""))
            },
            p.deathday.map { d in
                let age = p.birthday.flatMap { Calendar.current.dateComponents([.year], from: $0, to: d).year }
                return ("Morte", Self.date(d) + (age.map { " (\($0) anni)" } ?? ""))
            },
            p.placeOfBirth.map { ("Luogo di nascita", $0) },
            ("Titoli", "\(p.movies.count) film · \(p.series.count) serie")
        ]
        let lines = raw.compactMap { $0 }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines.indices, id: \.self) { i in
                let line = lines[i]
                HStack(alignment: .top) {
                    Text(line.0).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 120, alignment: .leading)
                    Text(line.1).font(.subheadline)
                }
            }
            HStack(spacing: 10) {
                if let imdb = p.imdbId, let url = URL(string: "https://www.imdb.com/name/\(imdb)") {
                    Link(destination: url) { linkChip("IMDb", icon: "star.fill") }
                }
                if let ig = p.instagram, let url = URL(string: "https://instagram.com/\(ig)") {
                    Link(destination: url) { linkChip("Instagram", icon: "camera") }
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 18)
    }

    private func linkChip(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.bold))
            .padding(.horizontal, 12).frame(height: 30)
            .background(.white.opacity(0.14), in: Capsule())
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private func biography(_ p: PersonDetail) -> some View {
        if let bio = translatedBio ?? p.biography {
            VStack(alignment: .leading, spacing: 6) {
                Text("Biografia").font(.headline)
                if p.biographyIsEnglish {
                    Label(translatedBio != nil ? "Tradotta con Apple Intelligence" : "Disponibile solo in inglese",
                          systemImage: translatedBio != nil ? "sparkles" : "globe")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                }
                Text(bio).font(.subheadline).foregroundStyle(.white.opacity(0.88))
                    .lineLimit(bioExpanded ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                if bio.count > 320 {
                    Button(bioExpanded ? "Mostra meno" : "Leggi tutto") { withAnimation { bioExpanded.toggle() } }
                        .font(.caption.weight(.bold)).foregroundStyle(app.accent)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func row(_ title: String, items: [MediaItem], badge: String? = nil, showAll: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let badge { Image(systemName: badge).font(.caption.weight(.bold)).foregroundStyle(.green) }
                Text(title).font(.headline)
                Spacer()
                if showAll && items.count > 12 {
                    Button("Mostra tutto") { showAllMovies = true }
                        .font(.caption.weight(.bold)).foregroundStyle(app.accent)
                }
            }
            .padding(.horizontal, 18)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(items.prefix(40)) { item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                PosterCard(item: item, width: 108)
                                Text(item.title).font(.caption.weight(.semibold)).lineLimit(2)
                                Text([item.year.map(String.init), item.isSeries ? "Serie" : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(Theme.secondaryText)
                            }
                            .frame(width: 108, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Dati

    private func isAvailable(_ item: MediaItem) -> Bool {
        item.isSeries ? links.episodeCount(seriesId: item.id) > 0 : links.link(forItem: item.id) != nil
    }

    private func load() async {
        guard person == nil else { return }
        guard let id = member.personId else {
            errorMessage = "Informazioni sull'attore non disponibili."
            return
        }
        guard let config = app.config.providers.first(where: { $0.type == .tmdb && $0.isUsable }) else {
            errorMessage = "Serve il catalogo TMDB per vedere i dettagli dell'attore."
            return
        }
        do {
            let p = try await TMDBProvider(config: config).person(id: id)
            withAnimation { person = p }
            ImagePipeline.shared.prefetch(p.knownFor.compactMap(\.bestPosterImage))
            if p.biographyIsEnglish, let bio = p.biography {
                translatedBio = PlotWriter.cachedTranslation("person-\(id)")
                if translatedBio == nil, let t = await PlotWriter.translate(id: "person-\(id)", text: String(bio.prefix(2500))) {
                    withAnimation { translatedBio = t }
                }
            }
        } catch {
            errorMessage = "Non riesco a caricare le informazioni. Riprova più tardi."
        }
    }

    private static func date(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "it_IT")))
    }

    private static func department(_ d: String) -> String {
        switch d {
        case "Acting": return "Attore / Attrice"
        case "Directing": return "Regia"
        case "Writing": return "Sceneggiatura"
        case "Production": return "Produzione"
        case "Sound": return "Musica"
        default: return d
        }
    }
}
