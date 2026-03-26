#!/usr/bin/env bash
# AIVR AI Node - Multi-Device Deployment Builder
# Builds Android APK and optionally installs to connected devices
#
# Usage:
#   ./deploy.sh              # Build Android APK
#   ./deploy.sh --install    # Build + install to connected devices

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")" && pwd)"
MOBILE_DIR="$PROJ_ROOT/.mobile"

echo ""
echo "========================================"
echo "  AIVR AI Node - Deployment Builder"
echo "  Target: 2 Android + 1 Windows"
echo "========================================"
echo ""

cd "$MOBILE_DIR"

# Resolve dependencies
echo "[1/3] Resolving dependencies..."
flutter pub get
echo "  Done."

# Build Android APK
echo ""
echo "[2/3] Building Android APK (release)..."
flutter build apk --release

APK_PATH="$MOBILE_DIR/build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK_PATH" ]; then
    APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
    echo "  Android APK built: $APK_PATH ($APK_SIZE)"

    mkdir -p "$PROJ_ROOT/deploy"
    cp "$APK_PATH" "$PROJ_ROOT/deploy/aivr-ai-node.apk"
    echo "  Copied to: deploy/aivr-ai-node.apk"
else
    echo "  ERROR: APK not found"
    exit 1
fi

# Install to connected devices if requested
if [ "${1:-}" = "--install" ]; then
    echo ""
    echo "[3/3] Installing to connected Android devices..."
    DEVICES=$(adb devices | grep -E "^\S+\s+device$" | awk '{print $1}')
    COUNT=$(echo "$DEVICES" | grep -c . || true)

    if [ "$COUNT" -eq 0 ]; then
        echo "  WARNING: No Android devices connected"
        echo "  Connect phones via USB with USB Debugging enabled"
    else
        echo "  Found $COUNT device(s)"
        for SERIAL in $DEVICES; do
            echo "  Installing to $SERIAL..."
            adb -s "$SERIAL" install -r "$APK_PATH"
            echo "  Installed on $SERIAL"
        done
    fi
else
    echo "[3/3] Skipping install (use --install to auto-install)"
fi

echo ""
echo "========================================"
echo "  Build Complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Install deploy/aivr-ai-node.apk on both Android phones"
echo "  2. Run the Windows app on your PC (build with deploy.ps1)"
echo "  3. Connect all 3 devices to the same WiFi"
echo "  4. Open SWARM tab - devices auto-discover each other"
echo "  5. Start the server on each device"
echo ""

cd "$PROJ_ROOT"
