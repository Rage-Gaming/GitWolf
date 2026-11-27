#!/usr/bin/env bash
# Creates the self-signed certificate that signs GitWolf releases. Run it once, on the maintainer's Mac.
#
#   Scripts/make-signing-cert.sh            # creates "GitWolf Release" in your login keychain
#
# Why: macOS ties Keychain access and privacy permissions to an app's signing identity. An ad-hoc
# signature changes with every build, so each update would ask for them again. Signing every release with
# the same certificate keeps the identity stable, so updates are silent. It costs nothing and it is NOT a
# Developer ID: Gatekeeper still shows its warning on the very first install (see docs/RELEASING.md).
#
# Environment: NAME (certificate name), KEYCHAIN (default: login), OUT (folder for the CI export files).
set -euo pipefail
# The system LibreSSL writes .p12 files that macOS can import; newer OpenSSL builds do not.
OPENSSL=/usr/bin/openssl
NAME="${NAME:-GitWolf Release}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OUT="${OUT:-build/signing}"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "A certificate named \"$NAME\" already exists in $KEYCHAIN; nothing to do."
  exit 0
fi

mkdir -p "$OUT"; chmod 700 "$OUT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/openssl.cnf" <<CNF
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
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The .p12 password is random and only ever lives in files readable by you, never on a command line.
export P12_PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/cert.p12" -passout env:P12_PASS

# `security -i` reads commands from stdin, so the password does not appear in a process argument list.
security -i <<EOS
import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
EOS
# No trust step: codesign signs with a self-signed identity by name; Gatekeeper never trusts it either way.

# Files for the release workflow's repository secrets (MACOS_CERTIFICATE_P12 / MACOS_CERTIFICATE_PASSWORD).
base64 < "$WORK/cert.p12" | tr -d '\n' > "$OUT/certificate.p12.base64"
printf '%s' "$P12_PASS" > "$OUT/certificate.password"
chmod 600 "$OUT"/certificate.*
echo "Created \"$NAME\" in $KEYCHAIN."
echo "For GitHub Actions, add repository secrets from these files, then delete them:"
echo "  MACOS_CERTIFICATE_P12      <- $OUT/certificate.p12.base64"
echo "  MACOS_CERTIFICATE_PASSWORD <- $OUT/certificate.password"
