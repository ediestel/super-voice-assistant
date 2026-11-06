#!/bin/bash

# Super Voice Assistant - Build .dmg installer
# Builds the release .app bundle and packs it into a compressed disk image with an
# Applications shortcut, so installing is: open the DMG, drag the app onto Applications.
#
# Usage: bash scripts/build_dmg.sh            (rebuilds the app bundle first)
#        bash scripts/build_dmg.sh --no-build (packs the existing build/SuperVoiceAssistant.app)
# Output: build/SuperVoiceAssistant-<version>.dmg

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME="SuperVoiceAssistant"
VOLUME_NAME="Super Voice Assistant"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_DIR="${PROJECT_DIR}/build/${APP_NAME}.app"

# Step 1: app bundle
if [ "${1:-}" != "--no-build" ]; then
    echo -e "${BLUE}Step 1: Building the app bundle...${NC}"
    bash "${PROJECT_DIR}/scripts/build_app_bundle.sh" release
else
    echo -e "${BLUE}Step 1: Using the existing app bundle${NC}"
fi
if [ ! -d "${BUNDLE_DIR}" ]; then
    echo -e "${RED}❌ No app bundle at ${BUNDLE_DIR}${NC}"
    exit 1
fi

# Step 2: never ship API keys
if find "${BUNDLE_DIR}" -name ".env*" | grep -q .; then
    echo -e "${RED}❌ The bundle contains a .env file; refusing to pack API keys into the DMG.${NC}"
    find "${BUNDLE_DIR}" -name ".env*"
    exit 1
fi
codesign --verify --deep --strict "${BUNDLE_DIR}"
echo -e "${GREEN}✅ Bundle signature valid, no .env inside${NC}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${BUNDLE_DIR}/Contents/Info.plist")
DMG_PATH="${PROJECT_DIR}/build/${APP_NAME}-${VERSION}.dmg"

# Step 3: staging folder (app + Applications shortcut)
echo -e "${BLUE}Step 3: Staging...${NC}"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/supervoice-dmg.XXXXXX")
trap 'rm -rf "${STAGING}"' EXIT
ditto "${BUNDLE_DIR}" "${STAGING}/${APP_NAME}.app"   # ditto keeps the signature intact
ln -s /Applications "${STAGING}/Applications"

# Step 4: compressed disk image
echo -e "${BLUE}Step 4: Creating ${DMG_PATH##*/}...${NC}"
rm -f "${DMG_PATH}"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${STAGING}" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "${DMG_PATH}" >/dev/null

# Step 5: sign the image with the same identity as the app, then verify
SIGN_IDENTITY="-"
if security find-certificate -c "SuperVoice Local Signing" >/dev/null 2>&1; then
    SIGN_IDENTITY="SuperVoice Local Signing"
fi
codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
hdiutil verify "${DMG_PATH}" >/dev/null
echo -e "${GREEN}✅ DMG signed (${SIGN_IDENTITY}) and verified${NC}"

echo ""
echo -e "${GREEN}✅ ${DMG_PATH} ($(du -h "${DMG_PATH}" | cut -f1))${NC}"
echo "Install: open the DMG, drag Super Voice Assistant onto Applications, eject."
