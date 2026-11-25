#!/usr/bin/env python3
import os, sys, json, sqlite3, shutil, base64, subprocess

HOME = os.path.expanduser('~')
GEMINI_DIR = os.path.join(HOME, '.gemini')
POOL_DIR = os.path.join(HOME, '.antigravity-profiles/personal-accounts')
APP_SUPPORT_DIR = os.path.join(HOME, 'Library/Application Support/Antigravity')
VSCDB_PATH = os.path.join(APP_SUPPORT_DIR, 'User/globalStorage/state.vscdb')
APP_STORAGE_PATH = os.path.join(APP_SUPPORT_DIR, 'app_storage.json')

def encode_varint(n):
    res = bytearray()
    while n >= 0x80:
        res.append((n & 0x7f) | 0x80)
        n >>= 7
    res.append(n)
    return bytes(res)

def wrap_sentinel(key_name, payload_ascii):
    key_bytes = key_name.encode('utf-8')
    payload_bytes = payload_ascii.encode('utf-8')
    inner_f1 = b'\x0a' + encode_varint(len(payload_bytes)) + payload_bytes
    f2 = b'\x12' + encode_varint(len(inner_f1)) + inner_f1
    f1 = b'\x0a' + encode_varint(len(key_bytes)) + key_bytes
    env = b'\x0a' + encode_varint(len(f1 + f2)) + f1 + f2
    return env

def get_active_account():
    # 1. Check ~/.gemini/google_accounts.json
    try:
        with open(os.path.join(GEMINI_DIR, 'google_accounts.json')) as f:
            d = json.load(f)
            if d.get('active'):
                return d['active'].strip()
    except Exception:
        pass
    # 2. Check jetski-standalone-oauth-token
    try:
        with open(os.path.join(GEMINI_DIR, 'jetski-standalone-oauth-token')) as f:
            d = json.load(f)
            if d.get('id_token_email'):
                return d['id_token_email'].strip()
    except Exception:
        pass
    return None

def backup_account(email):
    if not email:
        return
    email = email.strip()
    acc_dir = os.path.join(POOL_DIR, email)
    os.makedirs(acc_dir, exist_ok=True)
    
    # Check if ~/.gemini currently belongs to this email
    gemini_email = get_active_account()
    if gemini_email == email:
        for f in ['google_accounts.json', 'oauth_creds.json', 'jetski-standalone-oauth-token']:
            src = os.path.join(GEMINI_DIR, f)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(acc_dir, f))
    else:
        print(f"Skipping ~/.gemini file backup for {email} because active is {gemini_email}", file=sys.stderr)
            
    # Read UI state from state.vscdb
    ui_state = {}
    if os.path.isfile(VSCDB_PATH):
        try:
            conn = sqlite3.connect(VSCDB_PATH)
            c = conn.cursor()
            for key in ['antigravityAuthStatus', 'antigravity.profileUrl', 'antigravityUnifiedStateSync.userStatus', 'antigravityUnifiedStateSync.oauthToken']:
                c.execute('SELECT value FROM ItemTable WHERE key = ?', (key,))
                row = c.fetchone()
                if row and row[0]:
                    val = row[0]
                    if key == 'antigravityAuthStatus':
                        try:
                            parsed = json.loads(val)
                            if parsed.get('email') != email:
                                continue
                        except Exception:
                            continue
                    elif key == 'antigravityUnifiedStateSync.userStatus':
                        try:
                            decoded = base64.b64decode(val)
                            # inner payload starts at byte 32
                            inner = base64.b64decode(decoded[32:])
                            if email.encode('utf-8') not in inner:
                                continue
                        except Exception:
                            continue
                    ui_state[key] = val
            conn.close()
        except Exception as e:
            print(f"Warning reading vscdb: {e}", file=sys.stderr)
            
    if os.path.isfile(APP_STORAGE_PATH):
        try:
            with open(APP_STORAGE_PATH) as f:
                data = json.load(f)
                if 'jetski.onboarding.lastLoginUsername' in data:
                    ui_state['jetski.onboarding.lastLoginUsername'] = email
        except Exception as e:
            print(f"Warning reading app_storage: {e}", file=sys.stderr)
            
    if 'antigravityAuthStatus' in ui_state:
        if 'antigravityUnifiedStateSync.userStatus' not in ui_state:
            try:
                parsed = json.loads(ui_state['antigravityAuthStatus'])
                proto_b64 = parsed.get('userStatusProtoBinaryBase64')
                if proto_b64:
                    env = wrap_sentinel('userStatusSentinelKey', proto_b64)
                    ui_state['antigravityUnifiedStateSync.userStatus'] = base64.b64encode(env).decode('ascii')
            except Exception:
                pass
        with open(os.path.join(acc_dir, 'ui_auth_state.json'), 'w') as f:
            json.dump(ui_state, f, indent=2)

