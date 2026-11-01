# Lumen (beta)

App iOS in SwiftUI per film e serie, in stile **Liquid Glass**: schede Home, Clip, Cerca e Profilo,
catalogo completo da TMDB con trame, cast e voti, account utente con attivazione da parte dell'amministratore,
pannello admin nell'app e sul web.

> Per la riproduzione video usa solo sorgenti di cui hai i diritti: il tuo server, Jellyfin/Plex con le tue
> librerie, un servizio con licenza, contenuti open. TMDB fornisce informazioni e trailer, non i film.

## Cosa c'è dentro

```
ios/                       app iOS (XcodeGen: project.yml)
supabase/                  server account: tabella utenti + funzione lumen-auth (con test)
admin/index.html           pannello amministratore web (GitHub Pages)
config/app-config.json     configurazione letta dall'app (sorgenti, nome, colore)
docs/API.md                contratto JSON per agganciare un'API video personalizzata
tools/                     server API di prova, generatore del catalogo demo
.github/workflows          build IPA · pubblicazione pannello · pubblicazione server account
```

## Novità della 0.2

- **Liquid Glass** ovunque: barra delle schede, pulsanti, filtri, schede dei titoli, login, impostazioni.
  Su iOS 26 usa il vero materiale di sistema; su iOS 17–25 un vetro smerigliato equivalente.
- **Tastiera**: si chiude toccando un punto qualsiasi dello schermo.
- **Catalogo completo TMDB**: Home con tendenze, Top 10, popolari, più votati, generi; ricerca;
  **Esplora tutto il catalogo** con filtri per genere e ordinamento e scorrimento infinito;
  scheda titolo con voto TMDB e **voto IMDb** (con chiave OMDb), trama, generi, regia, cast con foto,
  stagioni ed episodi, trailer, "Disponibile su" (servizi in Italia).
- **Account**: accesso obbligatorio, registrazione con email di attivazione all'amministratore,
  ruoli utente/amministratore, gestione utenti in app e sul web, cambio password.

## 1 · Chiave TMDB (catalogo)

1. Crea un account gratuito su [themoviedb.org](https://www.themoviedb.org/) → Impostazioni → API → richiedi una chiave (uso personale).
2. Facoltativo, per il voto IMDb: chiave gratuita su [omdbapi.com](https://www.omdbapi.com/apikey.aspx).
3. Inseriscile nel pannello web (sezione API → Catalogo TMDB) e salva, oppure nell'app:
   Profilo → Amministrazione → Catalogo film e serie (TMDB).

Il catalogo di IMDb non può essere copiato (i dati sono protetti e i termini lo vietano): TMDB offre lo stesso
tipo di informazioni tramite un'API ufficiale, e OMDb aggiunge il voto IMDb in modo lecito.

## 2 · Server account (Supabase, gratuito)

1. Crea un progetto su [supabase.com](https://supabase.com).
2. **SQL Editor** → incolla ed esegui `supabase/migrations/20261101000000_lumen_users.sql`.
3. Crea un account su [resend.com](https://resend.com) **con l'email pasquale.priore94@gmail.com** e genera una API key
   (senza dominio verificato Resend può inviare solo all'email del proprio account: va bene, le email vanno all'admin).
4. Su Supabase → **Edge Functions → Secrets** aggiungi:
   - `JWT_SECRET` = una stringa casuale di almeno 32 caratteri
   - `ADMIN_EMAIL` = `pasquale.priore94@gmail.com`
   - `RESEND_API_KEY` = la chiave di Resend
5. Pubblica la funzione: dal Mac `supabase functions deploy lumen-auth --no-verify-jwt`, oppure in automatico con
   il workflow **Pubblica server account** (secret del repo: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`;
   il workflow crea anche la tabella).
6. L'URL del server è `https://<id-progetto>.supabase.co/functions/v1/lumen-auth`. Mettilo in
   **GitHub → Settings → Secrets and variables → Actions → Variables** come `AUTH_SERVER_URL`: la build lo inserisce nell'app.
   In alternativa si imposta dall'icona server nella schermata di accesso.

**Account amministratore iniziale: `admin` / `admin`** (creato al primo avvio del server, con email dell'admin).
Cambialo subito da Profilo → Cambia password: è una password debole e il repository la rende nota.

Flusso di registrazione: l'utente compila username, email e password → l'amministratore riceve un'email con
**Attiva account** / **Rifiuta** → finché non è attivato l'utente non può accedere. Le richieste compaiono anche
in Amministrazione → Utenti (app) e nella sezione Utenti del pannello web, dove puoi anche disattivare,
promuovere ad admin, reimpostare la password o eliminare.

Senza server configurato l'app funziona in modalità locale: solo `admin`/`admin`, registrazione disattivata.

Test del server: `deno test --no-check supabase/functions/lumen-auth/core_test.ts`.

## 3 · Compilare su GitHub

1. Carica tutto in un repository GitHub (anche privato).
2. **Actions → Build iOS (IPA non firmata) → Run workflow**. Usa il runner macOS 26 con Xcode 26, necessario per Liquid Glass.
3. Scarica l'artefatto **Lumen-unsigned-ipa** e installalo con Sideloadly o AltStore (Apple ID gratuito: va
   reinstallata ogni 7 giorni; con account sviluppatore si può usare TestFlight).

In locale su Mac: `brew install xcodegen && cd ios && xcodegen generate && open Lumen.xcodeproj` (Xcode 26).

## 4 · Pannello amministratore web

1. **Settings → Pages → Source: GitHub Actions**: il workflow lo pubblica su `https://<utente>.github.io/<repo>/`.
2. Sezione **Collegamento**: token GitHub *fine-grained* con permesso *Contents: Read and write* sul repo → salva
   sorgenti, chiavi, nome e colore in `config/app-config.json`, che l'app scarica all'avvio.
3. Sezione **Utenti**: URL del server account + credenziali admin → gestione registrazioni.

## 5 · Agganciare un'API video

Admin → Aggiungi API, secondo il contratto di [`docs/API.md`](docs/API.md). Per provare:
`python3 tools/mock_api.py` e indirizzo `http://<IP del computer>:8080`.

## Note

- Richiede iOS 17 o successivo; l'effetto Liquid Glass nativo compare da iOS 26.
- Download offline non ancora disponibili.
- `NSAllowsArbitraryLoads` è attivo per i server di prova in `http://`: per la versione definitiva usa solo HTTPS.
