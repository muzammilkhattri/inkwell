#!/bin/bash
# Creates a local self-signed code-signing certificate ("Inkwell Local Signing") in the login
# keychain so development builds keep the same identity. Remove it any time in Keychain Access.
set -euo pipefail
if security find-identity -p codesigning | grep -q "Inkwell Local Signing"; then echo "Already installed"; exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Inkwell Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/cert.cnf" 2>/dev/null
PW=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "Inkwell Local Signing" -out "$D/id.p12" -passout "pass:$PW" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "Inkwell Local Signing" -out "$D/id.p12" -passout "pass:$PW"
security import "$D/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
echo "Installed 'Inkwell Local Signing'"
