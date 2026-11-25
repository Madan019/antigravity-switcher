#!/usr/bin/env python3
"""
Antigravity Switcher - Cross-Platform Desktop GUI
Supports Windows, Linux, and macOS without external dependencies.
Opens as an authentic standalone window using Edge / Chrome / Brave in app-mode,
or pywebview if installed.
"""

import os
import sys
import json
import time
import socket
import shutil
import threading
import subprocess
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)
import account_switcher_core as core

HOME = os.path.expanduser('~')
PROFILES_DIR = os.path.join(HOME, '.antigravity-profiles')
REG_FILE = os.path.join(PROFILES_DIR, 'profiles.json')

def get_free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port

def get_profiles_data():
    os.makedirs(PROFILES_DIR, exist_ok=True)
    reg = {}
    if os.path.isfile(REG_FILE):
        try:
            with open(REG_FILE) as f:
                reg = json.load(f)
        except Exception:
            pass

    if 'personal' not in reg:
        reg['personal'] = {'label': 'Personal', 'color': '#9C27B0', 'mode': 'primary'}
    if 'company' not in reg:
        reg['company'] = {'label': 'Company', 'color': '#1A73E8', 'mode': 'clean'}

    # Personal Accounts Pool
    active_email = core.get_active_account() or ''
    accounts = []
    if os.path.isdir(core.POOL_DIR):
        accounts = sorted([a for a in os.listdir(core.POOL_DIR) if os.path.isdir(os.path.join(core.POOL_DIR, a)) and not a.startswith('.')])
    if active_email and active_email not in accounts:
        accounts.insert(0, active_email)
        core.backup_account(active_email)

    # Check if personal is running (search for running Antigravity process)
    personal_running = False
    try:
        if sys.platform == 'win32':
            out = subprocess.check_output('tasklist /FI "IMAGENAME eq Antigravity.exe"', shell=True).decode('utf-8', errors='ignore')
            personal_running = 'Antigravity.exe' in out
        else:
            out = subprocess.check_output(['pgrep', '-f', 'Antigravity'], stderr=subprocess.DEVNULL).decode('utf-8', errors='ignore')
            personal_running = len(out.strip()) > 0
    except Exception:
        pass

    profiles = [
        {
            'name': 'personal',
            'label': reg.get('personal', {}).get('label', 'Personal'),
            'email': active_email or 'Not signed in',
            'running': personal_running,
            'color': reg.get('personal', {}).get('color', '#9c27b0'),
            'initial': 'P',
            'isPrimary': True,
            'mode': 'primary',
            'accounts': accounts,
            'activeAccount': active_email
        }
    ]

    for name, info in reg.items():
        if name == 'personal':
            continue
        # Check running state via pid file
        pid_file = os.path.join(PROFILES_DIR, name, 'run.pid')
        running = False
        if os.path.isfile(pid_file):
            try:
                with open(pid_file) as pf:
                    pid = int(pf.read().strip())
                if sys.platform == 'win32':
                    res = subprocess.call(f'tasklist /FI "PID eq {pid}" | findstr {pid}', shell=True, stdout=subprocess.DEVNULL)
                    running = (res == 0)
                else:
                    os.kill(pid, 0)
                    running = True
            except Exception:
                running = False

        profiles.append({
            'name': name,
            'label': info.get('label', name.capitalize()),
            'email': info.get('email', 'Isolated Workspace'),
            'running': running,
            'color': info.get('color', '#1a73e8'),
            'initial': (info.get('label', name)[0] if info.get('label', name) else name[0]).upper(),
            'isPrimary': False,
            'mode': info.get('mode', 'clean')
        })

    return profiles

def find_antigravity_binary():
    if sys.platform == 'darwin':
        paths = [
            '/Applications/Antigravity.app/Contents/MacOS/Antigravity',
            os.path.expanduser('~/Applications/Antigravity.app/Contents/MacOS/Antigravity')
        ]
    elif sys.platform == 'win32':
        paths = [
            os.path.expandvars(r'%LOCALAPPDATA%\Programs\Antigravity\Antigravity.exe'),
            os.path.expandvars(r'%PROGRAMFILES%\Antigravity\Antigravity.exe')
        ]
    else:
        paths = [
            '/usr/bin/antigravity',
            '/usr/local/bin/antigravity',
            '/opt/Antigravity/antigravity',
            os.path.expanduser('~/.local/bin/antigravity')
        ]
    for p in paths:
        if os.path.isfile(p):
            return p
    return None

def launch_profile(name):
    bin_path = find_antigravity_binary()
    if not bin_path:
        print("Antigravity binary not found!")
        return False

    if name == 'personal':
        if sys.platform == 'darwin':
            subprocess.Popen(['/usr/bin/open', '-a', '/Applications/Antigravity.app'])
        else:
            subprocess.Popen([bin_path])
        return True

    # Isolated Profile
    p_dir = os.path.join(PROFILES_DIR, name)
    p_home = os.path.join(p_dir, 'home')
    gemini_dir = os.path.join(p_home, '.gemini')
    user_data = os.path.join(p_dir, 'user-data')
    os.makedirs(p_home, exist_ok=True)
    os.makedirs(gemini_dir, exist_ok=True)
    os.makedirs(user_data, exist_ok=True)

    env = os.environ.copy()
    env['HOME'] = p_home
    env['USERPROFILE'] = p_home
    env['ANTIGRAVITY_GEMINI_DIR'] = gemini_dir

    p = subprocess.Popen([bin_path, f'--user-data-dir={user_data}'], env=env)
    with open(os.path.join(p_dir, 'run.pid'), 'w') as pf:
        pf.write(str(p.pid) + '\n')
    return True

