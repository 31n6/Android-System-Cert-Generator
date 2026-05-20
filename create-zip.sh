#!/bin/bash
# Run on Linux/macOS/WSL to package the Magisk module.
# REQUIREMENT: Place a static Android ARM64 openssl binary at bin/openssl first.
set -e

MODULE_DIR="$(dirname "$0")"
OUTPUT_ZIP="$(dirname "$MODULE_DIR")/AndroidCACert.zip"
OPENSSL_BIN="$MODULE_DIR/bin/openssl"

if [ ! -f "$OPENSSL_BIN" ]; then
    echo "[!] bin/openssl not found."
    echo ""
    echo "Download a static Android ARM64 openssl binary and place it at:"
    echo "  $OPENSSL_BIN"
    echo ""
    echo "How to get it (choose one):"
    echo "  A) adb pull /system/bin/openssl bin/openssl  (if device has it)"
    echo "  B) Build from NDK targeting android-arm64"
    echo "  C) Extract from a static openssl package for Android ARM64"
    exit 1
fi

echo "[+] Found openssl binary: $OPENSSL_BIN"

cd "$MODULE_DIR"

# Ensure LF line endings and execute bits
for f in post-fs-data.sh META-INF/com/google/android/update-binary; do
    sed -i 's/\r//' "$f"
    chmod +x "$f"
done
sed -i 's/\r//' META-INF/com/google/android/updater-script
chmod +x bin/openssl

zip -r "$OUTPUT_ZIP" \
    module.prop \
    post-fs-data.sh \
    META-INF/ \
    bin/openssl

echo "Created: $OUTPUT_ZIP"
