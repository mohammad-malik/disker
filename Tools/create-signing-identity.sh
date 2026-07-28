#!/bin/bash
# Creates a self-signed code-signing certificate in the login keychain, once.
#
# Why this exists: macOS keys TCC permissions (Full Disk Access in particular) to a binary's
# code signature. An ad-hoc signature (`codesign -s -`) produces a different identity on every
# build, so macOS treats each rebuild as a brand new app and silently drops the Full Disk
# Access grant — the scan then returns a wrong, much smaller number with no obvious cause.
# Signing with one stable self-signed certificate makes the grant stick across rebuilds.
#
# This is for local development only. Distributing to other machines needs a real Developer ID.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
    echo "Signing identity '$SIGNING_IDENTITY' already exists — nothing to do."
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# The codeSigning extended key usage is what makes codesign accept this certificate;
# a plain self-signed TLS certificate is rejected.
cat >"$WORK_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = $SIGNING_IDENTITY

[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK_DIR/openssl.cnf" \
    -keyout "$WORK_DIR/key.pem" \
    -out "$WORK_DIR/cert.pem" 2>/dev/null

# OpenSSL 3 defaults to AES-256-CBC with a SHA-256 MAC, which macOS's Security framework
# cannot import ("MAC verification failed"). The legacy PBE algorithms below are what
# `security import` understands. An empty password also fails MAC verification, so the
# bundle carries a throwaway one — it never leaves this function.
P12_PASSWORD="disker-transient"
openssl pkcs12 -export -legacy \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -out "$WORK_DIR/identity.p12" -passout "pass:$P12_PASSWORD" 2>/dev/null

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# -T codesign pre-authorises codesign to use the private key, so builds do not each
# raise a keychain password prompt.
security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security

# Importing alone is not enough. codesign only accepts identities it trusts, and a
# freshly imported self-signed certificate is not trusted by default — `security
# find-identity -v -p codesigning` reports "0 valid identities" and signing fails with
# the distinctly unhelpful `errSecInternalComponent`. Marking it as a trusted root for
# code signing (user-level only, no sudo) is what makes it usable.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem"

if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    echo
    echo "Verified: '$SIGNING_IDENTITY' is a valid code-signing identity."
else
    echo
    echo "WARNING: the certificate imported but is not showing as a valid signing identity."
    echo "Builds will fall back to ad-hoc signing."
    exit 1
fi

echo
echo "Created signing identity '$SIGNING_IDENTITY'."
echo
echo "Two things worth knowing:"
echo "  1. macOS may prompt once for your password the first time codesign uses this key."
echo "  2. This certificate is not trusted by other Macs. It exists so Full Disk Access"
echo "     survives rebuilds on this machine, nothing more."
