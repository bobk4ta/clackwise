#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity (default "Clackwise Local Signing") in its own keychain,
# so macOS privacy grants (Input Monitoring) survive rebuilds: the app's designated requirement is
# then "identifier io.github.bobk4ta.clackwise and certificate leaf = H<this cert>", the same every build.
# Idempotent. Remove with:
#   security delete-keychain ~/Library/Keychains/clackwise-signing.keychain-db
#   rm -r ~/Library/Application\ Support/Clackwise/signing
set -euo pipefail

source "$(dirname "$0")/signing-env.sh"
NAME="$SIGN_NAME"
KC="$SIGN_KEYCHAIN"
PWFILE="$SIGN_PWFILE"
DIR="$(dirname "$PWFILE")"

if [[ -f "$KC" && -f "$PWFILE" ]] && security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "identity exists: $NAME in $KC"; exit 0
fi

mkdir -p "$DIR"; chmod 700 "$DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077
[[ -f "$PWFILE" ]] || /usr/bin/openssl rand -hex 24 > "$PWFILE"
PW="$(cat "$PWFILE")"
P12PW="$(/usr/bin/openssl rand -hex 16)"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$P12PW" 2>/dev/null

# Keep the user's keychain search list exactly as it was.
LIST_BEFORE="$(security list-keychains -d user | tr -d '"' | xargs)"
[[ -f "$KC" ]] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
# shellcheck disable=SC2086
security list-keychains -d user -s $LIST_BEFORE
echo "created identity: $NAME in $KC"
security find-certificate -c "$NAME" -Z "$KC" | grep SHA-1
