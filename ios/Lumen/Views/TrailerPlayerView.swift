import SwiftUI
import WebKit

/// Riproduce il trailer dentro l'app con il player ufficiale incorporato di YouTube.
struct TrailerPlayerView: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var loading = true

    static func videoId(from url: URL) -> String? {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let v = comps?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        if url.host?.contains("youtu.be") == true { return url.lastPathComponent }
        if url.path.contains("/embed/") { return url.lastPathComponent }
        return nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                ZStack {
                    if let id = Self.videoId(from: url) {
                        YouTubeEmbed(videoId: id, loading: $loading)
                    }
                    if loading { ProgressView().tint(.white) }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.6))
                .padding(.horizontal, 12)

                Text(title).font(.headline).multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
                Button { openURL(url) } label: {
                    Label("Apri su YouTube", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .buttonStyle(GlassButtonStyle())
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 40, height: 40)
            }
            .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
            .foregroundStyle(.white)
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }
}

struct YouTubeEmbed: UIViewRepresentable {
    let videoId: String
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.navigationDelegate = context.coordinator
        load(in: web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    private func load(in web: WKWebView) {
        let origin = "https://pasqualepriore94-dotcom.github.io"
        let src = "https://www.youtube-nocookie.com/embed/\(videoId)?playsinline=1&autoplay=1&rel=0&modestbranding=1&origin=\(origin)"
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:fixed;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(src)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
                referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: origin + "/"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loading: Binding<Bool>
        init(loading: Binding<Bool>) { self.loading = loading }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.loading.wrappedValue = false }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // I link che portano fuori dal player (logo YouTube, "guarda su YouTube") si aprono in Safari/YouTube.
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
