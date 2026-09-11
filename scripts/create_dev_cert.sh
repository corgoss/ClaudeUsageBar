#!/bin/bash
# Creates a self-signed code-signing certificate for local development.
#
# Why this exists: without a stable signing identity, build.sh falls back to
# ad-hoc signing, whose designated requirement is the binary's cdhash. Keychain
# ACLs are matched against that requirement, so every rebuild makes the app a
# stranger to its own keychain item and macOS asks for your password again —
# "Always Allow" only ever pins the exact build you clicked it on.
#
# A self-signed certificate gives the app a requirement of
#   identifier "com.claude.usagebar" and certificate leaf = H"<cert hash>"
# which does not change when the binary does, so one "Always Allow" sticks.
#
# The certificate never leaves this Mac and is not added as a trusted root;
# codesign does not need that, and Gatekeeper is not involved locally.
# Remove it any time with:  security delete-identity -c "ClaudeUsageBar Dev"
set -euo pipefail

CERT_NAME="ClaudeUsageBar Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if security find-identity -p codesigning | grep -q "\"$CERT_NAME\""; then
    echo "✅ '$CERT_NAME' already exists — skipping creation."
else
    cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext

[ dn ]
CN = $CERT_NAME

[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

    echo "🔑 Generating self-signed code-signing certificate..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
        -config "$WORK/openssl.cnf" >/dev/null 2>&1

    openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/identity.p12" -passout pass:temp -name "$CERT_NAME" >/dev/null 2>&1

    # -T /usr/bin/codesign lets codesign use the private key without prompting.
    echo "📥 Importing into the login keychain..."
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign
fi

# Prove the identity can actually sign before declaring success: codesign has to
# use the private key, and the keychain can still gate that with its own ACL.
echo "🧪 Verifying the identity can sign..."
printf 'int main(void){return 0;}\n' > "$WORK/selftest.c"
cc -o "$WORK/selftest" "$WORK/selftest.c"
if codesign --force --sign "$CERT_NAME" "$WORK/selftest" 2>"$WORK/err"; then
    echo "✅ Signed a test binary successfully."
    echo "   Requirement: $(codesign -d -r- "$WORK/selftest" 2>/dev/null | grep -o 'certificate leaf.*')"
else
    echo "❌ codesign could not use the key: $(cat "$WORK/err")" >&2
    echo "   If macOS showed a keychain dialog, answer it with \"Always Allow\" and re-run." >&2
    echo "   To grant access permanently without a dialog, run:" >&2
    echo "     security set-key-partition-list -S apple-tool:,apple:,codesign: \\" >&2
    echo "       -s -l \"$CERT_NAME\" \"$KEYCHAIN\"" >&2
    exit 1
fi

echo
echo "✅ Ready. Rebuild with app/build.sh and the app gets a stable identity."
echo
echo "⚠️  macOS will ask for your keychain password ONE more time on the next launch:"
echo "    the saved session is still locked to the old ad-hoc build. Click"
echo "    \"Always Allow\" and the ACL is rewritten to trust this certificate for good."
