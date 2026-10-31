# Sourced by build_app.sh and make_signing_identity.sh: where the code-signing identity lives.
# Defaults create/use a self-signed identity of your own. To use another one (for example the identity
# you release with), put SIGN_NAME / SIGN_KEYCHAIN / SIGN_PWFILE in scripts/local.env (git-ignored).
SIGN_NAME="Clackwise Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/clackwise-signing.keychain-db"
SIGN_PWFILE="$HOME/Library/Application Support/Clackwise/signing/keychain-password"
# shellcheck disable=SC1091
[[ -f "$(dirname "${BASH_SOURCE[0]}")/local.env" ]] && source "$(dirname "${BASH_SOURCE[0]}")/local.env"
true