def switch_to(target_email):
    target_email = target_email.strip()
    target_dir = os.path.join(POOL_DIR, target_email)
    if not os.path.isdir(target_dir):
        print(f"Error: Target directory does not exist: {target_dir}", file=sys.stderr)
        return False
        
    # 1. Copy credentials into ~/.gemini/
    for f in ['google_accounts.json', 'oauth_creds.json', 'jetski-standalone-oauth-token']:
        src = os.path.join(target_dir, f)
        dst = os.path.join(GEMINI_DIR, f)
        if os.path.isfile(src):
            try:
                if os.path.isfile(dst):
                    os.remove(dst)
                shutil.copy2(src, dst)
            except Exception as e:
                print(f"Error copying {f}: {e}", file=sys.stderr)
                
    # 2. Update macOS Keychain for language_server (go-keyring)
    token_file = os.path.join(target_dir, 'jetski-standalone-oauth-token')
    if os.path.isfile(token_file):
        try:
            with open(token_file) as f:
                t_content = f.read().strip()
            t_b64 = base64.b64encode(t_content.encode('utf-8')).decode('utf-8')
            kc_val = f"go-keyring-base64:{t_b64}"
            subprocess.run(['security', 'add-generic-password', '-a', 'antigravity', '-s', 'gemini', '-w', kc_val, '-U'], capture_output=True)
        except Exception as e:
            print(f"Error updating macOS Keychain: {e}", file=sys.stderr)
                
    # 2. Restore UI auth state
    ui_state_file = os.path.join(target_dir, 'ui_auth_state.json')
    if os.path.isfile(ui_state_file):
        try:
            with open(ui_state_file) as f:
                ui_state = json.load(f)
                
            # Synthesize or verify antigravityUnifiedStateSync.userStatus
            needs_synth = False
            if 'antigravityUnifiedStateSync.userStatus' in ui_state:
                try:
                    dec = base64.b64decode(ui_state['antigravityUnifiedStateSync.userStatus'])
                    inner = base64.b64decode(dec[32:])
                    if target_email.encode('utf-8') not in inner:
                        needs_synth = True
                except Exception:
                    needs_synth = True
            else:
                needs_synth = True
                
            if needs_synth and 'antigravityAuthStatus' in ui_state:
                try:
                    auth_parsed = json.loads(ui_state['antigravityAuthStatus'])
                    proto_b64 = auth_parsed.get('userStatusProtoBinaryBase64')
                    if proto_b64:
                        env = wrap_sentinel('userStatusSentinelKey', proto_b64)
                        ui_state['antigravityUnifiedStateSync.userStatus'] = base64.b64encode(env).decode('ascii')
                except Exception:
                    pass

            # Update SQLite state.vscdb
            if os.path.isfile(VSCDB_PATH):
                conn = sqlite3.connect(VSCDB_PATH)
                c = conn.cursor()
                for key, val in ui_state.items():
                    if key.startswith('jetski.'):
                        continue
                    c.execute('INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)', (key, val))
                c.execute("INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('agy.onboarding.lastLoginUsername', ?)", (target_email,))
                
                # If target profile doesn't have an oauthToken, delete old oauthToken so language_server refreshes cleanly
                if 'antigravityUnifiedStateSync.oauthToken' not in ui_state:
                    c.execute("DELETE FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.oauthToken'")
                    
                conn.commit()
                conn.close()
                
            # Update app_storage.json
            if os.path.isfile(APP_STORAGE_PATH):
                try:
                    with open(APP_STORAGE_PATH) as f:
                        storage = json.load(f)
                    storage['jetski.onboarding.lastLoginUsername'] = target_email
                    storage['agy.onboarding.lastLoginUsername'] = target_email
                    with open(APP_STORAGE_PATH, 'w') as f:
                        json.dump(storage, f, indent=2)
                except Exception as e:
                    print(f"Error updating app_storage: {e}", file=sys.stderr)
        except Exception as e:
            print(f"Error restoring UI state: {e}", file=sys.stderr)
            
    print(f"Successfully switched active account to: {target_email}")
    return True

