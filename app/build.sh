#!/bin/bash

# Build script for ClaudeUsageBar

echo "Building ClaudeUsageBar..."

# Create fresh build directory (delete any stale build to avoid accumulated xattrs
# from prior signs, which can cause "resource fork / detritus" errors on codesign).
rm -rf build
mkdir -p build

# Create app bundle structure first
APP_NAME="ClaudeUsageBar.app"
APP_PATH="build/$APP_NAME"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Info.plist
cp Info.plist "$APP_PATH/Contents/"

# Create icon if it doesn't exist
if [ ! -f "ClaudeUsageBar.icns" ]; then
    echo "Creating app icon..."
    ./make_app_icon.sh >/dev/null 2>&1
fi

# Copy icon to Resources
if [ -f "ClaudeUsageBar.icns" ]; then
    cp ClaudeUsageBar.icns "$APP_PATH/Contents/Resources/"
    # Update Info.plist to reference icon
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ClaudeUsageBar" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ClaudeUsageBar" "$APP_PATH/Contents/Info.plist"
fi

# Collect all sources; the app is no longer a single file.
SOURCES=$(find . -name '*.swift' -not -path './build/*' -not -path './.build/*')

# Compile the Swift app for arm64
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    $SOURCES \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target arm64-apple-macos12.0

# Compile for x86_64 (Intel)
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64" \
    $SOURCES \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target x86_64-apple-macos12.0

# Create universal binary
lipo -create -output "$APP_PATH/Contents/MacOS/ClaudeUsageBar" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Clean up individual arch binaries
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64"
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Create PkgInfo file
echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Set proper permissions first
chmod 755 "$APP_PATH/Contents/MacOS/ClaudeUsageBar"

# Clean any "detritus" that codesign rejects: extended attributes, ._files, .DS_Store
xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete 2>/dev/null
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null
dot_clean "$APP_PATH" 2>/dev/null

# Sign with Developer ID when available, otherwise with the local self-signed
# development certificate. The identity matters beyond Gatekeeper: keychain ACLs
# are matched against the app's designated requirement, and an ad-hoc signature's
# requirement is the binary's cdhash — which changes on every build. Ad-hoc
# builds therefore lose access to their own saved session and prompt for the
# keychain password on every launch. Both certificate paths give a stable
# requirement, so one "Always Allow" lasts.
DEVELOPER_ID="Developer ID Application: Linkko Technology Pte Ltd (Q467HQ5432)"
DEV_CERT="ClaudeUsageBar Dev"
if codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP_PATH" 2>/dev/null; then
    echo "✅ App signed with Developer ID"
    if codesign --verify --verbose=2 "$APP_PATH" 2>&1 | grep -q "valid on disk"; then
        echo "✅ Signature verified"
    else
        echo "❌ Signature verification failed — fix before shipping" >&2
        exit 1
    fi
elif codesign --force --sign "$DEV_CERT" "$APP_PATH" 2>/dev/null; then
    echo "✅ App signed with the local '$DEV_CERT' certificate"
else
    echo "⚠️  No signing identity found; falling back to ad-hoc signing." >&2
    echo "   The app will prompt for your keychain password on EVERY launch," >&2
    echo "   because an ad-hoc signature changes with every build." >&2
    echo "   Fix it once by running scripts/create_dev_cert.sh from the repo root." >&2
    if codesign --force --deep --sign - "$APP_PATH"; then
        echo "✅ App ad-hoc signed for local launch"
    else
        echo "❌ Ad-hoc signing failed" >&2
        exit 1
    fi
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
echo "Launching app..."
open "$APP_PATH"
