import SwiftUI

/// Pannello amministratore: visibile solo agli account con ruolo admin (Profilo → Amministrazione).
struct AdminView: View {
    @Environment(AppState.self) private var app
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var confirmReset = false
    @State private var importText = ""
    @State private var showImport = false
    @State private var importError: String?

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        UsersAdminView()
                    } label: {
                        Label("Utenti e richieste di accesso", systemImage: "person.2.fill")
                    }
                    LabeledContent("Server account", value: auth.hasServer ? "Collegato" : "Non configurato")
                        .font(.footnote)
                } header: {
                    Text("Account")
                } footer: {
                    Text("Le nuove registrazioni arrivano via email all'amministratore con il link di attivazione e compaiono anche qui.")
                }

                Section {
                    NavigationLink {
                        LinkImportView()
                    } label: {
                        Label("Aggiungi contenuto da link", systemImage: "link.badge.plus")
                    }
                } header: {
                    Text("Da link")
                } footer: {
                    Text("Incolla un link: l'app trova i video presenti e ti propone il play.")
                }

                Section {
                    Picker("Sorgente attiva", selection: Binding(
                        get: { app.activeProviderConfig?.id ?? "" },
                        set: { app.setActiveProvider($0) })) {
                        ForEach(app.config.providers.filter(\.isUsable)) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                } header: {
                    Text("Contenuti")
                }

                Section {
                    ForEach(app.config.providers) { provider in
                        NavigationLink {
                            ProviderEditor(original: provider)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.name)
                                    Text(provider.type == .custom ? provider.baseURL
                                         : (provider.type == .tmdb && !provider.isUsable ? "Manca la chiave TMDB" : provider.type.label))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if provider.id == app.activeProviderConfig?.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(app.accent)
                                } else if !provider.enabled {
                                    Text("Disattivata").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { app.config.providers[$0].id }
                        for id in ids { app.deleteProvider(id: id) }
                    }
                    NavigationLink {
                        ProviderEditor(original: .newCustom(), isNew: true)
                    } label: {
                        Label("Aggiungi API", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("API agganciate")
                } footer: {
                    Text("Ogni API deve rispondere nel formato descritto in docs/API.md. Le intestazioni (token, chiavi) restano solo su questo dispositivo se la configurazione remota non le contiene.")
                }

                Section {
                    TextField("https://raw.githubusercontent.com/…/app-config.json", text: $app.remoteConfigURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    Toggle("Sincronizza all'avvio", isOn: $app.autoSync)
                    Button {
                        Task { await app.syncRemote() }
                    } label: {
                        HStack {
                            Text("Sincronizza ora")
                            Spacer()
                            if app.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(app.remoteConfigURL.isEmpty || app.isSyncing)
                    if let msg = app.syncMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                    if let last = app.lastSync {
                        LabeledContent("Ultima sincronizzazione", value: last.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
                } header: {
                    Text("Configurazione remota (pannello web)")
                } footer: {
                    Text("Le modifiche salvate dal pannello web vengono scaricate da questo indirizzo. Una sincronizzazione sostituisce le impostazioni locali.")
                }

                Section("Aspetto") {
                    TextField("Nome app", text: $app.config.appName)
                    ColorPicker("Colore principale", selection: Binding(
                        get: { app.accent },
                        set: { app.config.accentHex = $0.hexString }), supportsOpacity: false)
                }

                Section {
                    ShareLink(item: app.config.withoutSecrets.jsonString()) {
                        Label("Esporta configurazione (senza segreti)", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        importText = ""
                        importError = nil
                        showImport = true
                    } label: {
                        Label("Importa configurazione JSON", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Import / export")
                }

                Section {
                    Button("Ripristina configurazione predefinita", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Amministrazione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .confirmationDialog("Ripristinare?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Ripristina", role: .destructive) { app.resetToDefaults() }
            } message: {
                Text("Le API aggiunte su questo dispositivo verranno rimosse.")
            }
            .sheet(isPresented: $showImport) { importSheet }
        }
        .preferredColorScheme(.dark)
    }

    private var importSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Incolla il JSON esportato dal pannello web o da un altro dispositivo.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $importText)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                if let importError {
                    Text(importError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Importa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { showImport = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importa") {
                        do {
                            let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(importText.utf8))
                            app.config = cfg
                            app.reload()
                            showImport = false
                        } catch {
                            importError = "JSON non valido: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct HeaderPair: Identifiable, Hashable {
    let id = UUID()
    var key: String
    var value: String
}

struct ProviderEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let original: ProviderConfig
    var isNew = false

    @State private var draft: ProviderConfig
    @State private var headers: [HeaderPair]
    @State private var testResult: String?
    @State private var testing = false

    init(original: ProviderConfig, isNew: Bool = false) {
        self.original = original
        self.isNew = isNew
        _draft = State(initialValue: original)
        _headers = State(initialValue: original.headers
            .sorted { $0.key < $1.key }
            .map { HeaderPair(key: $0.key, value: $0.value) })
    }

    var body: some View {
        Form {
            Section("Generale") {
                TextField("Nome", text: $draft.name)
                Picker("Tipo", selection: $draft.type) {
                    ForEach(ProviderType.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Attiva", isOn: $draft.enabled)
            }

            if draft.type == .tmdb {
                Section {
                    SecureField("Chiave API TMDB (v3) o token di lettura (v4)", text: optionBinding("tmdbKey"))
                    SecureField("Chiave OMDb per il voto IMDb (facoltativa)", text: optionBinding("omdbKey"))
                    TextField("Lingua (es. it-IT)", text: optionBinding("language"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Paese per 'Dove guardarlo' (es. IT)", text: optionBinding("region"))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                } header: {
                    Text("Catalogo TMDB")
                } footer: {
                    Text("Chiave gratuita su themoviedb.org → Impostazioni → API. La chiave OMDb (omdbapi.com) è gratuita fino a 1.000 richieste al giorno e aggiunge il voto IMDb nella scheda del titolo.")
                }
            }

            if draft.type == .custom {
                Section {
                    TextField("https://api.esempio.it", text: $draft.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Indirizzo base")
                }

                Section {
                    pathField("Home", $draft.paths.home)
                    pathField("Ricerca", $draft.paths.search)
                    pathField("Dettaglio", $draft.paths.detail)
                    pathField("Flussi video", $draft.paths.streams)
                    pathField("Clip", $draft.paths.clips)
                    pathField("Catalogo", $draft.paths.browse)
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text("Segnaposto: {query}, {id}, {episode}; per Catalogo {kind}, {genre}, {sort}, {page}. Lascia vuoto ciò che la tua API non offre.")
                }

                Section {
                    ForEach($headers) { $pair in
                        HStack {
                            TextField("Nome", text: $pair.key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .frame(maxWidth: 130)
                            Divider()
                            SecureField("Valore", text: $pair.value)
                        }
                        .font(.footnote)
                    }
                    .onDelete { headers.remove(atOffsets: $0) }
                    Button {
                        headers.append(HeaderPair(key: "Authorization", value: ""))
                    } label: {
                        Label("Aggiungi intestazione", systemImage: "plus")
                    }
                } header: {
                    Text("Intestazioni HTTP")
                } footer: {
                    Text("Es. Authorization: Bearer <token> oppure X-API-Key: <chiave>.")
                }
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Prova connessione")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                if let testResult {
                    Text(testResult).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Button(isNew ? "Aggiungi" : "Salva modifiche") { save() }
                    .bold()
                if !isNew && finalConfig.isUsable {
                    Button("Salva e usa come sorgente attiva") {
                        save()
                        app.setActiveProvider(draft.id)
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Nuova API" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func optionBinding(_ key: String) -> Binding<String> {
        Binding(get: { draft.options[key] ?? "" }, set: { draft.options[key] = $0 })
    }

    private func pathField(_ label: String, _ binding: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(label, text: binding)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
        }
    }

    private var finalConfig: ProviderConfig {
        var p = draft
        p.baseURL = p.baseURL.trimmingCharacters(in: .whitespaces)
        p.headers = Dictionary(headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
                               uniquingKeysWith: { _, last in last })
        return p
    }

    private func save() {
        app.upsert(finalConfig)
        dismiss()
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let provider = ProviderFactory.make(finalConfig)
        do {
            let feed = try await provider.home()
            var msg = "✅ Home OK: \(feed.sections.count) sezioni, \(feed.allItems.count) titoli."
            if !provider.capabilities.streams {
                msg += "\nℹ️ Catalogo informativo: trame, cast, voti e trailer (nessun video)."
            } else if let first = feed.allItems.first {
                do {
                    let streams = try await provider.streams(id: first.id, episodeId: nil)
                    msg += "\n✅ Flussi per «\(first.title)»: \(streams.count)."
                } catch {
                    if first.isSeries {
                        msg += "\nℹ️ «\(first.title)» è una serie: i flussi si chiedono per episodio."
                    } else {
                        msg += "\n⚠️ Flussi per «\(first.title)»: \(error.localizedDescription)"
                    }
                }
            }
            testResult = msg
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
