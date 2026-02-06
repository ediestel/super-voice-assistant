#!/bin/bash

# Super Voice Assistant - Build .app Bundle
# Creates a standalone macOS .app bundle

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Building Super Voice Assistant .app bundle${NC}\n"

# Configuration
APP_NAME="SuperVoiceAssistant"
BUNDLE_ID="com.supervoice.SuperVoiceAssistant"
VERSION="1.0.0"
BUILD_CONFIG="${1:-release}"  # release or debug
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
BUNDLE_DIR="${PROJECT_DIR}/build/${APP_NAME}.app"

echo -e "${YELLOW}Configuration:${NC}"
echo "  App Name: ${APP_NAME}"
echo "  Bundle ID: ${BUNDLE_ID}"
echo "  Version: ${VERSION}"
echo "  Build Config: ${BUILD_CONFIG}"
echo "  Project Dir: ${PROJECT_DIR}"
echo ""

# Step 1: Build the executable
echo -e "${BLUE}Step 1: Building executable (${BUILD_CONFIG})...${NC}"
cd "${PROJECT_DIR}"

if [ "$BUILD_CONFIG" = "release" ]; then
    swift build -c release --arch arm64 --arch x86_64
    EXECUTABLE_PATH="${BUILD_DIR}/apple/Products/Release/${APP_NAME}"

    # Fallback to architecture-specific path if universal build not available
    if [ ! -f "$EXECUTABLE_PATH" ]; then
        EXECUTABLE_PATH="${BUILD_DIR}/arm64-apple-macosx/release/${APP_NAME}"
    fi
else
    swift build -c debug
    EXECUTABLE_PATH="${BUILD_DIR}/arm64-apple-macosx/debug/${APP_NAME}"
fi

if [ ! -f "$EXECUTABLE_PATH" ]; then
    echo -e "${RED}❌ Executable not found at: ${EXECUTABLE_PATH}${NC}"
    echo -e "${YELLOW}Trying alternative paths...${NC}"

    # Try to find executable in build directory
    FOUND_EXEC=$(find "${BUILD_DIR}" -name "${APP_NAME}" -type f -perm +111 | head -1)
    if [ -n "$FOUND_EXEC" ]; then
        EXECUTABLE_PATH="$FOUND_EXEC"
        echo -e "${GREEN}✅ Found executable at: ${EXECUTABLE_PATH}${NC}"
    else
        echo -e "${RED}❌ Could not find executable${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✅ Executable built: ${EXECUTABLE_PATH}${NC}\n"

# Step 2: Create app bundle structure
echo -e "${BLUE}Step 2: Creating app bundle structure...${NC}"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

echo -e "${GREEN}✅ Bundle structure created${NC}\n"

# Step 3: Copy executable
echo -e "${BLUE}Step 3: Copying executable...${NC}"
cp "${EXECUTABLE_PATH}" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
echo -e "${GREEN}✅ Executable copied${NC}\n"

# Step 4: Copy icon
echo -e "${BLUE}Step 4: Copying app icon...${NC}"
ICON_SOURCE="${PROJECT_DIR}/Sources/AppIcon.icns"
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
    echo -e "${GREEN}✅ Icon copied${NC}"
else
    echo -e "${YELLOW}⚠️  Icon not found at: ${ICON_SOURCE}${NC}"
fi
echo ""

# Step 5: Create Info.plist
echo -e "${BLUE}Step 5: Creating Info.plist...${NC}"
cat > "${BUNDLE_DIR}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Super Voice Assistant</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Super Voice Assistant</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Super Voice Assistant needs microphone access to record and transcribe your voice.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Super Voice Assistant needs to control other applications to paste transcribed text.</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
EOF

echo -e "${GREEN}✅ Info.plist created${NC}\n"

# Step 6: Copy .env file if exists
echo -e "${BLUE}Step 6: Copying environment files...${NC}"
if [ -f "${PROJECT_DIR}/.env" ]; then
    cp "${PROJECT_DIR}/.env" "${BUNDLE_DIR}/Contents/Resources/.env"
    echo -e "${GREEN}✅ .env file copied${NC}"
else
    echo -e "${YELLOW}⚠️  No .env file found (will need to create one)${NC}"
fi
echo ""

# Step 7: Code signing (optional, ad-hoc for local use)
echo -e "${BLUE}Step 7: Code signing...${NC}"
if command -v codesign &> /dev/null; then
    codesign --force --deep --sign - "${BUNDLE_DIR}"
    echo -e "${GREEN}✅ App bundle signed (ad-hoc)${NC}"
else
    echo -e "${YELLOW}⚠️  codesign not found, skipping signature${NC}"
fi
echo ""

# Step 8: Verification
echo -e "${BLUE}Step 8: Verifying bundle...${NC}"
if [ -f "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}" ]; then
    echo -e "${GREEN}✅ Executable verified${NC}"
fi
if [ -f "${BUNDLE_DIR}/Contents/Info.plist" ]; then
    echo -e "${GREEN}✅ Info.plist verified${NC}"
fi
if [ -f "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns" ]; then
    echo -e "${GREEN}✅ Icon verified${NC}"
fi

# Check bundle validity
if codesign -v "${BUNDLE_DIR}" 2>/dev/null; then
    echo -e "${GREEN}✅ Bundle signature valid${NC}"
fi

BUNDLE_SIZE=$(du -sh "${BUNDLE_DIR}" | cut -f1)
echo -e "${GREEN}✅ Bundle size: ${BUNDLE_SIZE}${NC}"
echo ""

# Success!
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ SUCCESS! App bundle created:${NC}"
echo -e "${GREEN}   ${BUNDLE_DIR}${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Instructions
echo -e "${BLUE}📦 Next steps:${NC}"
echo ""
echo -e "1. ${YELLOW}Copy to Applications:${NC}"
echo -e "   cp -r \"${BUNDLE_DIR}\" /Applications/"
echo ""
echo -e "2. ${YELLOW}Create .env file (if not already present):${NC}"
echo -e "   Right-click app in Applications → Show Package Contents"
echo -e "   Navigate to Contents/Resources/"
echo -e "   Create .env file with your API keys:"
echo -e "     GEMINI_API_KEY=your_key_here"
echo -e "     OPENAI_API_KEY=your_key_here"
echo ""
echo -e "3. ${YELLOW}Grant permissions:${NC}"
echo -e "   System Settings → Privacy & Security → Microphone"
echo -e "   System Settings → Privacy & Security → Accessibility"
echo ""
echo -e "4. ${YELLOW}Launch:${NC}"
echo -e "   Double-click SuperVoiceAssistant.app in Applications"
echo -e "   Or: open /Applications/SuperVoiceAssistant.app"
echo ""
echo -e "${BLUE}🎉 Done!${NC}"
