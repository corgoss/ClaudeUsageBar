#!/bin/bash
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)/session_check
swiftc -o "$OUT" \
    app/Core/CookiePolicy.swift \
    app/Core/CredentialStore.swift \
    app/Auth/ClaudeSession.swift \
    scripts/session_check/main.swift \
    -framework Foundation
"$OUT"