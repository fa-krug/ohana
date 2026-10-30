#!/usr/bin/env python3
"""Builds Ohana/Resources/Localizable.xcstrings from the module translations.

Usage: scripts/merge-localizations.py [--check] [DERIVED_DATA]

Localization/*.de.json map String Catalog keys (the English literal, interpolations as %@ /
%lld / %lf) to German. With DERIVED_DATA (the -derivedDataPath of a build), the keys the
compiler extracted (*.stringsdata) are added too, and the script lists those without a German
translation. --check writes nothing and fails when a key has no German or the catalog isn't
up to date (CI).

A value is a string, or for plurals an object of plural categories, e.g.
{"one": "%lld day", "other": "%lld days"}. When the English text needs plural forms too, the
value is an object by language: {"en": {"one": "%lld day", "other": "%lld days"},
"de": {"one": "%lld Tag", "other": "%lld Tage"}} ("de" a string or plural object as above).
"""
import glob
import json
import os
import sys

CHECK = "--check" in sys.argv
ARGS = [a for a in sys.argv[1:] if a != "--check"]
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
if ARGS:
    for path in glob.glob(os.path.join(ARGS[0], "**", "*.stringsdata"), recursive=True):
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

# Translated keys stay even when this build didn't extract them (iOS-only strings in a Mac build).
LANGUAGES = ("en", "de")


def localization(value):
    """A string or an object of plural categories as one language's catalog entry."""
    if isinstance(value, dict):
        plural = {k: {"stringUnit": {"state": "translated", "value": v}} for k, v in value.items()}
        return {"variations": {"plural": plural}}
    return {"stringUnit": {"state": "translated", "value": value}}


strings = {}
for key in sorted(keys | set(translations)):
    entry = {}
    if key in translations:
        value = translations[key]
        if isinstance(value, dict) and any(lang in value for lang in LANGUAGES):
            # By language: {"en": …, "de": …}.
            entry["localizations"] = {lang: localization(value[lang]) for lang in LANGUAGES if lang in value}
        else:
            entry["localizations"] = {"de": localization(value)}
    strings[key] = entry

text = json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
if CHECK:
    with open(CATALOG, encoding="utf-8") as f:
        current = f.read()
    problems = (len(missing) if ARGS else 0) + (current != text)
    if current != text:
        print("Localizable.xcstrings is out of date: run scripts/merge-localizations.py", file=sys.stderr)
    sys.exit(1 if problems else 0)
with open(CATALOG, "w", encoding="utf-8") as f:
    f.write(text)
print(f"wrote {CATALOG}", file=sys.stderr)
