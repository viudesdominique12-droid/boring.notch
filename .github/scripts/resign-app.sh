#!/bin/bash
# Re-signs an ad-hoc built app with a fixed certificate, inside out, keeping
# each piece's identifier, entitlements and flags. A fixed certificate gives
# the app the same identity on every build, so macOS keeps its permissions
# (calendar, Desktop, Downloads, Bluetooth) across updates.
#
# Usage: resign-app.sh <App.app> <identity SHA-1> [keychain]
set -euo pipefail
APP="$1"; ID="$2"; KC="${3:-}"
KCARG=()
[ -n "$KC" ] && KCARG=(--keychain "$KC")

sign() {
  codesign --force --sign "$ID" "${KCARG[@]}" \
    --preserve-metadata=identifier,entitlements,flags --timestamp=none "$1"
}

# 1. Loose Mach-O files: dylibs, helper tools, framework binaries.
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then sign "$f"; fi
done < <(find "$APP/Contents" -type f -perm +111 ! -path "*/Contents/MacOS/*" -print0)

# 2. Nested bundles, deepest first (symlinked aliases skipped).
while IFS= read -r -d '' b; do
  sign "$b"
done < <(find "$APP/Contents" -depth ! -type l \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -print0)

# 3. The app itself.
sign "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dr - "$APP" 2>&1 | tail -1
