#!/bin/bash
# Rebuild the bundled emoji lexicon from the Unicode CLDR annotations (cldr-json, Unicode-3.0 licence).
# Output: NextTypedCore/Sources/NextTypedCore/Resources/emoji-lexicon.lzfse
# Each line of the plain text is: emoji TAB en-name TAB en-keywords TAB de-name TAB de-keywords
# (keywords joined by "|"). Skin-tone and gender variants are left out (a follow-up ticket).
# Usage: scripts/generate-emoji-lexicon.sh [cldr-version]   (default 46.0.0)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-46.0.0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for lang in en de; do
  curl -fsS "https://cdn.jsdelivr.net/npm/cldr-annotations-full@${VERSION}/annotations/${lang}/annotations.json" -o "$WORK/$lang.json"
done
# The CLDR annotations also cover plain symbols ('.', '$', card suits). Only the fully-qualified
# lines of emoji-test.txt are emoji, and they carry U+FE0F, so the stored form renders as emoji.
curl -fsS "https://unicode.org/Public/${EMOJI_VERSION:-16.0}/emoji-test.txt" -o "$WORK/emoji-test.txt" 2>/dev/null \
  || curl -fsS "https://unicode.org/Public/emoji/${EMOJI_VERSION:-16.0}/emoji-test.txt" -o "$WORK/emoji-test.txt"
python3 - "$WORK" <<'PY'
import json, sys
work = sys.argv[1]
def load(lang):
    return json.load(open(f"{work}/{lang}.json"))["annotations"]["annotations"]
en, de = load("en"), load("de")
# Card suits are emoji, but their name "Herz" outranks "rotes Herz" and :herz must give the red heart.
SKIP = set(range(0x1F3FB, 0x1F400)) | {0x2640, 0x2642, 0x2660, 0x2663, 0x2665, 0x2666}
def clean(s): return " ".join(s.replace("\t", " ").replace("|", " ").split())
FE0F = "\ufe0f"
qualified = []
for line in open(f"{work}/emoji-test.txt", encoding="utf-8"):
    if line.startswith("#") or ";" not in line: continue
    codes, rest = line.split(";", 1)
    if rest.split("#")[0].strip() != "fully-qualified": continue
    qualified.append("".join(chr(int(c, 16)) for c in codes.split()))
def note(table, emoji):
    return table.get(emoji) or table.get(emoji.replace(FE0F, ""))
lines = []
for emoji in sorted(qualified, key=lambda e: [ord(c) for c in e]):
    if any(ord(c) in SKIP for c in emoji): continue
    if note(en, emoji) is None or note(de, emoji) is None: continue
    row = [emoji]
    for d in (note(en, emoji), note(de, emoji)):
        row.append(clean(d["tts"][0]) if d.get("tts") else "")
        row.append("|".join(clean(k) for k in d.get("default", [])))
    lines.append("\t".join(row))
open(f"{work}/lexicon.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(len(lines), "entries", file=sys.stderr)
PY
compression_tool -encode -a lzfse -i "$WORK/lexicon.txt" -o NextTypedCore/Sources/NextTypedCore/Resources/emoji-lexicon.lzfse
ls -l NextTypedCore/Sources/NextTypedCore/Resources/emoji-lexicon.lzfse
