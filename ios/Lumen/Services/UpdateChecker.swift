import SwiftUI
import Observation

/// Controlla su GitHub se esiste una build più recente di quella installata.
@MainActor
@Observable
final class UpdateChecker {
    struct Update: Equatable {
        let version: String
        let build: Int
        let ipaURL: URL
        let notes: String
    }

    var available: Update? = nil
    var dismissedBuild: Int = UserDefaults.standard.integer(forKey: "lumen.dismissedUpdate")

    private var repo: String {
        let s = (Bundle.main.object(forInfoDictionaryKey: "UpdateRepo") as? String) ?? ""
        return s.contains("/") ? s : "pasqualepriore94-dotcom/Lumen"
    }

    var currentBuild: Int {
        Int((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "") ?? 0
    }

    var showBanner: Bool {
        guard let available else { return false }
        return available.build != dismissedBuild
    }

    private var feedURL: URL? {
        let s = ((Bundle.main.object(forInfoDictionaryKey: "UpdateFeedURL") as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("http") ? URL(string: s) : nil
    }

    /// Legge la sorgente SideStore pubblicata a ogni build (versione, numero di build, link all'IPA).
    func check() async {
        guard let url = feedURL else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (json["apps"] as? [[String: Any]])?.first,
              let latest = (app["versions"] as? [[String: Any]])?.first,
              let build = Int("\(latest["buildVersion"] ?? "")"),
              let ipa = latest["downloadURL"] as? String, let ipaURL = URL(string: ipa) else { return }
        guard build > currentBuild else {
            available = nil
            return
        }
        available = Update(version: (latest["version"] as? String) ?? "", build: build, ipaURL: ipaURL,
                           notes: (latest["localizedDescription"] as? String) ?? "")
    }

    func dismiss() {
        guard let available else { return }
        dismissedBuild = available.build
        UserDefaults.standard.set(available.build, forKey: "lumen.dismissedUpdate")
    }

    /// Apre SideStore per installare l'aggiornamento; se non è installato, scarica l'IPA da Safari.
    func install() {
        guard let available else { return }
        let encoded = available.ipaURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?"))) ?? ""
        let candidates = ["sidestore://install?url=\(encoded)", "altstore://install?url=\(encoded)"]
            .compactMap(URL.init(string:))
        func attempt(_ index: Int) {
            guard index < candidates.count else {
                UIApplication.shared.open(available.ipaURL)
                return
            }
            UIApplication.shared.open(candidates[index]) { ok in
                if !ok { Task { @MainActor in attempt(index + 1) } }
            }
        }
        attempt(0)
    }
}

/// Banner in vetro che avvisa della nuova versione.
struct UpdateBanner: View {
    @Environment(AppState.self) private var app
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        if updates.showBanner, let u = updates.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(app.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nuovo aggiornamento disponibile").font(.subheadline.weight(.semibold))
                    Text("Versione \(u.version) (build \(u.build))").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 4)
                Button { updates.install() } label: {
                    Text("Aggiorna").font(.footnote.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(GlassButtonStyle(tint: app.accent))
                Button { withAnimation { updates.dismiss() } } label: {
                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 28, height: 28)
                }
                .buttonStyle(GlassButtonStyle(shape: AnyShape(Circle())))
            }
            .foregroundStyle(.white)
            .padding(12)
            .liquidGlassCard(radius: 24)
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
