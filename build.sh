#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Building CTKBridge ==="

# Compile as a universal bundle (x86_64 + arm64)
clang -dynamiclib \
    -arch arm64 \
    -arch x86_64 \
    -framework Foundation \
    -framework CryptoTokenKit \
    -fobjc-arc \
    -mmacosx-version-min=13.0 \
    -o libctkbridge.so \
    CTKBridge.m

echo "=== Build successful ==="

# Create the bundle structure
BUNDLE="ifd-ctkbridge.bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp libctkbridge.so "$BUNDLE/Contents/MacOS/"
cp Info.plist "$BUNDLE/Contents/"

echo "=== Bundle created: $BUNDLE ==="
echo ""
echo "To install, run:"
echo "  sudo cp -r $BUNDLE /usr/local/libexec/SmartCardServices/drivers/"
echo "  sudo killall com.apple.ifdreader com.apple.ctkpcscd 2>/dev/null"
echo ""
echo "To verify:"
echo "  pcsctest"
