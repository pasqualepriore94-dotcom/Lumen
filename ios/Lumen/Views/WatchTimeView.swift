import SwiftUI
import UIKit

func formatWatchTime(_ minutes: Int) -> String {
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let mins = minutes % 60
    var parts: [String] = []
    if days > 0 { parts.append(days == 1 ? "1 giorno" : "\(days) giorni") }
    if hours > 0 { parts.append("\(hours) h") }
    if mins > 0 || parts.isEmpty { parts.append("\(mins) min") }
    return parts.joined(separator: " ")
}

/// Riepilogo del tempo passato davanti alla TV, separato tra film e serie.
struct WatchTimeView: View {
    @Environment(AppState.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// Titolo appena segnato come visto, mostrato in evidenza.
    var highlight: WatchedEntry?

    @State private var filter = 0

    var body: some View {
        let t = library.totals
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let h = highlight {
                        HStack(spacing: 12) {
                            ImageTile(url: h.item.bestPosterImage, width: 46, height: 68, corner: 8)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Segnato come visto").font(.caption).foregroundStyle(Theme.secondaryText)
                                Text(h.item.title).font(.headline).lineLimit(2)
                                Text("+ \(formatWatchTime(h.minutes))" + (h.isSeries ? " · \(h.episodes) episodi" : ""))
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(app.accent)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .liquidGlassCard(radius: 22)
                    }

                    VStack(spacing: 6) {
                        Text("Tempo totale davanti alla TV").font(.subheadline).foregroundStyle(Theme.secondaryText)
                        Text(formatWatchTime(t.totalMinutes))
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                        Text(String(format: "%.1f ore", Double(t.totalMinutes) / 60))
                            .font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .liquidGlassCard(radius: 30, tint: app.accent.opacity(0.4))

                    GlassGroup(spacing: 12) {
                        HStack(spacing: 12) {
                            statCard(icon: "film", title: "Film", time: t.movieMinutes,
                                     detail: t.movies == 1 ? "1 film" : "\(t.movies) film",
                                     color: Color(red: 0.36, green: 0.62, blue: 1))
                            statCard(icon: "tv", title: "Serie TV", time: t.seriesMinutes,
                                     detail: "\(t.series) serie · \(t.episodes) ep.",
                                     color: Color(red: 1, green: 0.48, blue: 0.35))
                        }
                    }

                    if t.totalMinutes > 0 {
                        proportionBar(t)
                    }

                    list
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(AuroraBackground(accent: app.accent).opacity(0.6))
            .navigationTitle("Visti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } } }
            .animation(.snappy, value: t.totalMinutes)
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    private func statCard(icon: String, title: String, time: Int, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .liquidGlass(in: Circle(), tint: color.opacity(0.35))
            Text(title).font(.subheadline).foregroundStyle(Theme.secondaryText)
            Text(formatWatchTime(time)).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .liquidGlassCard(radius: 24)
    }

    private func proportionBar(_ t: WatchTotals) -> some View {
        let movieShare = Double(t.movieMinutes) / Double(max(1, t.totalMinutes))
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    Capsule().fill(Color(red: 0.36, green: 0.62, blue: 1))
                        .frame(width: max(0, (geo.size.width - 3) * movieShare))
                    Capsule().fill(Color(red: 1, green: 0.48, blue: 0.35))
                }
            }
            .frame(height: 10)
            HStack {
                Text("Film \(Int((movieShare * 100).rounded()))%")
                Spacer()
                Text("Serie \(100 - Int((movieShare * 100).rounded()))%")
            }
            .font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .padding(16)
        .liquidGlassCard(radius: 22)
    }

    private var list: some View {
        let entries = library.watchedList.filter { filter == 0 || (filter == 1 ? !$0.isSeries : $0.isSeries) }
        return VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $filter) {
                Text("Tutti").tag(0)
                Text("Film").tag(1)
                Text("Serie").tag(2)
            }
            .pickerStyle(.segmented)

            if entries.isEmpty {
                Text("Tocca \"Visto\" nella scheda di un film o di una serie per aggiungerlo al conteggio.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                    .padding(.vertical, 12)
            }
            ForEach(entries) { e in
                HStack(spacing: 12) {
                    ImageTile(url: e.item.bestPosterImage, width: 40, height: 60, corner: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text((e.isSeries ? "Serie · \(e.episodes) ep. · " : "Film · ") + formatWatchTime(e.minutes)
                             + (e.estimated ? " (stima)" : ""))
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Button {
                        withAnimation { library.unmarkWatched(e.id) }
                    } label: {
                        Image(systemName: "xmark").font(.caption.bold()).frame(width: 30, height: 30)
                    }
                    .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
                }
                .padding(10)
                .liquidGlassCard(radius: 18)
            }
        }
    }
}

// MARK: - Icona dell'app

enum AppIconOption: String, CaseIterable, Identifiable {
    case opzione2 = "", opzione1 = "AppIcon-Opzione1", opzione3 = "AppIcon-Opzione3", opzione4 = "AppIcon-Opzione4"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .opzione2: return "Obiettivo"
        case .opzione1: return "Pellicola"
        case .opzione3: return "Schermi"
        case .opzione4: return "Nastro"
        }
    }
    var preview: String {
        switch self {
        case .opzione2: return "IconPreview-2"
        case .opzione1: return "IconPreview-1"
        case .opzione3: return "IconPreview-3"
        case .opzione4: return "IconPreview-4"
        }
    }
    var iconName: String? { rawValue.isEmpty ? nil : rawValue }
}

struct AppIconPicker: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current = UIApplication.shared.alternateIconName ?? ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(AppIconOption.allCases) { option in
                        Button { choose(option) } label: {
                            VStack(spacing: 10) {
                                Image(option.preview)
                                    .resizable()
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                                        .stroke(current == option.rawValue ? app.accent : .white.opacity(0.15),
                                                lineWidth: current == option.rawValue ? 3 : 0.6))
                                HStack(spacing: 6) {
                                    if current == option.rawValue {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(app.accent)
                                    }
                                    Text(option.label).font(.subheadline.weight(.semibold))
                                }
                            }
                            .padding(12)
                            .liquidGlassCard(radius: 28)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red).padding()
                }
            }
            .background(AuroraBackground(accent: app.accent).opacity(0.5))
            .navigationTitle("Icona dell'app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func choose(_ option: AppIconOption) {
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "Questo dispositivo non permette di cambiare icona."
            return
        }
        UIApplication.shared.setAlternateIconName(option.iconName) { error in
            Task { @MainActor in
                if let error {
                    errorMessage = "Impossibile cambiare icona: \(error.localizedDescription)"
                } else {
                    withAnimation { current = option.rawValue }
                    AppIconMemory.save(option)
                    errorMessage = nil
                }
            }
        }
    }
}

