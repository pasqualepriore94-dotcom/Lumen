import SwiftUI
import Observation

enum AppTab: String, CaseIterable, Identifiable {
    case home, clips, search, profile
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .clips: return "Clip"
        case .search: return "Cerca"
        case .profile: return "Il mio"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .clips: return "play.rectangle.on.rectangle"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return "house.fill"
        case .clips: return "play.rectangle.on.rectangle.fill"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle.fill"
        }
    }
}

/// Stato globale: configurazione (provider, aspetto), sincronizzazione remota e navigazione.
@MainActor
@Observable
final class AppState {
    private enum Keys {
        static let config = "lumen.config"
        static let remoteURL = "lumen.remoteConfigURL"
        static let autoSync = "lumen.autoSync"
        static let lastSync = "lumen.lastSync"
    }

    var config: AppConfig { didSet { persistConfig() } }
    var remoteConfigURL: String { didSet { UserDefaults.standard.set(remoteConfigURL, forKey: Keys.remoteURL) } }
    var autoSync: Bool { didSet { UserDefaults.standard.set(autoSync, forKey: Keys.autoSync) } }
    var lastSync: Date? { didSet { UserDefaults.standard.set(lastSync, forKey: Keys.lastSync) } }

    var isSyncing = false
    var syncMessage: String? = nil
    /// Cambia ogni volta che i contenuti vanno ricaricati.
    var reloadToken = UUID()

    // Navigazione
    var selectedTab: AppTab = .home
    /// Toccando un pulsante della barra in basso la schermata torna in cima.
    var scrollTopSignal = 0
    /// Link di attivazione di un account aperto dall'email (lumen://approve…).
    var approvalRequest: ApprovalRequest?
    var scrollTopTab: AppTab = .home

    func scrollToTop(_ tab: AppTab) {
        scrollTopTab = tab
        scrollTopSignal += 1
    }
    var detailItem: MediaItem? = nil
    var showAdmin = false
    var showCatalog = false
    var isPreparingPlayback = false

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.config),
           let saved = try? JSONDecoder().decode(AppConfig.self, from: data) {
            var migrated = saved
            if !migrated.providers.contains(where: { $0.type == .tmdb }) {
                migrated.providers.insert(.tmdb, at: 0)
            }
            // Chiavi predefinite per le installazioni che non le hanno ancora.
            for i in migrated.providers.indices where migrated.providers[i].type == .tmdb {
                for (key, value) in ProviderConfig.tmdb.options where migrated.providers[i].option(key).isEmpty {
                    migrated.providers[i].options[key] = value
                }
            }
            if migrated.activeProviderId == "demo" { migrated.activeProviderId = "tmdb" }
            config = migrated
        } else {
            config = .default
        }
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "RemoteConfigURL") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let savedURL = defaults.string(forKey: Keys.remoteURL)
        // Le installazioni precedenti puntavano a GitHub (ora privato): passa all'indirizzo pubblico della build.
        if let savedURL, !(savedURL.contains("raw.githubusercontent.com") && bundled.hasPrefix("http")) {
            remoteConfigURL = savedURL
        } else {
            remoteConfigURL = bundled.hasPrefix("http") ? bundled : ""
        }
        autoSync = defaults.object(forKey: Keys.autoSync) as? Bool ?? true
        lastSync = defaults.object(forKey: Keys.lastSync) as? Date
    }

    // MARK: Provider

    var activeProviderConfig: ProviderConfig? {
        let usable = config.providers.filter(\.isUsable)
        return usable.first { $0.id == config.activeProviderId } ?? usable.first
    }

    var provider: ContentProvider { ProviderFactory.make(activeProviderConfig) }

    /// Chiave da usare in `.task(id:)` per ricaricare quando cambia la sorgente.
    var contentKey: String { "\(activeProviderConfig?.id ?? "none")|\(reloadToken.uuidString)" }

    /// Tema scelto dall'utente su questo dispositivo (nil = colore predefinito dell'amministratore).
    var userAccentHex: String? = UserDefaults.standard.string(forKey: "lumen.userAccent") {
        didSet { UserDefaults.standard.set(userAccentHex, forKey: "lumen.userAccent") }
    }

    var accent: Color {
        if let user = userAccentHex, let c = Color(hex: user) { return c }
        return Color(hex: config.accentHex) ?? Color(red: 0.49, green: 0.36, blue: 1)
    }

    func setActiveProvider(_ id: String) {
        config.activeProviderId = id
        reload()
    }

    func upsert(_ provider: ProviderConfig) {
        if let i = config.providers.firstIndex(where: { $0.id == provider.id }) {
            config.providers[i] = provider
        } else {
            config.providers.append(provider)
        }
        reload()
    }

    func deleteProvider(id: String) {
        config.providers.removeAll { $0.id == id }
        if config.providers.isEmpty { config.providers = AppConfig.default.providers }
        reload()
    }

    func reload() { reloadToken = UUID() }

    func resetToDefaults() {
        config = .default
        reload()
    }

    // MARK: Configurazione remota

    func syncRemote() async {
        let trimmed = remoteConfigURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed) else {
            syncMessage = "URL della configurazione non valido."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ProviderError.http(http.statusCode)
            }
            var remote = try JSONDecoder().decode(AppConfig.self, from: data)
            // Le intestazioni (chiavi/token) inserite solo su questo dispositivo restano.
            remote.providers = remote.providers.map { incoming in
                var p = incoming
                if let local = config.providers.first(where: { $0.id == p.id }) {
                    if p.headers.isEmpty { p.headers = local.headers }
                    for (key, value) in local.options where p.option(key).isEmpty && !value.isEmpty {
                        p.options[key] = value
                    }
                }
                return p
            }
            let changed = remote != config
            config = remote
            lastSync = Date()
            syncMessage = changed ? "Configurazione aggiornata." : "Già aggiornata."
            if changed { reload() }
        } catch {
            syncMessage = "Sincronizzazione non riuscita: \(error.localizedDescription)"
        }
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Keys.config)
        }
    }
}


/// Richiesta di attivazione arrivata dal link nell'email dell'amministratore.
struct ApprovalRequest: Identifiable {
    var id: String { token + action }
    var token: String
    var action: String          // "approve" | "reject"
    var username: String
    var email: String
    var invalid: Bool

    init?(url: URL) {
        guard url.scheme?.lowercased() == "lumen", url.host?.lowercased() == "approve",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ k: String) -> String { items.first { $0.name == k }?.value ?? "" }
        token = value("token")
        action = value("action") == "reject" ? "reject" : "approve"
        username = value("user")
        email = value("email")
        invalid = value("invalid") == "1" || token.isEmpty
    }
}
