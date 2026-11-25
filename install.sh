#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/Applications/Antigravity Switcher.app"

echo "=== Installing Antigravity Switcher ==="

# 1. Run build script
bash "$DIR/build.sh"

# 2. Launch the application
echo "Launching Antigravity Switcher..."
open "$APP_DIR"

echo "✓ Antigravity Switcher is now installed and running!"
