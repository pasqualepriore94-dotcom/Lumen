# Lumen (beta)

App iOS in SwiftUI per lo streaming video, con interfaccia scura a schede (Home, Clip, Cerca, Profilo),
player nativo e sorgenti di contenuti agganciabili da un pannello amministratore, sia web sia nascosto nell'app.

> Usa solo sorgenti e contenuti di cui hai i diritti: il tuo server, Jellyfin/Plex con le tue librerie,
> un servizio con licenza, contenuti open o di pubblico dominio. L'app è un player generico e non include
> collegamenti a siti di terze parti.

## Cosa c'è dentro

```
ios/                 progetto iOS (generato con XcodeGen da project.yml)
  Lumen/App          avvio app, barra schede flottante
  Lumen/Models       modelli dati e configurazione
  Lumen/Services     provider (demo + API), stato, libreria, riproduzione
  Lumen/Views        Home, Clip, Cerca, Profilo, Dettaglio, Admin
  Lumen/Resources    catalogo demo, grafiche, icona
admin/index.html     pannello amministratore web (pubblicato su GitHub Pages)
config/app-config.json  configurazione letta dall'app all'avvio
docs/API.md          contratto JSON che ogni API deve rispettare
tools/mock_api.py    server API di prova che implementa il contratto
tools/make_demo.py   rigenera grafiche e catalogo demo
.github/workflows    build IPA + pubblicazione pannello admin
```

### Funzioni dell'app

- **Home**: hero con "Riproduci" e "La mia lista", filtri Serie / Film / Novità / Categorie, righe di locandine
  (normali, grandi, Top 10 con numeri, 16:9), badge "Nuova stagione"/"Aggiunto di recente",
  "Continua a guardare" con barra di avanzamento, "La mia lista".
- **Clip**: feed verticale a schermo intero con autoplay in loop, audio on/off, aggiungi alla lista, condividi,
  barra di avanzamento e miniatura che apre la scheda.
- **Cerca**: barra di ricerca con "Annulla", elenco "Serie TV e film consigliati", griglia risultati.
- **Scheda titolo**: trama, cast, stagioni ed episodi, riprendi da dove eri rimasto.
- **Player**: AVPlayer nativo (HLS e MP4), Picture in Picture, AirPlay, ripresa automatica.
- **Il mio Lumen**: profilo, cronologia, lista, impostazioni, accesso admin nascosto.

## 1 · Compilare su GitHub

1. Crea un repository su GitHub (anche privato) e carica tutto il contenuto di questa cartella.
2. Vai su **Actions** → **Build iOS (IPA non firmata)** → **Run workflow** (parte anche a ogni push su `ios/`).
3. A fine build (circa 10 minuti) scarica l'artefatto **Lumen-unsigned-ipa**.

L'IPA non è firmata: per installarla sul tuo iPhone usa **Sideloadly** o **AltStore** con il tuo Apple ID
(account gratuito: l'app scade dopo 7 giorni e va reinstallata), oppure firmala con un account sviluppatore.
Per TestFlight servono un account Apple Developer (99 €/anno) e i certificati come secret del repository.

Per compilare in locale su Mac: `brew install xcodegen && cd ios && xcodegen generate && open Lumen.xcodeproj`.

## 2 · Pannello amministratore web

1. Nel repository: **Settings → Pages → Source: GitHub Actions**.
2. Il workflow **Pubblica pannello admin** lo mette online su `https://<utente>.github.io/<repo>/`.
3. Crea un token: **GitHub → Settings → Developer settings → Fine-grained tokens**, accesso solo a questo
   repository, permesso **Contents: Read and write**.
4. Apri il pannello, inserisci token e repository, **Carica da GitHub**, modifica, **Salva su GitHub**.

Il pannello scrive `config/app-config.json`. La build imposta automaticamente nell'app l'URL raw di quel file,
quindi l'app scarica le modifiche al prossimo avvio (o con *Aggiorna catalogo* nel profilo).
Se il repository è privato, l'URL raw non è leggibile dall'app: in quel caso pubblica il file altrove
(per esempio copiandolo in `admin/` così finisce su Pages) e inserisci quell'URL nell'admin dell'app.

## 3 · Pannello amministratore nascosto nell'app

**Il mio Lumen** → tocca **7 volte** la scritta della versione in fondo → PIN (predefinito **0000**, cambialo subito).

Da qui puoi: scegliere la sorgente attiva, aggiungere/modificare API (indirizzo, endpoint, intestazioni),
provare la connessione, impostare l'URL della configurazione remota, cambiare nome e colore, esportare
o importare la configurazione in JSON, cambiare PIN.

Le intestazioni con token o chiavi inserite qui restano sul dispositivo: una sincronizzazione dal pannello web
non le cancella se la configurazione remota non ne contiene.

## 4 · Agganciare un'API

Ogni API deve rispondere nel formato di [`docs/API.md`](docs/API.md) (home, ricerca, dettaglio, flussi, clip).
Se il tuo servizio ha un formato diverso, la via più semplice è un piccolo adattatore lato server che
traduce le sue risposte in questo contratto. Per provare subito:

```bash
python3 tools/mock_api.py   # poi nell'app: Admin → Aggiungi API → http://<IP del Mac/PC>:8080
```

## Catalogo demo

La sorgente "Catalogo demo" è inclusa nell'app e usa cortometraggi open della Blender Foundation
(Big Buck Bunny, Sintel, Tears of Steel, Elephants Dream, licenza Creative Commons) e flussi di test pubblici
(Apple, Mux, Google). Le locandine sono grafiche originali generate da `tools/make_demo.py`.

## Note sulla beta

- Download offline: non ancora implementati (l'icona apre un segnaposto).
- Richiede iOS 17 o successivo.
- `NSAllowsArbitraryLoads` è attivo per permettere server di prova in `http://`; per la versione definitiva
  conviene usare solo HTTPS e rimuoverlo.
