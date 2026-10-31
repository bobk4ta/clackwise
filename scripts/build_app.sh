#!/usr/bin/env bash
# Builds Clackwise.app (and the keyimpact CLI), signs it with the stable local identity and
# installs it to ~/Applications. Usage: scripts/build_app.sh [--no-install]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/signing-env.sh

BUNDLE_ID="io.github.bobk4ta.clackwise"
APP="$ROOT/build/Clackwise.app"
DEST="$HOME/Applications/Clackwise.app"

[[ -d Resources/SoundPacks/holy-pandas ]] || scripts/fetch_packs.sh
scripts/make_signing_identity.sh >/dev/null

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
# Universal binary: SwiftPM's --arch fat build needs Xcode's XCBuild, so build the Intel slice into its own
# scratch directory with a triple and join the two with lipo (Intel Macs play every key at the normal level).
X86="x86_64-apple-macosx14.0"
swift build -c release --triple "$X86" --scratch-path .build-x86
BIN_X86="$(swift build -c release --triple "$X86" --scratch-path .build-x86 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BIN/Clackwise" "$BIN_X86/Clackwise" -output "$APP/Contents/MacOS/Clackwise"
sed "s/BUILD_NUMBER/$(date +%Y%m%d%H%M)/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/calibration.json "$APP/Contents/Resources/"
cp THIRD_PARTY_LICENSES "$APP/Contents/Resources/LICENSES.md"
# App icon: drawn in code (AppIconView), rendered by the binary itself.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN/Clackwise" --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rsync -a --delete Resources/SoundPacks/ "$APP/Contents/Resources/SoundPacks/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

security unlock-keychain -p "$(cat "$SIGN_PWFILE")" "$SIGN_KEYCHAIN"
codesign --force --sign "$SIGN_NAME" --keychain "$SIGN_KEYCHAIN" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x Clackwise 2>/dev/null && sleep 0.5 || true
  mkdir -p "$HOME/Applications"
  rsync -a --delete "$APP/" "$DEST/"
  echo "installed $DEST"
fi
