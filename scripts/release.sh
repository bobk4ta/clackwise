#!/usr/bin/env bash
# Release build: builds and signs Clackwise.app (identity from scripts/signing-env.sh), zips it to
# dist/Clackwise-<version>.zip with a SHA-256 file, and verifies the zip. Installs nothing, publishes nothing.
# Usage: scripts/release.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="dist/Clackwise-$VERSION.zip"

scripts/build_app.sh --no-install
.build/release/keyimpact selftest | grep -c PASS | sed 's/$/ selftest checks passed/'
! .build/release/keyimpact selftest | grep -q FAIL
# The Intel slice, under Rosetta (when available).
BIN_X86="$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86 --show-bin-path)"
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  arch -x86_64 "$BIN_X86/keyimpact" selftest | grep -c PASS | sed 's/$/ selftest checks passed on x86_64 (Rosetta)/'
  ! arch -x86_64 "$BIN_X86/keyimpact" selftest | grep -q FAIL
fi

mkdir -p dist
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent build/Clackwise.app "$ZIP"
(cd dist && shasum -a 256 "Clackwise-$VERSION.zip" > "Clackwise-$VERSION.zip.sha256")

# Verify what users will get: unzip into a fresh directory and check signature and requirement.
CHECK="$(mktemp -d)"; trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --strict --deep "$CHECK/Clackwise.app"
echo "designated requirement: $(codesign -d -r- "$CHECK/Clackwise.app" 2>&1 | sed -n 's/^designated => //p')"
echo "architectures: $(lipo -archs "$CHECK/Clackwise.app/Contents/MacOS/Clackwise")"
echo "bundle id: $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$CHECK/Clackwise.app/Contents/Info.plist")"
echo "version:   $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$CHECK/Clackwise.app/Contents/Info.plist")"
echo "$ZIP ($(du -h "$ZIP" | cut -f1))"; cat "$ZIP.sha256"
