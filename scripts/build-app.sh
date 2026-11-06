#!/bin/bash
# Build a bundle that carries the stable signing identity — and REFUSE to hand back one that does not.
#
# Why this exists: `xcodebuild` from a non-interactive shell silently falls back to
# ad-hoc signing when the login keychain is not unlocked, even though project.yml sets
# CODE_SIGN_STYLE/CODE_SIGN_IDENTITY on both targets. It exits 0 with no warning. macOS keys TCC grants
# and Keychain ACLs to the code identity, so an ad-hoc bundle is a DIFFERENT app: the Accessibility and
# Screen-Recording grants stop applying and the encrypted style profile stops decrypting. Both were
# observed on this machine and both looked like product defects.
#
# So: pass the identity explicitly, then verify what actually got signed and fail loudly if it is wrong.
#
# Usage: ./scripts/build-app.sh [scheme]     # scheme defaults to NextTyped
#
# Optional environment variables:
#   AC_CONFIGURATION=Release        build that configuration instead of Debug
#   AC_PRODUCT_PATH_FILE=<path>     write the verified product's path there
#   AC_DERIVED_DATA=<dir>           build into this DerivedData folder (xcodebuild -derivedDataPath)
#   AC_BUILD_JOBS=<n>               pass -jobs <n> to xcodebuild
#   AC_XCODEBUILD_SETTINGS="A=1 B=2" extra build settings
set -euo pipefail

SCHEME=${1:-NextTyped}
CONFIGURATION=${AC_CONFIGURATION:-Debug}
IDENTITY="NextTyped Dev"
cd "$(dirname "$0")/.."

# Regenerate every time: the project is gitignored, so a checkout that pulled new source files
# otherwise builds a stale project and fails with "cannot find X in scope" (2026-10-29).
xcodegen generate >/dev/null || { echo "xcodegen generate failed" >&2; exit 1; }

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ARGS=(-project NextTyped.xcodeproj -scheme "$SCHEME"
      -configuration "$CONFIGURATION" -destination 'platform=macOS' -skipMacroValidation
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY")
[ -z "${AC_DERIVED_DATA:-}" ] || ARGS+=(-derivedDataPath "$AC_DERIVED_DATA")
[ -z "${AC_BUILD_JOBS:-}" ] || ARGS+=(-jobs "$AC_BUILD_JOBS")
# Extra build settings, space-separated NAME=value words (scripts/test-sparkle-local.sh passes
# SPARKLE_PUBLIC_ED_KEY and the version numbers). Absent on the normal dev path.
# shellcheck disable=SC2206
[ -z "${AC_XCODEBUILD_SETTINGS:-}" ] || ARGS+=($AC_XCODEBUILD_SETTINGS)

# Ask the build where its product lands instead of re-scanning DerivedData for the newest bundle
# afterwards. Scanning would reintroduce the stale-bundle bug inside its own fix: an up-to-date build does not
# rewrite the executable's mtime, so another DerivedData folder's newer bundle would win and the ✓ would
# attest a bundle this invocation never touched.
SETTINGS=$(xcodebuild "${ARGS[@]}" -showBuildSettings 2>/dev/null)
# Here-strings, not printf | awk: awk exits on the first match, and with pipefail a
# settings dump over the 64 KB pipe buffer killed printf with SIGPIPE (exit 141).
PRODUCTS_DIR=$(awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}' <<<"$SETTINGS")
PRODUCT_NAME=$(awk -F' = ' '/^ *FULL_PRODUCT_NAME = /{print $2; exit}' <<<"$SETTINGS")
BUILT="$PRODUCTS_DIR/$PRODUCT_NAME"

xcodebuild "${ARGS[@]}" build

if [ -z "$PRODUCTS_DIR" ] || [ -z "$PRODUCT_NAME" ] || [ ! -e "$BUILT" ]; then
  echo "Build reported success but the product is not where xcodebuild said it would be: ${BUILT:-<unknown>}" >&2
  exit 1
fi

AUTHORITY=$(codesign -dvvv "$BUILT" 2>&1 | grep -m1 '^Authority=' | sed 's/^Authority=//' || true)
if [ "$AUTHORITY" != "$IDENTITY" ]; then
  cat >&2 <<MSG

✗ Signed "${AUTHORITY:-ad-hoc/unsigned}", expected "$IDENTITY".
  $BUILT

  The login keychain is most likely locked for this shell, so the identity was unreachable and Xcode
  degraded instead of failing. Unlock it and re-run:
      security unlock-keychain ~/Library/Keychains/login.keychain-db
  Do NOT run the app from this bundle: every TCC grant and the style-profile Keychain item are keyed to
  the code identity, so it would cost the Accessibility grant in both directions.
MSG
  exit 1
fi

if [ -n "${AC_PRODUCT_PATH_FILE:-}" ]; then
  printf '%s' "$BUILT" > "$AC_PRODUCT_PATH_FILE"
fi

echo
echo "✓ $BUILT"
echo "  Configuration=$CONFIGURATION"
echo "  Authority=$AUTHORITY"
