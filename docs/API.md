# Contratto API per le sorgenti di Lumen

Ogni sorgente "API personalizzata" deve esporre cinque endpoint HTTP(S) che rispondono in JSON.
I percorsi sono configurabili dal pannello amministratore (web o in-app); questi sono i valori predefiniti:

| Funzione       | Percorso predefinito                         | Obbligatorio |
|----------------|----------------------------------------------|--------------|
| Home           | `GET /home`                                  | sì           |
| Ricerca        | `GET /search?q={query}`                      | sì           |
| Dettaglio      | `GET /titles/{id}`                           | sì           |
| Flussi video   | `GET /titles/{id}/streams?episode={episode}` | sì           |
| Clip verticali | `GET /clips`                                 | no           |

Segnaposto: `{query}` testo cercato, `{id}` id del titolo, `{episode}` id dell'episodio (vuoto per i film).
Un percorso può anche essere un URL completo (`https://…`), utile se gli endpoint stanno su host diversi.

Le intestazioni configurate (per esempio `Authorization: Bearer <token>` o `X-API-Key: <chiave>`) vengono
inviate a ogni richiesta. Per una sorgente statica (file JSON su GitHub Pages, S3 e simili) bastano percorsi
come `/home.json`, `/titles/{id}.json`, `/streams/{id}{episode}.json`.

La decodifica è tollerante: campi sconosciuti vengono ignorati, numeri e stringhe sono intercambiabili per
`id`, `year`, `rank`, e un elemento malformato in una lista viene saltato invece di far fallire tutta la pagina.

---

## Oggetto `Title`

```json
{
  "id": "sintel",                       // obbligatorio
  "title": "Sintel",                    // obbligatorio
  "kind": "movie",                      // "movie" | "series"
  "poster": "https://…/poster.jpg",     // verticale 2:3
  "backdrop": "https://…/wide.jpg",     // orizzontale 16:9
  "overview": "Trama breve…",
  "year": 2010,
  "tags": ["Fantasy", "Avventura"],     // mostrati come "Fantasy • Avventura"
  "badge": "Nuova stagione",            // etichetta colorata sulla locandina
  "rank": 1,                            // per le righe "top10"
  "rating": "13+"                       // classificazione per età
}
```

## `GET /home`

```json
{
  "hero": { …Title… },
  "sections": [
    { "id": "nuovi", "title": "Altri titoli da guardare", "style": "poster", "items": [ …Title… ] },
    { "id": "top",   "title": "La Top 10 di oggi",        "style": "top10",  "items": [ …Title con rank… ] }
  ]
}
```

`style` decide l'aspetto della riga: `poster` (locandine normali), `large` (locandine grandi),
`top10` (numeri giganti accanto alle locandine), `wide` (miniature 16:9 con titolo).
Le righe "Continua a guardare" e "La mia lista" le genera l'app da sola.

## `GET /search?q=…`

Un array di `Title`, oppure `{ "results": [ …Title… ] }`.

## `GET /titles/{id}`

```json
{
  "item": { …Title… },
  "duration": 5400,                     // secondi, per i film
  "cast": ["Nome Cognome", "…"],
  "seasons": [
    {
      "id": "s1", "number": 1, "title": "Stagione 1",
      "episodes": [
        { "id": "s1e1", "number": 1, "title": "Pilota", "overview": "…",
          "still": "https://…/s1e1.jpg", "duration": 2700 }
      ]
    }
  ]
}
```

In alternativa i campi del titolo possono stare al primo livello (senza `item`).

## `GET /titles/{id}/streams?episode={episode}`

Un array, oppure `{ "streams": [ … ] }`. Viene usato il primo elemento.

```json
{
  "streams": [
    { "url": "https://cdn.esempio.it/sintel/master.m3u8", "quality": "Auto",
      "headers": { "Authorization": "Bearer …" } }
  ]
}
```

Formati supportati dal player nativo (AVPlayer): HLS (`.m3u8`) e MP4/MOV. I contenuti protetti da DRM
FairPlay richiedono un'integrazione dedicata, non inclusa in questa beta. `headers` è facoltativo e viene applicato alle richieste video.

## `GET /clips`

```json
[
  { "id": "c1", "video": "https://…/clip.mp4", "item": { …Title… } }
]
```

Le clip si riproducono in loop, senza controlli, nella scheda **Clip**; toccare la miniatura apre la scheda del titolo.

---

## Server di prova

`tools/mock_api.py` implementa questo contratto servendo il catalogo demo:

```bash
python3 tools/mock_api.py                    # http://0.0.0.0:8080
MOCK_TOKEN=segreto python3 tools/mock_api.py # richiede "Authorization: Bearer segreto"
```

Nell'app: Admin → Aggiungi API → indirizzo `http://<IP del computer>:8080`, poi "Prova connessione".
