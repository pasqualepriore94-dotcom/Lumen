#!/usr/bin/env bash
# Carica file pubblici (IPA, sorgente SideStore, configurazione) nel bucket "lumen" di Supabase Storage.
# Serve perché il repository è privato: i link di GitHub richiederebbero il login.
# Uso: publish_supabase.sh <percorso-nel-bucket> <file-locale> <content-type> [<percorso> <file> <type> ...]
# Richiede: SUPABASE_ACCESS_TOKEN, PROJECT_REF
set -euo pipefail
if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ] || [ -z "${PROJECT_REF:-}" ]; then
  echo "::warning::Secret Supabase assenti: salto la pubblicazione su Storage."; exit 0
fi
KEY=$(curl -sf -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true" | python3 -c '
import sys, json
keys = json.load(sys.stdin)
pick = [k for k in keys if k.get("name") == "service_role"] or [k for k in keys if k.get("type") == "secret"]
print(pick[0]["api_key"] if pick else "")')
[ -n "$KEY" ] || { echo "::error::Chiave service_role non trovata"; exit 1; }
echo "::add-mask::$KEY"
BASE="https://$PROJECT_REF.supabase.co/storage/v1"
AUTH=(-H "apikey: $KEY")
case "$KEY" in eyJ*) AUTH+=(-H "Authorization: Bearer $KEY");; esac
# Bucket pubblico (se esiste già la richiesta fallisce senza problemi)
curl -s -X POST "$BASE/bucket" "${AUTH[@]}" -H "Content-Type: application/json" \
  -d '{"id":"lumen","name":"lumen","public":true}' > /dev/null || true
while [ $# -ge 3 ]; do
  DEST="$1"; FILE="$2"; TYPE="$3"; shift 3
  CODE=$(curl -s -o /tmp/upload.out -w "%{http_code}" -X POST "$BASE/object/lumen/$DEST" "${AUTH[@]}" \
    -H "x-upsert: true" -H "Content-Type: $TYPE" -H "cache-control: max-age=30" --data-binary @"$FILE")
  if [ "$CODE" != "200" ]; then echo "::error::Upload di $DEST fallito ($CODE): $(cat /tmp/upload.out)"; exit 1; fi
  echo "Pubblicato: https://$PROJECT_REF.supabase.co/storage/v1/object/public/lumen/$DEST"
done
