#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 OCamlPro <contact@ocamlpro.com>
#
# Vérifie le schéma JSON du format de manifeste contre les fichiers livrés et
# le catalogue des erreurs :
#   - tout manifeste livré (exemples, providers, profils, bundles) doit être
#     accepté ;
#   - les cas d'étage 1 du catalogue que la syntaxe suffit à refuser doivent
#     l'être. E001 (YAML invalide) ne concerne pas le schéma ; les autres codes
#     d'étage 1 relèvent de vérifications que JSON Schema n'exprime pas
#     (doublons, comparaisons entre champs, références de gabarits).
#
# Usage, depuis la racine du dépôt : python3 -I tools/check-schema.py

import glob
import json
import sys

import jsonschema
import yaml

SCHEMA = "doc/schema/hamac-manifest-1.1.schema.json"
ACCEPTED = sorted(
    glob.glob("examples/**/*.yml", recursive=True)
    + glob.glob("providers/*.yml")
    + glob.glob("provisioning-profiles/*.yaml")
    + glob.glob("templates/bundles/*/bundle.yaml")
)
REFUSED_CODES = ["E002", "E003", "E004", "E005", "E006", "E007", "E011"]
REFUSED = sorted(
    f for code in REFUSED_CODES
    for f in glob.glob(f"tests/hamac/catalogue.t/cases/{code}-*/manifest.yml")
)


def main():
    with open(SCHEMA) as fh:
        schema = json.load(fh)
    jsonschema.Draft202012Validator.check_schema(schema)
    validator = jsonschema.Draft202012Validator(schema)
    failures = 0
    for path in ACCEPTED:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
        errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
        if errors:
            failures += 1
            e = errors[0]
            where = ".".join(str(p) for p in e.path) or "(root)"
            print(f"FAIL  {path}: {where}: {e.message}")
        else:
            print(f"ok    {path}")
    for path in REFUSED:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
        if validator.is_valid(doc):
            failures += 1
            print(f"FAIL  {path}: accepted, should be refused")
        else:
            print(f"ok    {path} (refused)")
    if len(REFUSED) != len(REFUSED_CODES):
        failures += 1
        print(f"FAIL  expected {len(REFUSED_CODES)} refused cases, found {len(REFUSED)}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
