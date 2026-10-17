#!/bin/bash
# Creates a self-signed code signing identity so rebuilds keep the same designated
# requirement, and macOS privacy grants (Screen Recording, Camera, Microphone) survive them.
set -euo pipefail
NAME="Screengrab Local Signing"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "$NAME already exists"
    exit 0
fi

dir=$(mktemp -d)
trap 'rm -r "$dir"' EXIT
cat > "$dir/c.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/k.pem" -out "$dir/c.pem" -days 3650 -config "$dir/c.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$dir/k.pem" -in "$dir/c.pem" -out "$dir/c.p12" -passout pass:tmp
security import "$dir/c.p12" -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
echo "Created $NAME"