def delete_account(email):
    if not email:
        return False
    email = email.strip()
    active = get_active_account()
    if active and active.lower() == email.lower():
        print(f"Error: Cannot delete currently active account {email}. Please switch to another account first.", file=sys.stderr)
        return False
    
    target_dir = os.path.join(POOL_DIR, email)
    if os.path.isdir(target_dir):
        try:
            shutil.rmtree(target_dir)
            print(f"Successfully removed account {email} from personal pool.")
            return True
        except Exception as e:
            print(f"Error removing directory {target_dir}: {e}", file=sys.stderr)
            return False
    else:
        print(f"Account {email} not found in pool.", file=sys.stderr)
        return False

def clean_caches():
    caches = [
        os.path.join(HOME, 'Library/Caches/com.google.antigravity'),
        os.path.join(HOME, 'Library/Caches/com.google.antigravity.ShipIt')
    ]
    cleaned = 0
    for c in caches:
        if os.path.isdir(c):
            for item in os.listdir(c):
                p = os.path.join(c, item)
                try:
                    if os.path.isdir(p):
                        shutil.rmtree(p)
                    else:
                        os.remove(p)
                    cleaned += 1
                except Exception:
                    pass
    print(f"Cleaned {cleaned} cache items.")
    return True

def resync_keychain():
    token_file = os.path.join(GEMINI_DIR, 'jetski-standalone-oauth-token')
    if os.path.isfile(token_file):
        try:
            with open(token_file) as f:
                t_content = f.read().strip()
            t_b64 = base64.b64encode(t_content.encode('utf-8')).decode('utf-8')
            kc_val = f"go-keyring-base64:{t_b64}"
            subprocess.run(['security', 'add-generic-password', '-a', 'antigravity', '-s', 'gemini', '-w', kc_val, '-U'], capture_output=True)
            print("Successfully re-synced active token to macOS Keychain.")
            return True
        except Exception as e:
            print(f"Error re-syncing Keychain: {e}", file=sys.stderr)
            return False
    else:
        print("No jetski-standalone-oauth-token found to sync.", file=sys.stderr)
        return False

if __name__ == '__main__':
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == 'switch' and len(sys.argv) > 2:
            switch_to(sys.argv[2])
        elif cmd == 'backup' and len(sys.argv) > 2:
            backup_account(sys.argv[2])
        elif cmd == 'delete' and len(sys.argv) > 2:
            delete_account(sys.argv[2])
        elif cmd == 'clean-caches':
            clean_caches()
        elif cmd == 'resync-keychain':
            resync_keychain()
        elif cmd == 'active':
            print(get_active_account())
    else:
        print("Usage: account_switcher_core.py [switch <email> | backup <email> | delete <email> | clean-caches | resync-keychain | active]")

