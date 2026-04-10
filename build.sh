#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Framewise"
BUNDLE_ID="com.local.Framewise"
BUNDLE="${APP_NAME}.app"
BUILD_DIR=".build"
ENTITLEMENTS="Framewise.entitlements"

# Code-signing identity: use env var, or fall back to ad-hoc
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

echo "=== Building ${APP_NAME} ==="

# Clean
rm -rf "$BUILD_DIR" "$BUNDLE"
mkdir -p "$BUILD_DIR"

# ── Compile Swift sources ─────────────────────────────────────────
echo "Compiling..."
swiftc \
    -O \
    -whole-module-optimization \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macosx14.0" \
    -framework Metal \
    -framework MetalKit \
    -framework AVFoundation \
    -framework CoreImage \
    -framework CoreVideo \
    -framework AppKit \
    -framework SwiftUI \
    -framework UniformTypeIdentifiers \
    -framework QuartzCore \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    FramewiseApp.swift \
    ShaderSource.swift \
    VideoEngine.swift \
    MetalComparisonView.swift \
    ContentView.swift \
    -o "$BUILD_DIR/Framewise"

echo "Compilation successful."

# ── Create .icns from icon.png ────────────────────────────────────
ICON_SRC="App Exports/App-iOS-Dark-1024x1024@1x.png"
if [ -f "$ICON_SRC" ]; then
    echo "Creating app icon..."
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"

    # Generate all required sizes
    for SIZE in 16 32 64 128 256 512 1024; do
        sips -z $SIZE $SIZE "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null 2>&1
    done
    # Retina variants
    cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
    cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
    cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
    cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
    cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    # Remove non-standard sizes
    rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"

    iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
    echo "Icon created."
else
    echo "Warning: icon not found, skipping icon."
fi

# ── Assemble app bundle ───────────────────────────────────────────
echo "Creating app bundle..."
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BUILD_DIR/Framewise" "$BUNDLE/Contents/MacOS/"
cp Info.plist "$BUNDLE/Contents/"

if [ -f "$BUILD_DIR/AppIcon.icns" ]; then
    cp "$BUILD_DIR/AppIcon.icns" "$BUNDLE/Contents/Resources/"
fi

# ── Code-sign ─────────────────────────────────────────────────────
echo "Signing with: ${SIGN_IDENTITY}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc signing (local dev)
    codesign --force --sign - "$BUNDLE"
else
    # Developer ID signing (for notarization)
    codesign --force --options runtime \
        --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$BUNDLE"
fi

echo ""
echo "=== Build complete: $BUNDLE ==="
echo "Run with: open \"$BUNDLE\""
