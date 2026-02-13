#!/bin/bash
# Extract Tor binary from official Tor Browser APK
#
# Usage: ./extract_tor_from_apk.sh <path_to_apk>
#
# This extracts the arm64-v8a Tor binary from the official
# Tor Browser for Android APK.

set -e

APK_PATH="${1:-tor-browser.apk}"
OUTPUT_DIR="$(dirname "$0")/../android/app/src/main/assets/tor"

if [ ! -f "$APK_PATH" ]; then
    echo "Error: APK not found at $APK_PATH"
    echo "Download from: https://www.torproject.org/download/#android"
    exit 1
fi

echo "Extracting Tor binary from: $APK_PATH"

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Unzip APK
unzip -q "$APK_PATH" -d "$TEMP_DIR"

# Find and copy Tor binary
TOR_BINARY="$TEMP_DIR/lib/arm64-v8a/libTor.so"
if [ -f "$TOR_BINARY" ]; then
    cp "$TOR_BINARY" "$OUTPUT_DIR/tor"
    chmod 755 "$OUTPUT_DIR/tor"
    echo "Tor binary extracted successfully!"
    echo "Location: $OUTPUT_DIR/tor"
    
    # Verify
    file "$OUTPUT_DIR/tor"
else
    echo "Error: libTor.so not found in APK"
    echo "Expected path: lib/arm64-v8a/libTor.so"
    exit 1
fi