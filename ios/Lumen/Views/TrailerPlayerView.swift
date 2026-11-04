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

/// Anteprima del trailer che parte da sola, senza audio e senza controlli, in testa alla scheda del titolo.
struct TrailerPreview: UIViewRepresentable {
    let videoId: String
    var muted: Bool
    var paused: Bool
    /// true: controlli di YouTube visibili e toccabili (scheda del titolo). false: solo video (clip).
    var controls: Bool = false
    /// false: il trailer resta fermo sulla copertina finché l'utente non preme play.
    var autoplay: Bool = true
    @Binding var playing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(playing: $playing, controls: controls) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.lastMuted = muted
        context.coordinator.lastPaused = paused
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.userContentController.add(context.coordinator, name: "yt")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = controls
        web.navigationDelegate = context.coordinator
        let origin = "https://pasqualepriore94-dotcom.github.io"
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
        html,body{margin:0;height:100%;background:transparent;overflow:hidden}
        #p{position:fixed;left:50%;top:50%;width:100%;height:100%;transform:translate(-50%,-50%);pointer-events:\(controls ? "auto" : "none")}
        </style></head><body><div id="p"></div>
        <script>
        var player, wantMuted = \(muted), wantPaused = \(autoplay ? "false" : "true");
        function post(v){ try{ window.webkit.messageHandlers.yt.postMessage(v) }catch(e){} }
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('p', {
            host: 'https://www.youtube-nocookie.com', videoId: '\(videoId)', width: '100%', height: '100%',
            playerVars: { autoplay: \(autoplay ? 1 : 0), mute: \(autoplay ? 1 : 0), playsinline: 1, controls: \(controls ? 1 : 0), rel: 0, modestbranding: 1,
                          loop: 1, playlist: '\(videoId)', iv_load_policy: 3, fs: \(controls ? 1 : 0), disablekb: \(controls ? 0 : 1), origin: '\(origin)' },
            events: {
              onReady: function(e){ post(100); if(wantMuted && \(autoplay)){ e.target.mute() } else if(!wantMuted){ e.target.unMute(); e.target.setVolume(100) }
                                    if(!wantPaused){ e.target.playVideo() } },
              onStateChange: function(e){ post(e.data) },
              onError: function(e){ post(-2) }
            }
          });
        }
        function setMuted(m){ wantMuted = m; if(!player||!player.mute) return; if(m){ player.mute() } else { player.unMute(); player.setVolume(100) } }
        function setPaused(p){ wantPaused = p; if(!player||!player.pauseVideo) return; if(p){ player.pauseVideo() } else { player.playVideo() } }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: origin + "/"))
        context.coordinator.web = web
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        if c.lastMuted != muted { c.lastMuted = muted; web.evaluateJavaScript("setMuted(\(muted))") }
        if c.lastPaused != paused {
            c.lastPaused = paused
            // Senza avvio automatico si mette solo in pausa: a ripartire è l'utente.
            if paused || autoplay { web.evaluateJavaScript("setPaused(\(paused))") }
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.evaluateJavaScript("setPaused(true)")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        web.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var playing: Binding<Bool>
        let controls: Bool
        weak var web: WKWebView?
        var lastMuted = true
        var lastPaused = false
        init(playing: Binding<Bool>, controls: Bool) { self.playing = playing; self.controls = controls }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Logo YouTube / "Guarda su YouTube": fuori dall'app.
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let state = message.body as? Int else { return }
            // 1 = in riproduzione; -2 = errore (video non incorporabile): resta l'immagine.
            DispatchQueue.main.async {
                // Con i controlli il player si mostra appena pronto (se l'avvio automatico non riesce, si tocca play).
                if state == 1 || (self.controls && state == 100) { self.playing.wrappedValue = true }
                if state == -2 { self.playing.wrappedValue = false }
            }
        }
    }
}
