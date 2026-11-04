import SwiftUI

/// "Chiedi a Lumen": descrivi a parole cosa vuoi vedere, Apple Intelligence propone i titoli.
struct AssistantView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var assistant = LumenAssistant()
    @State private var question = ""
    @State private var selected: MediaItem?
    @FocusState private var focused: Bool
    var initialQuestion: String = ""

    private let ideas = [
        "Cosa guardo stasera?",
        "Qualcosa di leggero, meno di due ore",
        "Un thriller con un colpo di scena finale",
        "Una serie da finire in un weekend",
        "Un film da vedere con tutta la famiglia",
        "Il film dell'astronauta rimasto da solo su Marte",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let reason = LumenAssistant.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .liquidGlassCard(radius: 18)
                    }
                    inputField
                    switch assistant.state {
                    case .idle:
                        ideasList
                    case .thinking:
                        HStack(spacing: 10) {
                            ProgressView().tint(app.accent)
                            Text("Sto pensando a cosa proporti…").font(.subheadline).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.top, 10)
                    case .failed(let message):
                        Text(message).font(.subheadline).foregroundStyle(.orange)
                        ideasList
                    case .done:
                        results
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AuroraBackground(accent: app.accent).opacity(0.45).ignoresSafeArea())
            .navigationTitle("Chiedi a Lumen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } } }
            .sheet(item: $selected) { DetailView(item: $0) }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !initialQuestion.isEmpty, question.isEmpty {
                question = initialQuestion
                send()
            } else {
                focused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(app.accent)
                .frame(width: 48, height: 48)
                .liquidGlass(in: Circle(), tint: app.accent.opacity(0.35))
            VStack(alignment: .leading, spacing: 2) {
                Text("Descrivi cosa ti va di vedere").font(.headline)
                Text("Apple Intelligence, sul tuo iPhone: le richieste non lasciano il telefono.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var inputField: some View {
        HStack(spacing: 8) {
            TextField("", text: $question, prompt: Text("Es. una commedia anni '90 da ridere").foregroundColor(Theme.secondaryText),
                      axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36)
            }
            .buttonStyle(GlassButtonStyle(tint: app.accent, shape: AnyShape(Circle())))
            .foregroundStyle(.white)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || assistant.state == .thinking)
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .liquidGlassCard(radius: 24)
    }

    private var ideasList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Idee").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            ForEach(ideas, id: \.self) { idea in
                Button {
                    question = idea
                    send()
                } label: {
                    HStack {
                        Text(idea).font(.subheadline)
                        Spacer()
                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .liquidGlassCard(radius: 16)
            }
        }
        .padding(.top, 4)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !assistant.intro.isEmpty {
                Text(assistant.intro).font(.body)
            }
            ForEach(assistant.picks) { pick in
                Button { if let item = pick.item { focused = false; selected = item } } label: { row(pick) }
                    .buttonStyle(.plain)
                    .disabled(pick.item == nil)
            }
            Text("I suggerimenti sono generati dall'intelligenza artificiale e possono contenere imprecisioni.")
                .font(.caption2).foregroundStyle(Theme.secondaryText).padding(.top, 4)
        }
    }

    private func row(_ pick: LumenAssistant.Pick) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ImageTile(url: pick.item?.bestPosterImage, width: 70, height: 105, corner: 8)
                .overlay { if pick.item == nil { Image(systemName: "film").foregroundStyle(Theme.secondaryText) } }
            VStack(alignment: .leading, spacing: 5) {
                Text(pick.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let y = pick.year { Text(String(y)) }
                    Text(pick.isSeries ? "Serie TV" : "Film")
                    if let item = pick.item, let match = library.taste.compatibility(item) {
                        MatchBadge(percent: match, compact: true)
                    }
                }
                .font(.caption).foregroundStyle(Theme.secondaryText)
                Text(pick.reason).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if pick.available {
                    Label("Disponibile in Lumen", systemImage: "play.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(.green)
                } else if pick.item == nil {
                    Text("Non trovato nel catalogo").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .liquidGlassCard(radius: 18)
    }

    private func send() {
        let q = question
        focused = false
        Task { await assistant.ask(q, app: app, library: library) }
    }
}
