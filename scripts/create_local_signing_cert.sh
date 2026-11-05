#!/usr/bin/env bash
set -euo pipefail

# Creates a self-signed code-signing certificate in your login keychain, for
# signing local Dayflow builds. macOS ties permissions such as Screen Recording
# to the app's signature; with ad-hoc signing that changes on every rebuild,
# with this certificate it stays the same, so the permission survives rebuilds.
#
# The certificate only works on this Mac. It is not an Apple Developer ID:
# builds signed with it can't be notarized or given to other people.
#
# Usage:
#   ./scripts/create_local_signing_cert.sh
#   SIGN_ID="Dayflow Local Signing" ./scripts/release_dmg.sh
#
# Optional env vars:
#   CERT_NAME  - certificate name (default: Dayflow Local Signing)
#   CERT_DAYS  - validity in days (default: 3650)

CERT_NAME=${CERT_NAME:-Dayflow Local Signing}
CERT_DAYS=${CERT_DAYS:-3650}
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
# macOS's LibreSSL writes a PKCS#12 that `security import` understands; a
# Homebrew OpenSSL 3 would need -legacy.
OPENSSL=/usr/bin/openssl

if security find-certificate -c "${CERT_NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
  echo "Certificate \"${CERT_NAME}\" already exists in the login keychain."
  security find-identity -v -p codesigning | grep -F "${CERT_NAME}" || true
  echo "Build with: SIGN_ID=\"${CERT_NAME}\" ./scripts/release_dmg.sh"
  exit 0
fi

WORK_DIR=$(mktemp -d -t dayflow_cert)
trap 'rm -rf "${WORK_DIR}"' EXIT
# A throwaway password only protects the .p12 between creating and importing it.
P12_PASSWORD=$(uuidgen)

cat >"${WORK_DIR}/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${CERT_NAME}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "[1/4] Generating key and certificate \"${CERT_NAME}\" (${CERT_DAYS} days)…"
"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -sha256 -days "${CERT_DAYS}" \
  -config "${WORK_DIR}/cert.conf" \
  -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/cert.pem" 2>/dev/null

"${OPENSSL}" pkcs12 -export \
  -inkey "${WORK_DIR}/key.pem" -in "${WORK_DIR}/cert.pem" \
  -name "${CERT_NAME}" -passout "pass:${P12_PASSWORD}" \
  -out "${WORK_DIR}/cert.p12"

echo "[2/4] Importing into the login keychain (codesign may use the key without asking)…"
security import "${WORK_DIR}/cert.p12" -k "${KEYCHAIN}" -P "${P12_PASSWORD}" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "[3/4] Trusting the certificate for code signing (macOS asks for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK_DIR}/cert.pem"

echo "[4/4] Checking codesign can use it…"
if security find-identity -v -p codesigning | grep -F "\"${CERT_NAME}\""; then
  echo
  echo "Done. Build with:"
  echo "  SIGN_ID=\"${CERT_NAME}\" DISABLE_UPDATES=1 ./scripts/release_dmg.sh"
else
  echo "ERROR: the certificate was imported but is not a valid code-signing identity." >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi
