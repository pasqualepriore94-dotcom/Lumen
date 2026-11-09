import SwiftUI
import Observation

/// Controlla su GitHub se esiste una build più recente di quella installata.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Update: Equatable {
        let version: String
        let build: Int
        let ipaURL: URL
        let notes: String
    }

    var available: Update? = nil
    /// "Più tardi": il banner e la finestra tornano dopo 24 ore (prima il banner chiuso spariva per sempre).
    var snoozedUntil: Date? = UserDefaults.standard.object(forKey: "lumen.updateSnoozedUntil") as? Date
    /// Finestra "Aggiorna Lumen" da mostrare (la apre la schermata principale).
    var promptPending = false
    @ObservationIgnored private var lastCheck: Date?

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    private var repo: String {
        let s = (Bundle.main.object(forInfoDictionaryKey: "UpdateRepo") as? String) ?? ""
        return s.contains("/") ? s : "pasqualepriore94-dotcom/Lumen"
    }

    var currentBuild: Int {
        Int((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "") ?? 0
    }

    var showBanner: Bool {
        guard available != nil else { return false }
        return (snoozedUntil ?? .distantPast) < Date()
    }

    private var feedURL: URL? {
        let s = ((Bundle.main.object(forInfoDictionaryKey: "UpdateFeedURL") as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("http") ? URL(string: s) : nil
    }

    /// Legge la sorgente SideStore pubblicata a ogni build (versione, numero di build, link all'IPA).
    func check(force: Bool = false) async {
        guard let url = feedURL else { return }
        // Al rientro nell'app al massimo ogni 30 minuti
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 30 * 60 { return }
        lastCheck = Date()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (json["apps"] as? [[String: Any]])?.first,
              let latest = (app["versions"] as? [[String: Any]])?.first,
              let build = Int("\(latest["buildVersion"] ?? "")"),
              let ipa = latest["downloadURL"] as? String, let ipaURL = URL(string: ipa) else { return }
        let version = (latest["version"] as? String) ?? ""
        // Più recente se il numero di build è maggiore o, a parità, se la versione è maggiore
        guard build > currentBuild || Self.isNewer(version, than: currentVersion) else {
            available = nil
            return
        }
        available = Update(version: (latest["version"] as? String) ?? "", build: build, ipaURL: ipaURL,
                           notes: (latest["localizedDescription"] as? String) ?? "")
        if showBanner { promptPending = true }
        if UserDefaults.standard.integer(forKey: "lumen.notifiedUpdate") != build {
            UserDefaults.standard.set(build, forKey: "lumen.notifiedUpdate")
            NotificationStore.shared.post(AppNotification(kind: .update, title: "Nuovo aggiornamento disponibile",
                                                          body: "Versione \((latest["version"] as? String) ?? "") (build \(build)). Installalo dal banner in alto o da SideStore.",
                                                          icon: "arrow.down.app.fill"))
        }
    }

    /// "Più tardi": niente banner né finestra per 24 ore.
    func dismiss() {
        let until = Date().addingTimeInterval(24 * 3600)
        snoozedUntil = until
        promptPending = false
        UserDefaults.standard.set(until, forKey: "lumen.updateSnoozedUntil")
    }

    /// Finestra a comparsa con le novità della versione da installare.
    func promptNotification() -> AppNotification? {
        guard let available else { return nil }
        let lines = available.notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "• ", with: "") }
            .filter { !$0.isEmpty && !$0.hasPrefix("Build ") }
        var items = [AnnouncementItem(icon: "iphone.and.arrow.forward",
                                      text: "Hai la versione \(currentVersion). È disponibile la \(available.version): aggiorna per avere tutte le novità e le correzioni.")]
        items += lines.prefix(8).map { AnnouncementItem(icon: "sparkles", text: $0) }
        var n = AppNotification(kind: .update, title: "Aggiorna Lumen",
                                body: "Versione \(available.version) (build \(available.build))", icon: "arrow.down.app.fill")
        n.items = items
        n.subtitle = "Versione \(available.version) disponibile"
        return n
    }

    /// Le app installate normalmente stanno in /var/containers/Bundle; dentro LiveContainer l'app gira
    /// dalla cartella dati di LiveContainer.
    static var runsInLiveContainer: Bool {
        let path = Bundle.main.bundlePath
        return !(path.hasPrefix("/private/var/containers/Bundle/") || path.hasPrefix("/var/containers/Bundle/"))
    }

    /// Notifica che propone l'aggiornamento (non "Cosa c'è di nuovo", che usa lo stesso tipo).
    static func isOffer(_ n: AppNotification) -> Bool { n.kind == .update && n.icon == "arrow.down.app.fill" }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Apre SideStore per installare l'aggiornamento; se non è installato, scarica l'IPA da Safari.
    func install() {
        guard let available else { return }
        let encoded = available.ipaURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?"))) ?? ""
        // Dentro LiveContainer l'aggiornamento si installa lì (sostituisce l'app tenendo i dati)
        let schemes = Self.runsInLiveContainer
            ? ["livecontainer://install?url=\(encoded)", "sidestore://install?url=\(encoded)"]
            : ["sidestore://install?url=\(encoded)", "altstore://install?url=\(encoded)", "livecontainer://install?url=\(encoded)"]
        let candidates = schemes.compactMap(URL.init(string:))
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
