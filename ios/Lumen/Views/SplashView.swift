import SwiftUI
import UIKit

/// Animazione di avvio: compare una "L" luminosa, poi le lettere completano il nome dell'app,
/// infine la scritta si dissolve e si entra nell'app. Un tocco la salta.
struct SplashView: View {
    @Environment(AppState.self) private var app
    var onFinish: () -> Void

    @State private var visibleCount = 0
    @State private var lScale: CGFloat = 0.3
    @State private var lightSweep = false
    @State private var underline: CGFloat = 0
    @State private var leaving = false
    @State private var finished = false

    private var letters: [String] {
        let name = app.config.appName.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Lumen" : name).map(String.init)
    }

    var body: some View {
        ZStack {
            AuroraBackground(accent: app.accent)

            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    ForEach(0..<visibleCount, id: \.self) { i in
                        Text(letters[i])
                            .font(.system(size: 68, weight: .heavy, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(colors: [.white, .white.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                            )
                            .scaleEffect(i == 0 ? lScale : 1)
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.6, anchor: .leading)),
                                removal: .opacity))
                    }
                }
                .fixedSize()
                .overlay {
                    // riflesso di luce che attraversa la scritta
                    LinearGradient(colors: [.clear, .white.opacity(0.8), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 70)
                        .rotationEffect(.degrees(18))
                        .offset(x: lightSweep ? 220 : -220)
                        .blendMode(.overlay)
                        .allowsHitTesting(false)
                }
                .mask {
                    HStack(spacing: 0) {
                        ForEach(0..<visibleCount, id: \.self) { i in
                            Text(letters[i]).font(.system(size: 68, weight: .heavy, design: .rounded))
                                .scaleEffect(i == 0 ? lScale : 1)
                        }
                    }
                    .fixedSize()
                }
                .shadow(color: app.accent.opacity(0.9), radius: 24)
                .shadow(color: app.accent.opacity(0.5), radius: 60)

                Capsule()
                    .fill(LinearGradient(colors: [app.accent.opacity(0), app.accent, app.accent.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 220 * underline, height: 3)
                    .shadow(color: app.accent, radius: 8)
            }
            .scaleEffect(leaving ? 1.18 : 1)
            .opacity(leaving ? 0 : 1)
            .blur(radius: leaving ? 10 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await run() }
    }

    private func run() async {
        // 1. la "L"
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            visibleCount = 1
            lScale = 1
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        try? await Task.sleep(for: .milliseconds(650))

        // 2. le altre lettere, una alla volta
        for i in 1..<letters.count {
            guard !finished else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { visibleCount = i + 1 }
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
            try? await Task.sleep(for: .milliseconds(150))
        }

        // 3. luce e sottolineatura
        withAnimation(.easeInOut(duration: 0.7)) {
            lightSweep = true
            underline = 1
        }
        try? await Task.sleep(for: .milliseconds(850))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeIn(duration: 0.35)) { leaving = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(330))
            onFinish()
        }
    }
}
