#!/bin/bash
# Creates a *stable* self-signed code-signing identity for SonosControl, stored
# in a dedicated keychain, so macOS keeps the Local Network grant across
# rebuilds. (TCC remembers a grant by the app's designated requirement — bundle
# id + signing certificate; ad-hoc signatures change every build and drop it.)
#
# Idempotent: re-running is a no-op once the identity exists. Signing does not
# require the certificate to be trusted, so there's no admin/trust prompt.
set -euo pipefail

IDENTITY="SonosControl Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/sonoscontrol-signing.keychain-db"
KEYCHAIN_PASS="sonoscontrol"
OPENSSL="/usr/bin/openssl"   # system LibreSSL: emits Keychain-importable PKCS12

# NOTE: use plain `find-identity` (not `-v`): a self-signed cert isn't trust
# valid, and `-v` would hide it, causing a duplicate import every run (which
# makes `codesign --sign` ambiguous and fail).
if [ -f "$KEYCHAIN" ] && security find-identity "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> Signing identity '$IDENTITY' already present."
    exit 0
fi

echo "==> Creating self-signed code-signing identity '$IDENTITY'"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CONF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.conf" -extensions v3 2>/dev/null

"$OPENSSL" pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$TMP/identity.p12" \
    -passout "pass:$KEYCHAIN_PASS" 2>/dev/null

if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null

EXISTING="$(security list-keychains -d user | sed -e 's/"//g' -e 's/^[[:space:]]*//')"
if ! echo "$EXISTING" | grep -q "sonoscontrol-signing"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KEYCHAIN" $EXISTING
fi

echo "==> Done. Identity '$IDENTITY' ready in $KEYCHAIN"