def stop_profile(name):
    pid_file = os.path.join(PROFILES_DIR, name, 'run.pid')
    if os.path.isfile(pid_file):
        try:
            with open(pid_file) as pf:
                pid = int(pf.read().strip())
            if sys.platform == 'win32':
                subprocess.call(['taskkill', '/F', '/PID', str(pid)])
            else:
                os.kill(pid, 15)
        except Exception:
            pass
        try:
            os.remove(pid_file)
        except Exception:
            pass

class SwitcherHTTPHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Quiet logging

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == '/' or url.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            ui_path = os.path.join(DIR, 'ui.html')
            with open(ui_path, 'rb') as f:
                self.wfile.write(f.read())
            return

        if url.path == '/api/profiles':
            data = get_profiles_data()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode('utf-8'))
            return

        super().do_GET()

    def do_POST(self):
        url = urlparse(self.path)
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length).decode('utf-8')) if length > 0 else {}

        if url.path == '/api/bridge':
            action = body.get('action')
            res = {'status': 'ok'}

            if action == 'getProfiles':
                profiles = get_profiles_data()
                res['eval'] = f"window.updateProfiles({json.dumps(profiles)});"

            elif action == 'launch':
                name = body.get('name', 'personal')
                launch_profile(name)
                time.sleep(0.5)
                profiles = get_profiles_data()
                res['eval'] = f"window.updateProfiles({json.dumps(profiles)});"

            elif action == 'stop':
                name = body.get('name', '')
                stop_profile(name)
                time.sleep(0.3)
                profiles = get_profiles_data()
                res['eval'] = f"window.updateProfiles({json.dumps(profiles)});"

            elif action == 'launchBoth':
                p1 = body.get('p1', 'personal')
                p2 = body.get('p2', 'company')
                launch_profile(p1)
                threading.Thread(target=lambda: (time.sleep(1.2), launch_profile(p2))).start()
                res['eval'] = "showToast('Launching both instances...');"

            elif action == 'switchPersonalAccount':
                email = body.get('email')
                if email:
                    success = core.switch_to(email)
                    profiles = get_profiles_data()
                    res['eval'] = f"window.updateProfiles({json.dumps(profiles)}); showToast('Switched to {email}');"

            elif action == 'removeAccountFromPool':
                email = body.get('email')
                if email:
                    core.delete_account(email)
                    profiles = get_profiles_data()
                    res['eval'] = f"window.updateProfiles({json.dumps(profiles)}); showToast('Account removed from pool');"

            elif action == 'createProfile':
                name = body.get('name', '').lower().strip()
                label = body.get('label', '').strip()
                if name:
                    reg = {}
                    if os.path.isfile(REG_FILE):
                        try:
                            with open(REG_FILE) as f:
                                reg = json.load(f)
                        except Exception:
                            pass
                    reg[name] = {'label': label or name.capitalize(), 'color': '#1a73e8', 'mode': 'clean'}
                    with open(REG_FILE, 'w') as f:
                        json.dump(reg, f, indent=2)
                    launch_profile(name)
                    profiles = get_profiles_data()
                    res['eval'] = f"window.updateProfiles({json.dumps(profiles)});"

            elif action == 'deleteProfile':
                name = body.get('name', '')
                if name and name != 'personal':
                    stop_profile(name)
                    p_dir = os.path.join(PROFILES_DIR, name)
                    shutil.rmtree(p_dir, ignore_errors=True)
                    if os.path.isfile(REG_FILE):
                        try:
                            with open(REG_FILE) as f:
                                reg = json.load(f)
                            if name in reg:
                                del reg[name]
                                with open(REG_FILE, 'w') as f:
                                    json.dump(reg, f, indent=2)
                        except Exception:
                            pass
                    profiles = get_profiles_data()
                    res['eval'] = f"window.updateProfiles({json.dumps(profiles)}); showToast('Profile deleted');"

            elif action == 'cleanCaches':
                core.clean_caches()
                res['eval'] = "showToast('Caches cleaned successfully');"

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(res).encode('utf-8'))
            return

        self.send_response(404)
        self.end_headers()

def open_desktop_window(url):
    # Try pywebview if installed
    try:
        import webview
        webview.create_window("Who's using Antigravity?", url, width=960, height=680, resizable=True)
        webview.start()
        return
    except ImportError:
        pass

    # Windows: Microsoft Edge in --app mode (standard on all Windows 10 & 11)
    if sys.platform == 'win32':
        edge_paths = [
            os.path.expandvars(r'%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe'),
            os.path.expandvars(r'%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe'),
            os.path.expandvars(r'%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe')
        ]
        for ep in edge_paths:
            if os.path.isfile(ep):
                subprocess.Popen([ep, f'--app={url}', '--window-size=960,680'])
                return

    # Linux / Chrome fallback
    browsers = ['google-chrome', 'google-chrome-stable', 'chromium-browser', 'chromium', 'brave-browser']
    for b in browsers:
        if shutil.which(b):
            subprocess.Popen([b, f'--app={url}', '--window-size=960,680'])
            return

    # Default browser fallback
    import webbrowser
    webbrowser.open(url)

def main():
    port = get_free_port()
    server = HTTPServer(('127.0.0.1', port), SwitcherHTTPHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    url = f"http://127.0.0.1:{port}"
    print(f"Antigravity Switcher running at {url}")
    open_desktop_window(url)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nExiting Antigravity Switcher...")

if __name__ == '__main__':
    main()
