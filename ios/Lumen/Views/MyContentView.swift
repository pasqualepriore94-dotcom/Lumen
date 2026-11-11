import SwiftUI

/// "I miei contenuti": ogni utente (non solo l'amministratore) può aggiungere le proprie playlist
/// da link o file .m3u e gestire ciò che ha importato. Tutto resta su questo telefono.
struct MyContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var job = ImportJob.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        LinkImportView()
                    } label: {
                        HStack {
                            Label("Aggiungi contenuto da link o file", systemImage: "link.badge.plus")
                            Spacer()
                            if job.isRunning {
                                Text("\(Int(job.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            } else if job.phase == .ready {
                                Text("Pronti").font(.caption.bold()).foregroundStyle(app.accent)
                            }
                        }
                    }
                    NavigationLink {
                        UnmatchedContentView()
                    } label: {
                        Label("Contenuti non abbinati", systemImage: "questionmark.folder")
                    }
                    NavigationLink {
                        LinkedContentView()
                    } label: {
                        HStack {
                            Label("Gestisci contenuti caricati", systemImage: "list.bullet.rectangle")
                            Spacer()
                            let n = LinkLibrary.shared.matchedItems.count + LinkLibrary.shared.items.count
                            if n > 0 { Text("\(n)").foregroundStyle(.secondary) }
                        }
                    }
                } header: {
                    Text("Le tue playlist")
                } footer: {
                    Text("Incolla il link di una playlist o scegli un file .m3u: Lumen trova film, serie e dirette, li abbina alle schede del catalogo e li rende riproducibili. Le playlist e i contenuti restano solo su questo telefono. Usa solo playlist di contenuti che hai il diritto di guardare.")
                }
            }
            .navigationTitle("I miei contenuti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() } } }
            .navigationDestination(isPresented: $job.openRequested) { LinkImportView() }
        }
        .preferredColorScheme(.dark)
    }
}
