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
        static let pin = "lumen.adminPIN"
        static let lastSync = "lumen.lastSync"
    }

    var config: AppConfig { didSet { persistConfig() } }
    var remoteConfigURL: String { didSet { UserDefaults.standard.set(remoteConfigURL, forKey: Keys.remoteURL) } }
    var autoSync: Bool { didSet { UserDefaults.standard.set(autoSync, forKey: Keys.autoSync) } }
    var adminPIN: String { didSet { UserDefaults.standard.set(adminPIN, forKey: Keys.pin) } }
    var lastSync: Date? { didSet { UserDefaults.standard.set(lastSync, forKey: Keys.lastSync) } }

    var isSyncing = false
    var syncMessage: String? = nil
    /// Cambia ogni volta che i contenuti vanno ricaricati.
    var reloadToken = UUID()

    // Navigazione
    var selectedTab: AppTab = .home
    var detailItem: MediaItem? = nil
    var showAdmin = false
    var isPreparingPlayback = false

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.config),
           let saved = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = saved
        } else {
            config = .default
        }
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "RemoteConfigURL") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        remoteConfigURL = defaults.string(forKey: Keys.remoteURL) ?? (bundled.hasPrefix("http") ? bundled : "")
        autoSync = defaults.object(forKey: Keys.autoSync) as? Bool ?? true
        adminPIN = defaults.string(forKey: Keys.pin) ?? "0000"
        lastSync = defaults.object(forKey: Keys.lastSync) as? Date
    }

    // MARK: Provider

    var activeProviderConfig: ProviderConfig? {
        let enabled = config.providers.filter(\.enabled)
        return enabled.first { $0.id == config.activeProviderId } ?? enabled.first
    }

    var provider: ContentProvider { ProviderFactory.make(activeProviderConfig) }

    /// Chiave da usare in `.task(id:)` per ricaricare quando cambia la sorgente.
    var contentKey: String { "\(activeProviderConfig?.id ?? "none")|\(reloadToken.uuidString)" }

    var accent: Color { Color(hex: config.accentHex) ?? Color(red: 0.49, green: 0.36, blue: 1) }

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
        if config.providers.isEmpty { config.providers = [.demo] }
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
                if p.headers.isEmpty, let local = config.providers.first(where: { $0.id == p.id }) {
                    p.headers = local.headers
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
