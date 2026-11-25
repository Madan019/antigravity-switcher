#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/share/antigravity-switcher"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"

echo "=================================================="
echo "    Antigravity Switcher - Linux Installation    "
echo "=================================================="

# Check Python 3
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required. Please install python3 via your package manager." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR"

# Copy files
cp "$DIR/account_switcher_core.py" "$INSTALL_DIR/"
cp "$DIR/switcher_gui.py" "$INSTALL_DIR/"
cp "$DIR/ui.html" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/switcher_gui.py"
chmod +x "$INSTALL_DIR/account_switcher_core.py"

# Create launcher script in ~/.local/bin
cat << 'EOF' > "$BIN_DIR/antigravity-switcher"
#!/usr/bin/env bash
exec python3 "$HOME/.local/share/antigravity-switcher/switcher_gui.py" "$@"
EOF
chmod +x "$BIN_DIR/antigravity-switcher"

# Create .desktop entry
cat << EOF > "$DESKTOP_DIR/antigravity-switcher.desktop"
[Desktop Entry]
Name=Antigravity Switcher
Comment=Multi-account profile switcher and workspace manager for Google Antigravity
Exec=$BIN_DIR/antigravity-switcher
Icon=google-chrome
Terminal=false
Type=Application
Categories=Development;Utility;
StartupNotify=true
EOF

# Update desktop database if available
if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
fi

echo "✓ Installed launcher to $BIN_DIR/antigravity-switcher"
echo "✓ Created Desktop Application entry in $DESKTOP_DIR"
echo "=================================================="
echo "✓ Installation complete! Launching Antigravity Switcher..."
echo "=================================================="

nohup "$BIN_DIR/antigravity-switcher" >/dev/null 2>&1 &
