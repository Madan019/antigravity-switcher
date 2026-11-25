#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$DIR/dist"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR"/*

VERSION="2.0.0"
echo "=================================================="
echo " Packaging Antigravity Switcher v$VERSION Releases"
echo "=================================================="

# 1. Build macOS .app
echo "--> Building macOS Native App..."
"$DIR/build.sh"

APP_PATH="$HOME/Applications/Antigravity Switcher.app"

# 2. Package macOS .zip
echo "--> Creating Antigravity-Switcher-macOS.zip..."
(cd "$HOME/Applications" && zip -r -q "$DIST_DIR/Antigravity-Switcher-macOS.zip" "Antigravity Switcher.app")

# 3. Package macOS .dmg
echo "--> Creating Antigravity-Switcher-macOS.dmg..."
DMG_STAGING="/tmp/dmg_staging_$$"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "Antigravity Switcher" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DIST_DIR/Antigravity-Switcher-macOS.dmg" >/dev/null

rm -rf "$DMG_STAGING"
echo "✓ Created Antigravity-Switcher-macOS.dmg"

# 4. Package Windows .zip
echo "--> Creating Antigravity-Switcher-Windows.zip..."
WIN_STAGING="/tmp/win_staging_$$"
rm -rf "$WIN_STAGING"
mkdir -p "$WIN_STAGING/AntigravitySwitcher"

cp "$DIR/account_switcher_core.py" "$WIN_STAGING/AntigravitySwitcher/"
cp "$DIR/switcher_gui.py" "$WIN_STAGING/AntigravitySwitcher/"
cp "$DIR/ui.html" "$WIN_STAGING/AntigravitySwitcher/"
cp "$DIR/install.bat" "$WIN_STAGING/AntigravitySwitcher/"
cp "$DIR/install.ps1" "$WIN_STAGING/AntigravitySwitcher/"
cp "$DIR/launch.bat" "$WIN_STAGING/AntigravitySwitcher/"
cp "$DIR/README.md" "$WIN_STAGING/AntigravitySwitcher/"

(cd "$WIN_STAGING" && zip -r -q "$DIST_DIR/Antigravity-Switcher-Windows.zip" "AntigravitySwitcher")
rm -rf "$WIN_STAGING"
echo "✓ Created Antigravity-Switcher-Windows.zip"

# 5. Package Linux .tar.gz
echo "--> Creating Antigravity-Switcher-Linux.tar.gz..."
LINUX_STAGING="/tmp/linux_staging_$$"
rm -rf "$LINUX_STAGING"
mkdir -p "$LINUX_STAGING/antigravity-switcher"

cp "$DIR/account_switcher_core.py" "$LINUX_STAGING/antigravity-switcher/"
cp "$DIR/switcher_gui.py" "$LINUX_STAGING/antigravity-switcher/"
cp "$DIR/ui.html" "$LINUX_STAGING/antigravity-switcher/"
cp "$DIR/install_linux.sh" "$LINUX_STAGING/antigravity-switcher/install.sh"
cp "$DIR/README.md" "$LINUX_STAGING/antigravity-switcher/"
chmod +x "$LINUX_STAGING/antigravity-switcher/"*.sh
chmod +x "$LINUX_STAGING/antigravity-switcher/"*.py

tar -czf "$DIST_DIR/Antigravity-Switcher-Linux.tar.gz" -C "$LINUX_STAGING" "antigravity-switcher"
rm -rf "$LINUX_STAGING"
echo "✓ Created Antigravity-Switcher-Linux.tar.gz"

echo "=================================================="
echo "✓ All Release Archives Built Successfully in:"
ls -lh "$DIST_DIR"
echo "=================================================="
