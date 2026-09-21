#!/usr/bin/env python3
"""Build the merged Zumbo vocab starter file from seeds/packs/*.json.

Reads every pack in seeds/packs/, validates each one, merges them
(first pack wins on a duplicate `text` across packs), and writes the
merged term list to seeds/vocab-dev-starter.json and
Engine/Sources/VesperEngine/Resources/vocab-dev-starter.json.
"""

import glob
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
PACKS_DIR = os.path.join(SCRIPT_DIR, "packs")
OUTPUT_PATHS = [
    os.path.join(SCRIPT_DIR, "vocab-dev-starter.json"),
    os.path.join(
        REPO_ROOT, "Engine", "Sources", "VesperEngine", "Resources", "vocab-dev-starter.json"
    ),
]


def validate_pack(pack_id, terms):
    seen = set()
    for term in terms:
        text = term.get("text")
        if not text:
            raise ValueError(f"[{pack_id}] term missing 'text': {term}")
        if text in seen:
            raise ValueError(f"[{pack_id}] duplicate text within pack: {text}")
        seen.add(text)

        aliases = term.get("aliases")
        if not isinstance(aliases, list) or not aliases:
            raise ValueError(f"[{pack_id}] term '{text}' has no aliases list")
        for alias in aliases:
            if not isinstance(alias, str) or alias != alias.lower():
                raise ValueError(
                    f"[{pack_id}] term '{text}' has a non-lowercase alias: {alias!r}"
                )

        if "minSimilarity" in term and term["minSimilarity"] != 0.9:
            raise ValueError(
                f"[{pack_id}] term '{text}' has minSimilarity "
                f"{term['minSimilarity']!r}, only 0.9 is allowed"
            )


def main():
    pack_files = sorted(glob.glob(os.path.join(PACKS_DIR, "*.json")))
    if not pack_files:
        print(f"no packs found in {PACKS_DIR}", file=sys.stderr)
        sys.exit(1)

    merged = []
    seen_text_to_pack = {}
    cross_pack_duplicates = []
    per_pack_counts = []
    total_in_packs = 0

    for path in pack_files:
        with open(path) as f:
            data = json.load(f)

        pack_id = data.get("pack", os.path.splitext(os.path.basename(path))[0])
        terms = data.get("terms", [])
        validate_pack(pack_id, terms)

        per_pack_counts.append((pack_id, len(terms)))
        total_in_packs += len(terms)

        for term in terms:
            text = term["text"]
            if text in seen_text_to_pack:
                cross_pack_duplicates.append(
                    {
                        "text": text,
                        "kept_from": seen_text_to_pack[text],
                        "skipped_from": pack_id,
                    }
                )
                continue
            seen_text_to_pack[text] = pack_id
            term_with_pack = dict(term)
            term_with_pack["pack"] = pack_id
            merged.append(term_with_pack)

    output = {"terms": merged}

    for out_path in OUTPUT_PATHS:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "w") as f:
            json.dump(output, f, indent=1)
            f.write("\n")

    print("Per-pack counts:")
    for pack_id, count in per_pack_counts:
        print(f"  {pack_id}: {count}")
    print(f"Total terms across packs: {total_in_packs}")
    print(f"Merged terms (deduped): {len(merged)}")

    if cross_pack_duplicates:
        print(f"\nCross-pack duplicates ({len(cross_pack_duplicates)}):")
        for dup in cross_pack_duplicates:
            print(
                f"  '{dup['text']}': kept from '{dup['kept_from']}', "
                f"skipped from '{dup['skipped_from']}'"
            )
    else:
        print("\nNo cross-pack duplicates.")


if __name__ == "__main__":
    main()
