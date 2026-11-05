import Foundation
import Observation
import Security
import CryptoKit

struct AppUser: Codable, Identifiable, Hashable {
    var id: String
    var username: String
    var email: String
    var role: String
    var approved: Bool
    var createdAt: String?
    var approvedAt: String?

    var isAdmin: Bool { role == "admin" }

    var createdDate: Date? {
        guard let createdAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
}

enum AuthError: LocalizedError {
    case server(String)
    case noServer
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .noServer: return "Il server degli account non è configurato: per ora è disponibile solo l'accesso amministratore."
        case .invalidCredentials: return "Username o password errati."
        }
    }
}

/// Account utente. Con un server configurato (funzione Supabase `lumen-auth`) gestisce registrazione,
/// attivazione da parte dell'admin e ruoli. Senza server funziona solo l'account amministratore locale.
@MainActor
@Observable
final class AuthStore {
    private enum Keys {
        static let server = "lumen.authServerURL"
        static let user = "lumen.currentUser"
        static let localAdminHash = "lumen.localAdminHash"
        static let token = "lumen.authToken"
        static let mustChange = "lumen.mustChangePassword"
    }

    var user: AppUser? = nil
    var isRestoring = true
    /// La password è quella predefinita (o troppo corta): va cambiata prima di usare l'app.
    var mustChangePassword = false
    var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: Keys.server) } }
    /// Server incluso nell'app: in quel caso non si può cambiare né usare l'accesso locale.
    let bundledServer: String
    var canChangeServer: Bool { bundledServer.isEmpty }

    var isLoggedIn: Bool { user != nil }
    var isAdmin: Bool { user?.isAdmin == true }
    var hasServer: Bool { normalizedServer != nil }

    init() {
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "AuthServerURL") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        bundledServer = bundled.hasPrefix("http") ? bundled : ""
        // Con il server incluso nell'app si usa sempre quello: prima bastava svuotare l'indirizzo
        // dalle impostazioni per entrare come admin locale con admin/admin.
        serverURL = bundledServer.isEmpty ? (UserDefaults.standard.string(forKey: Keys.server) ?? "") : bundledServer
        // Utente salvato nel portachiavi (prima nelle preferenze, modificabili da un backup)
        if let json = Keychain.read(Keys.user), let saved = try? JSONDecoder().decode(AppUser.self, from: Data(json.utf8)) {
            user = saved
        } else if let data = UserDefaults.standard.data(forKey: Keys.user),
                  let saved = try? JSONDecoder().decode(AppUser.self, from: data) {
            user = saved
            if let json = String(data: data, encoding: .utf8) { Keychain.save(json, for: Keys.user) }
            UserDefaults.standard.removeObject(forKey: Keys.user)
        }
        if user?.id == "local-admin", !bundledServer.isEmpty { user = nil; Keychain.delete(Keys.user) }
        mustChangePassword = UserDefaults.standard.bool(forKey: Keys.mustChange)
    }

    private var normalizedServer: String? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("http") else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: Sessione

    /// All'avvio verifica che il token sia ancora valido e che l'account sia ancora attivo.
    func restore() async {
        defer { isRestoring = false }
        guard user != nil else { return }
        guard hasServer else {
            if user?.id != "local-admin" { signOut() }
            return
        }
        guard Keychain.read(Keys.token) != nil else { signOut(); return }
        do {
            let response: UserEnvelope = try await request("/me", method: "GET", auth: true)
            setUser(response.user)
        } catch let error as AuthError {
            if case .server = error { signOut() }
        } catch {
            // Offline: resta l'ultima sessione nota.
        }
    }

    func login(username: String, password: String) async throws {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hasServer else {
            guard name == "admin", Self.sha(password) == localAdminHash else { throw AuthError.invalidCredentials }
            setUser(AppUser(id: "local-admin", username: "admin", email: "pasquale.priore94@gmail.com",
                            role: "admin", approved: true))
            return
        }
        let response: LoginResponse = try await request("/login", body: ["username": name, "password": password])
        Keychain.save(response.token, for: Keys.token)
        setUser(response.user)
        setMustChange(response.mustChangePassword ?? false)
    }

    func register(username: String, email: String, password: String) async throws -> String {
        guard hasServer else { throw AuthError.noServer }
        let response: RegisterResponse = try await request("/register", body: [
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "password": password,
        ])
        return response.message
    }

    private struct ApprovalResponse: Decodable { let status: String; let username: String }

    /// Conferma il link di attivazione ricevuto via email (aperto nell'app). Restituisce lo username.
    func confirmApproval(token: String, reject: Bool) async throws -> String {
        guard hasServer else { throw AuthError.noServer }
        let r: ApprovalResponse = try await request("/approve", body: ["token": token, "action": reject ? "reject" : "approve"])
        return r.username
    }

    func changePassword(old: String, new: String) async throws {
        guard new.count >= 8 else { throw AuthError.server("La nuova password deve avere almeno 8 caratteri.") }
        if !hasServer {
            guard Self.sha(old) == localAdminHash else { throw AuthError.server("La password attuale non è corretta.") }
            UserDefaults.standard.set(Self.sha(new), forKey: Keys.localAdminHash)
            setMustChange(false)
            return
        }
        let r: OkResponse = try await request("/password", body: ["oldPassword": old, "newPassword": new], auth: true)
        // Il server emette un nuovo token: quelli precedenti non valgono più
        if let token = r.token { Keychain.save(token, for: Keys.token) }
        setMustChange(false)
    }

    private func setMustChange(_ value: Bool) {
        mustChangePassword = value
        UserDefaults.standard.set(value, forKey: Keys.mustChange)
    }

    func signOut() {
        Keychain.delete(Keys.token)
        Keychain.delete(Keys.user)
        UserDefaults.standard.removeObject(forKey: Keys.user)
        setMustChange(false)
        user = nil
    }

    // MARK: Amministrazione utenti

    func listUsers() async throws -> [AppUser] {
        guard hasServer else { throw AuthError.noServer }
        let response: UsersResponse = try await request("/users", method: "GET", auth: true)
        return response.users
    }

    @discardableResult
    func perform(_ action: String, on target: AppUser, newPassword: String? = nil) async throws -> AppUser {
        var body = ["action": action]
        if let newPassword { body["newPassword"] = newPassword }
        let response: UserEnvelope = try await request("/users/\(target.id)", body: body, auth: true)
        return response.user
    }

    func delete(_ target: AppUser) async throws {
        let _: OkResponse = try await request("/users/\(target.id)", method: "DELETE", auth: true)
    }

    // MARK: Interni

    private var localAdminHash: String {
        UserDefaults.standard.string(forKey: Keys.localAdminHash) ?? Self.sha("admin")
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func setUser(_ u: AppUser) {
        user = u
        if let data = try? JSONEncoder().encode(u), let json = String(data: data, encoding: .utf8) {
            Keychain.save(json, for: Keys.user)
        }
    }

    private struct LoginResponse: Decodable { let token: String; let user: AppUser; let mustChangePassword: Bool? }
    private struct RegisterResponse: Decodable { let message: String }
    private struct UserEnvelope: Decodable { let user: AppUser }
    private struct UsersResponse: Decodable { let users: [AppUser] }
    private struct OkResponse: Decodable { let ok: Bool?; let token: String? }
    private struct ErrorResponse: Decodable { let error: String }

    private func request<T: Decodable>(_ path: String, method: String = "POST",
                                       body: [String: String]? = nil, auth: Bool = false) async throws -> T {
        guard let base = normalizedServer, let url = URL(string: base + path) else { throw AuthError.noServer }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let token = Keychain.read(Keys.token) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let e = try? JSONDecoder().decode(ErrorResponse.self, from: data) { throw AuthError.server(e.error) }
            throw AuthError.server("Errore del server (\(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Salvataggio minimo del token nel portachiavi di iOS.
enum Keychain {
    private static let service = "app.lumen.auth"

    static func save(_ value: String, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            // Solo su questo iPhone (non finisce nei backup né su altri dispositivi)
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
