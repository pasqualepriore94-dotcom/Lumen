"""Server API di esempio che implementa il contratto descritto in docs/API.md.

Serve il catalogo demo (film open e flussi di test) via HTTP, così puoi provare
l'aggancio di un'API personalizzata dall'admin dell'app o dal pannello web.

Uso:
    python3 tools/mock_api.py            # http://0.0.0.0:8080
    python3 tools/mock_api.py 9000       # porta diversa

Nell'app: Admin → Aggiungi API → indirizzo base  http://<IP-del-computer>:8080
(iPhone e computer sulla stessa rete Wi-Fi). Lascia gli endpoint predefiniti.
Per provare l'autenticazione avvia con  MOCK_TOKEN=segreto python3 tools/mock_api.py
e aggiungi l'intestazione  Authorization: Bearer segreto.
"""
import json
import os
import sys
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = json.load(open(os.path.join(ROOT, "ios/Lumen/Resources/demo_catalog.json"), encoding="utf-8"))
TOKEN = os.environ.get("MOCK_TOKEN")
# Le immagini bundle:// esistono solo dentro l'app; per un'API reale usa URL https.


def all_items():
    seen, out = set(), []
    for it in [CATALOG["home"]["hero"]] + [i for s in CATALOG["home"]["sections"] for i in s["items"]]:
        if it["id"] not in seen:
            seen.add(it["id"]); out.append(it)
    return out


def fold(s):
    return unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204, {})

    def do_GET(self):
        if TOKEN and self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self._send(401, {"error": "token mancante o errato"})
        url = urlparse(self.path)
        parts = [unquote(p) for p in url.path.strip("/").split("/") if p]
        q = parse_qs(url.query)

        if parts == ["home"]:
            return self._send(200, CATALOG["home"])
        if parts == ["search"]:
            term = fold(q.get("q", [""])[0])
            res = [i for i in all_items() if term in fold(i["title"] + " " + i.get("overview", "") + " " + " ".join(i.get("tags", [])))]
            return self._send(200, {"results": res})
        if parts == ["clips"]:
            return self._send(200, CATALOG["clips"])
        if len(parts) == 2 and parts[0] == "titles":
            d = CATALOG["details"].get(parts[1])
            return self._send(200, d) if d else self._send(404, {"error": "titolo non trovato"})
        if len(parts) == 3 and parts[0] == "titles" and parts[2] == "streams":
            ep = q.get("episode", [""])[0]
            s = CATALOG["streams"].get(ep) or CATALOG["streams"].get(parts[1])
            return self._send(200, {"streams": s}) if s else self._send(404, {"error": "nessun flusso"})
        self._send(404, {"error": "endpoint sconosciuto"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"API di esempio su http://0.0.0.0:{port}  (token: {'sì' if TOKEN else 'no'})")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
