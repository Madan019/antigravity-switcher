#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/Applications/Antigravity Switcher.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
PROFILES_DIR="$HOME/.antigravity-profiles"

echo "=================================================="
echo "  Building Antigravity Switcher (Native macOS App) "
echo "=================================================="

# 1. Compile native Swift binary
echo "Compiling native Swift binary..."
swiftc -O "$DIR/AntigravitySwitcher.swift" -o "$DIR/AntigravitySwitcher"
echo "✓ Native binary compiled successfully."

# 2. Assemble macOS App Bundle
echo "Assembling application bundle in ~/Applications/..."
mkdir -p "$MACOS" "$RESOURCES" "$PROFILES_DIR"

cp "$DIR/AntigravitySwitcher" "$MACOS/AntigravitySwitcher"
chmod +x "$MACOS/AntigravitySwitcher"

# 3. Bundle resources (UI & Python Core)
cp "$DIR/ui.html" "$RESOURCES/ui.html"
cp "$DIR/account_switcher_core.py" "$RESOURCES/account_switcher_core.py"
chmod +x "$RESOURCES/account_switcher_core.py"

# Mirror to runtime profile directory
cp "$DIR/ui.html" "$PROFILES_DIR/ui.html"
cp "$DIR/account_switcher_core.py" "$PROFILES_DIR/account_switcher_core.py"
chmod +x "$PROFILES_DIR/account_switcher_core.py"

# 4. Copy app icon if Antigravity is installed
if [ -f "/Applications/Antigravity.app/Contents/Resources/icon.icns" ]; then
    cp "/Applications/Antigravity.app/Contents/Resources/icon.icns" "$RESOURCES/icon.icns"
fi

# 5. Generate Info.plist
cat << 'EOF' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Antigravity Switcher</string>
    <key>CFBundleExecutable</key>
    <string>AntigravitySwitcher</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.google.antigravity.switcher</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Antigravity Switcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# 6. Ad-hoc code sign the app bundle
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

# 7. Clear any stale TCC privacy permissions from legacy child-process runs
tccutil reset All com.google.antigravity.switcher 2>/dev/null || true

# 7. Refresh macOS LaunchServices
if [ -f "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
fi

echo "=================================================="
echo "✓ Successfully built: $APP_DIR"
echo "=================================================="