// MARK: - Tema

struct ThemePreset: Identifiable {
    let id: String
    let name: String
    let hex: String
}

/// Scelta del colore principale dell'app, salvata su questo dispositivo.
struct ThemePicker: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    static let presets: [ThemePreset] = [
        .init(id: "viola", name: "Viola", hex: "#7C5CFF"),
        .init(id: "rubino", name: "Rubino", hex: "#FF3B5C"),
        .init(id: "blu", name: "Blu", hex: "#3D8BFF"),
        .init(id: "ciano", name: "Ciano", hex: "#22C7E8"),
        .init(id: "verde", name: "Smeraldo", hex: "#2BD38B"),
        .init(id: "oro", name: "Oro", hex: "#F5B83D"),
        .init(id: "arancio", name: "Tramonto", hex: "#FF7A3D"),
        .init(id: "rosa", name: "Rosa", hex: "#FF4FB8"),
    ]

    private var selectedHex: String? { app.userAccentHex?.uppercased() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // anteprima
                    VStack(spacing: 12) {
                        LogoMark(size: 56)
                        HStack(spacing: 10) {
                            Text("Riproduci").font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 10)
                                .liquidGlassCapsule(tint: app.accent)
                            Text("La mia lista").font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 10)
                                .liquidGlassCapsule()
                        }
                        Capsule().fill(app.accent).frame(width: 160, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .liquidGlassCard(radius: 28)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 18) {
                        ForEach(Self.presets) { p in
                            Button { select(p.hex) } label: {
                                VStack(spacing: 8) {
                                    Circle()
                                        .fill(LinearGradient(colors: [Color(hex: p.hex) ?? .purple, (Color(hex: p.hex) ?? .purple).opacity(0.6)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 52, height: 52)
                                        .overlay(Circle().stroke(.white, lineWidth: selectedHex == p.hex ? 3 : 0))
                                        .overlay {
                                            if selectedHex == p.hex {
                                                Image(systemName: "checkmark").font(.headline.bold())
                                            }
                                        }
                                        .shadow(color: (Color(hex: p.hex) ?? .clear).opacity(0.6), radius: 10)
                                    Text(p.name).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .liquidGlassCard(radius: 28)

                    VStack(spacing: 0) {
                        ColorPicker("Colore personalizzato", selection: Binding(
                            get: { app.accent },
                            set: { app.userAccentHex = $0.hexString }), supportsOpacity: false)
                            .padding(.horizontal, 16).frame(height: 52)
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
                        Button {
                            withAnimation { app.userAccentHex = nil }
                        } label: {
                            HStack {
                                Text("Usa il colore predefinito")
                                Spacer()
                                if app.userAccentHex == nil { Image(systemName: "checkmark").foregroundStyle(app.accent) }
                            }
                            .padding(.horizontal, 16).frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .liquidGlassCard(radius: 22)

                    Text("Il tema viene salvato su questo iPhone e resta anche dopo gli aggiornamenti dell'app.")
                        .font(.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .foregroundStyle(.white)
            .background(AuroraBackground(accent: app.accent).opacity(0.6))
            .navigationTitle("Tema")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .animation(.snappy, value: app.userAccentHex)
        }
        .preferredColorScheme(.dark)
    }

    private func select(_ hex: String) {
        app.userAccentHex = hex
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// Riapplica l'icona scelta se una reinstallazione l'ha riportata a quella predefinita.
enum AppIconMemory {
    static let key = "lumen.iconChoice"

    static func save(_ option: AppIconOption) {
        UserDefaults.standard.set(option.rawValue, forKey: key)
    }

    @MainActor
    static func restoreIfNeeded() {
        guard let saved = UserDefaults.standard.string(forKey: key),
              UIApplication.shared.supportsAlternateIcons else { return }
        let current = UIApplication.shared.alternateIconName ?? ""
        guard saved != current else { return }
        UIApplication.shared.setAlternateIconName(saved.isEmpty ? nil : saved) { _ in }
    }
}
