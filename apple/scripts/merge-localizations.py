#!/usr/bin/env python3
"""Builds Ohana/Resources/Localizable.xcstrings from the module translations.

Usage: scripts/merge-localizations.py [DERIVED_DATA]

Localization/*.de.json map String Catalog keys (the English literal, interpolations as %@ /
%lld / %lf) to German. With DERIVED_DATA (the -derivedDataPath of a build), the keys the
compiler extracted (*.stringsdata) are the catalog's keys, and the script lists those without
a German translation; without it, the keys of the JSON files are used.
"""
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Ohana", "Resources", "Localizable.xcstrings")

translations = {}
for path in sorted(glob.glob(os.path.join(ROOT, "Localization", "*.de.json"))):
    with open(path, encoding="utf-8") as f:
        for key, value in json.load(f).items():
            if key in translations and translations[key] != value:
                print(f"note: {os.path.basename(path)} translates {key!r} differently; keeping the first", file=sys.stderr)
                continue
            translations[key] = value

keys = set()
if len(sys.argv) > 1:
    for path in glob.glob(os.path.join(sys.argv[1], "**", "*.stringsdata"), recursive=True):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.add(entry["key"])
    missing = sorted(k for k in keys if k not in translations and any(c.isalpha() for c in k))
    for key in missing:
        print(f"missing: {key!r}", file=sys.stderr)
    print(f"{len(keys)} keys, {len(missing)} without German", file=sys.stderr)
else:
    keys = set(translations)

strings = {}
for key in sorted(keys | (set(translations) if len(sys.argv) <= 1 else set())):
    entry = {}
    if key in translations:
        entry["localizations"] = {"de": {"stringUnit": {"state": "translated", "value": translations[key]}}}
    strings[key] = entry

with open(CATALOG, "w", encoding="utf-8") as f:
    json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
print(f"wrote {CATALOG}", file=sys.stderr)
