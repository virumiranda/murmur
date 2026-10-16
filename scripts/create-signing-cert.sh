#!/bin/bash
# Creates a self-signed code-signing identity in your login keychain, used by `make`.
#
# macOS ties Accessibility / Input Monitoring permissions to the app's signature. An ad-hoc signature
# changes on every build, so each rebuild loses the permissions; this stable identity keeps them.
# Run once. Nothing leaves your Mac.
set -euo pipefail

NAME="${1:-Murmur Local Signing}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
  -out "$tmp/identity.p12" -passout pass:murmur
security import "$tmp/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P murmur -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". Build with: make install SIGN_IDENTITY=\"$NAME\" (the Makefile picks it up automatically)."
