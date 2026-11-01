import SwiftUI

// Liquid Glass: su iOS 26 usa il materiale di sistema (`glassEffect`), sulle versioni
// precedenti un vetro smerigliato con riflesso sul bordo che ne imita l'aspetto.
// Il codice iOS 26 viene compilato solo con Xcode 26 (Swift 6.2) o successivo.

extension View {
    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        liquidGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    func liquidGlassCard(radius: CGFloat = 22, tint: Color? = nil) -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }

    fileprivate func legacyGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.35)) }
                    shape.fill(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.02)],
                                              startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay {
                shape.stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08), .white.opacity(0.22)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing),
                             lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }
}

#if compiler(>=6.2)

extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(GlassStyle.make(tint: tint, interactive: interactive), in: shape)
        } else {
            self.legacyGlass(in: shape, tint: tint)
        }
    }
}

@available(iOS 26.0, *)
enum GlassStyle {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Raggruppa più elementi di vetro così che su iOS 26 si fondano tra loro.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

#else

extension View {
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        legacyGlass(in: shape, tint: tint)
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View { content }
}

#endif

/// Pulsante in vetro; con `tint` prende il colore principale dell'app.
struct GlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var shape: AnyShape = AnyShape(Capsule())

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .liquidGlass(in: shape, tint: tint, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Sfondo animato a "bolle" di colore, ideale dietro al vetro.
struct AuroraBackground: View {
    var accent: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            Color.black
            Circle().fill(accent).frame(width: 420).blur(radius: 120)
                .offset(x: animate ? -120 : -60, y: animate ? -260 : -200)
            Circle().fill(accent.opacity(0.7)).frame(width: 360).blur(radius: 110)
                .offset(x: animate ? 140 : 90, y: animate ? 40 : 120)
            Circle().fill(Color(red: 1, green: 0.42, blue: 0.21).opacity(0.45)).frame(width: 300).blur(radius: 120)
                .offset(x: animate ? -80 : 30, y: animate ? 330 : 280)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { animate = true }
        }
    }
}
