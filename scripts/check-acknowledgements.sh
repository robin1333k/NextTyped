#!/bin/bash
# Fail when a package the app resolves has no section in App/Resources/Acknowledgements.txt, or when a
# licence link in AboutSettingsView.swift is not an https URL. Apache-2.0 section 4(a) needs the licence
# text with every binary, so this covers indirect packages too.
# Usage: scripts/check-acknowledgements.sh [path-to-Package.resolved]
# Build-time only packages (macro plugins) are listed in SKIP and ship no code.
set -euo pipefail
cd "$(dirname "$0")/.."

RESOLVED="${1:-NextTyped.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved}"
[ -f "$RESOLVED" ] || { echo "no Package.resolved at $RESOLVED (run xcodegen generate and resolve packages)" >&2; exit 2; }
SKIP="swift-syntax"
status=0

for id in $(python3 -c 'import json,sys; [print(p["identity"]) for p in json.load(open(sys.argv[1]))["pins"]]' "$RESOLVED"); do
  case " $SKIP " in *" $id "*) continue ;; esac
  if ! grep -qi -- "$id" App/Resources/Acknowledgements.txt; then
    echo "missing licence section: $id" >&2
    status=1
  fi
done

# Vendored code inside Cmlx that has its own notice (BSD clauses need it in the documentation of a binary).
for name in "Max-Planck-Society" "Norbert Juffa" "NVIDIA Corporation"; do
  grep -q -- "$name" App/Resources/Acknowledgements.txt || { echo "missing vendored notice: $name" >&2; status=1; }
done

for link in $(grep -o 'licenceLink: "[^"]*"' App/Settings/AboutSettingsView.swift | cut -d'"' -f2); do
  case "$link" in https://*/*) ;; *) echo "bad licence link: $link" >&2; status=1 ;; esac
done

[ "$status" -eq 0 ] && echo "acknowledgements complete"
exit "$status"
