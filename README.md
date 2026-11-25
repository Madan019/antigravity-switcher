# Antigravity Switcher

A native macOS application and identity management utility for **Google Antigravity**. Switch between multiple personal Google accounts seamlessly, manage isolated workspaces (Personal vs Company / Work), and protect against quota rate limits (HTTP 429) with automatic failover.

---

## Key Highlights

- **Multi-Account Personal Pool**: Add multiple Google accounts (e.g. primary account and backup quota accounts) to your Personal workspace without losing your existing conversations or project histories.
- **5-Tier Identity Synchronization**:
  1. macOS Keychain (`security add-generic-password -s gemini -a antigravity`) for the language server.
  2. Google Accounts registry (`~/.gemini/google_accounts.json`).
  3. Standalone OAuth Token cache (`~/.gemini/jetski-standalone-oauth-token`).
  4. SQLite State Database (`state.vscdb` - `antigravityAuthStatus`, `antigravityUnifiedStateSync.userStatus`, `agy.onboarding.lastLoginUsername`).
  5. Application Storage (`app_storage.json`).
- **Isolated Workspace Profiles**: Run separate environments (such as Company / Work) with dedicated settings, isolated chats, and independent tokens.
- **Simultaneous Instances**: Launch Personal and Company workspaces side-by-side in separate native windows.
- **Google Material Design 3 (M3) UI**: Authentic Google profile picker aesthetic with light/dark theme toggle, Google brand colors, smooth card interactions, and window dragging.
- **Safety Guards**: Active accounts are protected from accidental deletion.

---

## Project Structure

```
antigravity-switcher/
├── AntigravitySwitcher.swift      # Native Swift AppKit wrapper & process manager
├── account_switcher_core.py       # Core synchronization engine across 5 identity tiers
├── ui.html                       # Google M3 Webview UI (Accounts manager & Settings)
├── build.sh                      # Shell script to compile Swift binary & build .app bundle
├── install.sh                    # 1-click build, register, and launch script
└── .gitignore                    # Git ignore file for macOS and build artifacts
```

---

## Build & Installation

### Prerequisites
- macOS 12.0 or later
- Swift compiler (`swiftc`, included with Xcode or Command Line Tools: `xcode-select --install`)
- Python 3 (`/usr/bin/python3`)

### 1-Click Install
Run the installation script from your terminal:
```bash
chmod +x build.sh install.sh
./install.sh
```

This compiles `AntigravitySwitcher.swift`, bundles `ui.html` and `account_switcher_core.py`, creates `~/Applications/Antigravity Switcher.app`, and opens the app.

---

## CLI Usage

The core engine can also be executed directly from the terminal:

```bash
# Check current active account
python3 account_switcher_core.py active

# Switch to a saved account in your pool
python3 account_switcher_core.py switch <email>

# Backup current account credentials
python3 account_switcher_core.py backup <email>

# Remove an account from pool (cannot delete active account)
python3 account_switcher_core.py delete <email>

# Force re-sync active token to macOS Keychain
python3 account_switcher_core.py resync-keychain

# Clear temporary updater archives and cache files
python3 account_switcher_core.py clean-caches
```

---

## Authors & Contribution

Created by [Madanlal Bidiyasar](https://github.com/madanlal019). Contributions and improvements are welcome!
