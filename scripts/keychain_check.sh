#!/bin/bash
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)/keychain_check
swiftc -o "$OUT" \
    app/Core/CredentialStore.swift \
    app/Auth/KeychainStore.swift \
    scripts/keychain_check/main.swift \
    -framework Foundation
"$OUT"