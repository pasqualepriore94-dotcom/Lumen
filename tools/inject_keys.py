#!/usr/bin/env python3
"""Copia la configurazione inserendo le chiavi API dai secret (TMDB_KEY, OMDB_KEY), se presenti.
Uso: inject_keys.py <config.json> <output.json>"""
import json, os, sys

src, dst = sys.argv[1], sys.argv[2]
cfg = json.load(open(src))
for p in cfg.get("providers", []):
    if p.get("type") == "tmdb":
        opts = p.setdefault("options", {})
        if os.environ.get("TMDB_KEY"): opts["tmdbKey"] = os.environ["TMDB_KEY"]
        if os.environ.get("OMDB_KEY"): opts["omdbKey"] = os.environ["OMDB_KEY"]
json.dump(cfg, open(dst, "w"), indent=2, sort_keys=True)
print("configurazione pronta:", dst)
