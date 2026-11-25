import Cocoa
import WebKit
import UserNotifications

struct ProfileInfo: Codable {
    let name: String
    let label: String
    let email: String
    let running: Bool
    let pid: Int?
    let color: String
    let path: String
    let isPrimary: Bool
    let mode: String?
    let accounts: [String]?
    let activeAccount: String?
}

// MARK: - Quota Failover & Multi-Account Manager for Personal Workspace

class QuotaFailoverManager {
    static let shared = QuotaFailoverManager()
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    var logOffset: UInt64 = 0
    var isChecking = false
    var isEnabled = true
    
    var poolDir: URL {
        return homeDir.appendingPathComponent(".antigravity-profiles/personal-accounts")
    }
    
    var geminiDir: URL {
        return homeDir.appendingPathComponent(".gemini")
    }
    
    var logFile: URL {
        return homeDir.appendingPathComponent("Library/Logs/Antigravity/language_server.log")
    }
    
    func getSavedAccounts() -> [String] {
        try? FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        if let active = getActiveAccount() {
            saveCurrentAsAccount(email: active)
        }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: poolDir.path) else { return [] }
        return items.filter { item in
            let dir = poolDir.appendingPathComponent(item)
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue && !item.hasPrefix(".")
        }.sorted()
    }
    
    func getActiveAccount() -> String? {
        let accFile = geminiDir.appendingPathComponent("google_accounts.json")
        if let data = try? Data(contentsOf: accFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = json["active"] as? String, !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return active.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let standalone = geminiDir.appendingPathComponent("jetski-standalone-oauth-token")
        if let data = try? Data(contentsOf: standalone),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let email = json["id_token_email"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    func saveCurrentAsAccount(email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let pyScript = Bundle.main.url(forResource: "account_switcher_core", withExtension: "py")?.path ??
            homeDir.appendingPathComponent(".antigravity-profiles/account_switcher_core.py").path
        if FileManager.default.fileExists(atPath: pyScript) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [pyScript, "backup", trimmed]
            try? p.run()
            p.waitUntilExit()
            return
        }
        
        let targetDir = poolDir.appendingPathComponent(trimmed)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        
        let files = ["google_accounts.json", "oauth_creds.json", "jetski-standalone-oauth-token"]
        for f in files {
            let src = geminiDir.appendingPathComponent(f)
            let dst = targetDir.appendingPathComponent(f)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
    }
    
    func switchToAccount(email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        let pyScript = Bundle.main.url(forResource: "account_switcher_core", withExtension: "py")?.path ??
            homeDir.appendingPathComponent(".antigravity-profiles/account_switcher_core.py").path
        if FileManager.default.fileExists(atPath: pyScript) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [pyScript, "switch", trimmed]
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                return true
            }
        }
        
        let srcDir = poolDir.appendingPathComponent(trimmed)
        guard FileManager.default.fileExists(atPath: srcDir.appendingPathComponent("oauth_creds.json").path) else {
            return false
        }
        
        // 1. Save currently active account first
        if let current = getActiveAccount(), current != trimmed {
            saveCurrentAsAccount(email: current)
        }
        
        // 2. Copy target credentials to ~/.gemini/
        let files = ["google_accounts.json", "oauth_creds.json", "jetski-standalone-oauth-token"]
        for f in files {
            let src = srcDir.appendingPathComponent(f)
            let dst = geminiDir.appendingPathComponent(f)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
        
        return true
    }
    
    func deleteAccount(email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let active = getActiveAccount(), active.lowercased() == trimmed.lowercased() {
            return false // Cannot delete active account
        }
        
        let pyScript = Bundle.main.url(forResource: "account_switcher_core", withExtension: "py")?.path ??
            homeDir.appendingPathComponent(".antigravity-profiles/account_switcher_core.py").path
        if FileManager.default.fileExists(atPath: pyScript) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [pyScript, "delete", trimmed]
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        
        let targetDir = poolDir.appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: targetDir.path) {
            try? FileManager.default.removeItem(at: targetDir)
            return true
        }
        return false
    }
    
    func checkForQuotaExhaustionAndFailover() -> String? {
        guard isEnabled else { return nil }
        guard !isChecking else { return nil }
        isChecking = true
        defer { isChecking = false }
        
        // Ensure active account is mirrored in pool
        if let active = getActiveAccount() {
            saveCurrentAsAccount(email: active)
        }
        
        guard FileManager.default.fileExists(atPath: logFile.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return nil }
        
        let fileSize = handle.seekToEndOfFile()
        if logOffset == 0 || logOffset > fileSize {
            // First run: only inspect recent 16KB
            logOffset = fileSize > 16384 ? (fileSize - 16384) : 0
        }
        
        handle.seek(toFileOffset: logOffset)
        let data = handle.readDataToEndOfFile()
        logOffset = fileSize
        
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        
        // Check for quota exhaustion indicators
        let isQuotaError = text.contains("RESOURCE_EXHAUSTED") ||
                           text.contains("Quota exceeded") ||
                           text.contains("rateLimitExceeded") ||
                           text.contains("code: 429")
                           
        if isQuotaError {
            let current = getActiveAccount() ?? ""
            let all = getSavedAccounts()
            let alternatives = all.filter { $0 != current }
            
            if let nextAccount = alternatives.first {
                let success = switchToAccount(email: nextAccount)
                if success {
                    notifyUserOfFailover(from: current, to: nextAccount)
                    return nextAccount
                }
            }
        }
        
        return nil
    }
    
    func notifyUserOfFailover(from: String, to: String) {
        let content = UNMutableNotificationContent()
        content.title = "⚡ Antigravity Quota Auto-Switched"
        content.body = "Quota reached on \(from). Seamlessly switched to \(to) so your work continues without interruption!"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

class SwitcherWebView: WKWebView {
    var isModalOpen = false
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        // When modal is open, don't drag so modal inputs and buttons get clicks
        if isModalOpen {
            super.mouseDown(with: event)
            return
        }
        
        // Settings button at top right: x > bounds.width - 85, y > bounds.height - 85
        let isSettingsButton = (point.x > bounds.width - 85 && point.x < bounds.width - 20 && point.y > bounds.height - 85 && point.y < bounds.height - 25)
        
        // Traffic lights (close/min) at top left
        let isTrafficLights = (point.x < 75 && point.y > bounds.height - 35)
        
        // Top 140px header area (Google logo, title, subtitle, empty space)
        let isHeaderArea = (point.y > bounds.height - 140 && !isSettingsButton && !isTrafficLights)
        
        // Outer window margin (left, right, bottom margins)
        let isMargin = (point.x < 24 || point.x > bounds.width - 24 || point.y < 24)
        
        if isHeaderArea || isMargin {
            window?.performDrag(with: event)
            return
        }
        
        super.mouseDown(with: event)
    }
}

class SwitcherWindowController: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var webView: SwitcherWebView!
    var statusTimer: Timer?
    var signinProcess: Process?
    var signinApp: NSRunningApplication?
    var signinTimer: Timer?
    
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    var profilesDir: URL {
        return homeDir.appendingPathComponent(".antigravity-profiles")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        
        let width: CGFloat = 880
        let height: CGFloat = 660
        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let rect = NSRect(
            x: (screenSize.width - width) / 2,
            y: (screenSize.height - height) / 2,
            width: width,
            height: height
        )
        
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "Who's using Antigravity?"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 780, height: 560)
        
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "switcher")
        config.userContentController = userContent
        
        // Enable file access and web inspector
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        webView = SwitcherWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        loadUI()
        
        // Request user notification permissions for quota auto-failover alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // Start periodic status refresh timer and quota exhaustion watcher (every 1.5 seconds)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            _ = QuotaFailoverManager.shared.checkForQuotaExhaustionAndFailover()
            self.sendProfiles()
        }
        if let timer = statusTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        // Listen to macOS app lifecycle notifications for instantaneous launch/quit updates
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendProfiles()
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendProfiles()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
    }
    
    func loadUI() {
        var htmlUrl = Bundle.main.url(forResource: "ui", withExtension: "html")
        if htmlUrl == nil {
            let fallback = homeDir.appendingPathComponent(".antigravity-profiles/ui.html")
            if FileManager.default.fileExists(atPath: fallback.path) {
                htmlUrl = fallback
            }
        }
        
        if let url = htmlUrl, let htmlString = try? String(contentsOf: url, encoding: .utf8) {
            // Load string directly in memory so WebKit does not request filesystem sandbox permissions
            webView.loadHTMLString(htmlString, baseURL: nil)
        }
    }
    
    // MARK: - Window & Dock Reopening Lifecycle
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false // Hide rather than destroy, so clicking Dock re-opens instantly
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        showWindow()
    }
    
    @objc func showWindow() {
        guard window != nil else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.setIsVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        sendProfiles()
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show Switcher", action: #selector(showWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())
        
        let launchBothItem = NSMenuItem(title: "Launch Both Simultaneously", action: #selector(dockLaunchBoth), keyEquivalent: "")
        launchBothItem.target = self
        menu.addItem(launchBothItem)
        return menu
    }
    
    @objc func dockLaunchBoth() {
        launchProfile(name: "personal", ide: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.launchProfile(name: "company", ide: false)
        }
    }
    
    // MARK: - WebKit Bridge Messages
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "switcher", let dict = message.body as? [String: Any] else { return }
        let action = dict["action"] as? String ?? ""
        
        switch action {
        case "getProfiles":
            sendProfiles()
        case "launch":
            if let name = dict["name"] as? String {
                let ide = dict["ide"] as? Bool ?? false
                launchProfile(name: name, ide: ide)
            }
        case "launchBoth":
            let p1 = dict["p1"] as? String ?? "personal"
            let p2 = dict["p2"] as? String ?? "company"
            launchProfile(name: p1, ide: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.launchProfile(name: p2, ide: false)
            }
        case "stop":
            if let name = dict["name"] as? String {
                stopProfile(name: name)
            }
        case "createProfile":
            let name = dict["name"] as? String ?? ""
            let label = dict["label"] as? String ?? ""
            let mode = dict["mode"] as? String ?? "clean"
            createProfile(name: name, label: label, cloneFromPersonal: (mode == "clone"))
        case "deleteProfile":
            if let name = dict["name"] as? String {
                deleteProfile(name: name)
            }
        case "modalState":
            if let open = dict["open"] as? Bool {
                self.webView.isModalOpen = open
            }
        case "startWindowDrag":
            if let event = NSApp.currentEvent, event.type == .leftMouseDown {
                self.window.performDrag(with: event)
            }
        case "switchPersonalAccount":
            if let email = dict["email"] as? String {
                let autoRestart = dict["autoRestart"] as? Bool ?? false
                let success = QuotaFailoverManager.shared.switchToAccount(email: email)
                if success {
                    sendProfiles()
                    if autoRestart {
                        restartAntigravity()
                    }
                }
            }
        case "setTheme":
            if let theme = dict["theme"] as? String {
                DispatchQueue.main.async {
                    if theme == "dark" {
                        self.window.appearance = NSAppearance(named: .darkAqua)
                    } else if theme == "light" {
                        self.window.appearance = NSAppearance(named: .aqua)
                    } else {
                        self.window.appearance = nil
                    }
                }
            }
        case "deletePersonalAccount":
            if let email = dict["email"] as? String {
                let success = QuotaFailoverManager.shared.deleteAccount(email: email)
                if success {
                    dispatchNotification(title: "Account Removed", body: "\(email) was removed from your personal switcher pool.")
                }
                sendProfiles()
            }
        case "cleanCaches":
            cleanAntigravityCaches()
            dispatchNotification(title: "Caches Cleaned", body: "Antigravity update and temporary cache files cleared.")
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript("if (window.onCachesCleaned) window.onCachesCleaned();", completionHandler: nil)
            }
        case "resyncKeychain":
            resyncActiveKeychain()
            dispatchNotification(title: "Keychain Synced", body: "Active Google credentials re-synced to macOS Keychain.")
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript("if (window.onKeychainSynced) window.onKeychainSynced();", completionHandler: nil)
            }
        case "saveCurrentAccount":
            if let email = QuotaFailoverManager.shared.getActiveAccount() {
                QuotaFailoverManager.shared.saveCurrentAsAccount(email: email)
                sendProfiles()
            }
        case "triggerSignIn":
            startAccountCSignIn()
            sendProfiles()
        case "cancelSignIn":
            cancelAccountCSignIn()
            sendProfiles()
        case "toggleAutoFailover":
            if let enabled = dict["enabled"] as? Bool {
                QuotaFailoverManager.shared.isEnabled = enabled
            }
        case "restartAntigravity":
            restartAntigravity()
        default:
            break
        }
    }
    
    // MARK: - Accurate Profile PID Resolution & Status
    
    func resolveAllRunningProfiles() -> [String: Int] {
        var allApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity")
        allApps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity.ide"))
        
        let activeApps = allApps.filter { !$0.isTerminated }
        var runningPids = Set(activeApps.map { Int($0.processIdentifier) })
        var resolved: [String: Int] = [:]
        
        let regFile = profilesDir.appendingPathComponent("profiles.json")
        var customProfileNames = ["company"]
        if let data = try? Data(contentsOf: regFile),
           let reg = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (key, _) in reg where key != "personal" {
                if !customProfileNames.contains(key) {
                    customProfileNames.append(key)
                }
            }
        }
        
        // Match each custom/isolated profile
        for pName in customProfileNames {
            let pDir = profilesDir.appendingPathComponent(pName)
            var matchedPid: Int? = nil
            
            // 1. Check SingletonLock in user-data
            let lockFile = pDir.appendingPathComponent("user-data/SingletonLock")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lockFile.path),
               let last = target.split(separator: "-").last,
               let pid = Int(last),
               runningPids.contains(pid) {
                matchedPid = pid
            }
            
            // 2. Check SingletonLock in user-data-ide
            if matchedPid == nil {
                let ideLockFile = pDir.appendingPathComponent("user-data-ide/SingletonLock")
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: ideLockFile.path),
                   let last = target.split(separator: "-").last,
                   let pid = Int(last),
                   runningPids.contains(pid) {
                    matchedPid = pid
                }
            }
            
            // 3. Fallback to run.pid
            if matchedPid == nil {
                let pidFile = pDir.appendingPathComponent("run.pid")
                if let content = try? String(contentsOfFile: pidFile.path, encoding: .utf8),
                   let pid = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)),
                   runningPids.contains(pid) {
                    matchedPid = pid
                }
            }
            
            if let pid = matchedPid {
                resolved[pName] = pid
                runningPids.remove(pid)
                let pidFile = pDir.appendingPathComponent("run.pid")
                try? "\(pid)\n".write(to: pidFile, atomically: true, encoding: .utf8)
            }
        }
        
        // Any remaining Antigravity process belongs to Personal (the primary default instance)
        if let personalPid = runningPids.first {
            resolved["personal"] = personalPid
        }
        
        return resolved
    }
    
    func getProfileStatus(name: String) -> (running: Bool, pid: Int?) {
        let pName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = resolveAllRunningProfiles()
        if let pid = resolved[pName] {
            return (true, pid)
        }
        return (false, nil)
    }
    
    func getProfileEmail(name: String) -> String {
        let pName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        if pName == "personal" {
            let accFile = homeDir.appendingPathComponent(".gemini/google_accounts.json")
            if let data = try? Data(contentsOf: accFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let active = json["active"] as? String, !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return active.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "madanlabidyasar.mo@gmail.com"
        }
        
        // For custom/secondary profiles, read from their own isolated user-data
        let storageFile = profilesDir.appendingPathComponent("\(pName)/user-data/app_storage.json")
        if let data = try? Data(contentsOf: storageFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let email = json["agy.onboarding.lastLoginUsername"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let accFile = profilesDir.appendingPathComponent("\(pName)/home/.gemini/google_accounts.json")
        if let data = try? Data(contentsOf: accFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = json["active"] as? String, !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return active.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return "Not signed in"
    }
    
    func sendProfiles() {
        var profilesList: [ProfileInfo] = []
        let regFile = profilesDir.appendingPathComponent("profiles.json")
        
        var reg: [String: [String: Any]] = [:]
        if !FileManager.default.fileExists(atPath: regFile.path) {
            reg["personal"] = ["label": "Personal", "color": "#9C27B0", "mode": "primary"]
            reg["company"] = ["label": "Company", "color": "#1A73E8", "mode": "clean"]
            if let data = try? JSONSerialization.data(withJSONObject: reg, options: .prettyPrinted) {
                try? data.write(to: regFile)
            }
        } else if let data = try? Data(contentsOf: regFile),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            reg = parsed
        }
        
        // Ensure personal is always present
        if reg["personal"] == nil {
            reg["personal"] = ["label": "Personal", "color": "#9C27B0", "mode": "primary"]
        }
        
        let resolved = resolveAllRunningProfiles()
        
        for (name, info) in reg {
            let pid = resolved[name.lowercased()]
            let isRunning = (pid != nil)
            let email = getProfileEmail(name: name)
            let label = info["label"] as? String ?? name.capitalized
            let color = info["color"] as? String ?? "#1A73E8"
            let mode = info["mode"] as? String ?? (name == "personal" ? "primary" : "clean")
            let isPrimary = (name == "personal")
            let savedAccounts = isPrimary ? QuotaFailoverManager.shared.getSavedAccounts() : nil
            let activeAcc = isPrimary ? (QuotaFailoverManager.shared.getActiveAccount() ?? email) : nil
            let p = ProfileInfo(
                name: name,
                label: label,
                email: email,
                running: isRunning,
                pid: pid,
                color: color,
                path: isPrimary ? homeDir.appendingPathComponent(".gemini").path : profilesDir.appendingPathComponent(name).path,
                isPrimary: isPrimary,
                mode: mode,
                accounts: savedAccounts,
                activeAccount: activeAcc
            )
            profilesList.append(p)
        }
        
        profilesList.sort { a, b in
            if a.name == "personal" { return true }
            if b.name == "personal" { return false }
            if a.name == "company" { return true }
            if b.name == "company" { return false }
            return a.name < b.name
        }
        
        if let encoded = try? JSONEncoder().encode(profilesList),
           let jsonStr = String(data: encoded, encoding: .utf8) {
            let js = "window.renderProfiles(\(jsonStr));"
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
    
    // MARK: - Direct Account C Sign-In Flow
    
    func startAccountCSignIn() {
        // 1. Ensure current active account is saved
        if let active = QuotaFailoverManager.shared.getActiveAccount() {
            QuotaFailoverManager.shared.saveCurrentAsAccount(email: active)
        }
        
        let binaryPath = "/Applications/Antigravity.app/Contents/MacOS/Antigravity"
        guard FileManager.default.fileExists(atPath: binaryPath) else { return }
        
        let signinDir = profilesDir.appendingPathComponent("signin-helper")
        let signinHome = signinDir.appendingPathComponent("home")
        let signinUserData = signinDir.appendingPathComponent("user-data")
        let signinGemini = signinHome.appendingPathComponent(".gemini")
        
        // Clean previous temp attempt
        try? FileManager.default.removeItem(at: signinDir)
        try? FileManager.default.createDirectory(at: signinUserData, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: signinGemini, withIntermediateDirectories: true)
        
        // Disable autoCheckForUpdates
        let storageFile = signinUserData.appendingPathComponent("app_storage.json")
        let storageDict: [String: Any] = ["autoCheckForUpdates": "false"]
        if let data = try? JSONSerialization.data(withJSONObject: storageDict, options: .prettyPrinted) {
            try? data.write(to: storageFile)
        }
        
        let appBundlePath = binaryPath.contains("Antigravity IDE") ?
            "/Applications/Antigravity IDE.app" :
            "/Applications/Antigravity.app"
        let appURL = URL(fileURLWithPath: appBundlePath)
        
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--user-data-dir=\(signinUserData.path)"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = signinHome.path
        env.removeValue(forKey: "ANTIGRAVITY_GEMINI_DIR")
        config.environment = env
        config.createsNewApplicationInstance = true
        config.activates = true
        
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] runningApp, error in
            if let app = runningApp {
                self?.signinApp = app
            }
        }
        
        // Watch for sign-in completion in signinGemini
        signinTimer?.invalidate()
        signinTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else { return }
                
                var detectedEmail: String? = nil
                
                // 1. Check jetski-standalone-oauth-token (Primary modern Antigravity auth format)
                let standalone = signinGemini.appendingPathComponent("jetski-standalone-oauth-token")
                if let data = try? Data(contentsOf: standalone),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let email = json["id_token_email"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detectedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // 2. Check google_accounts.json
                if detectedEmail == nil {
                    let accFile = signinGemini.appendingPathComponent("google_accounts.json")
                    if let data = try? Data(contentsOf: accFile),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let active = json["active"] as? String, !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        detectedEmail = active.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                
                // 3. Check user-data/app_storage.json
                if detectedEmail == nil {
                    let storageFile = signinUserData.appendingPathComponent("app_storage.json")
                    if let data = try? Data(contentsOf: storageFile),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let username = json["jetski.onboarding.lastLoginUsername"] as? String, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        detectedEmail = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                
                guard let email = detectedEmail else { return }
                
                // Success! Copy credentials to personal-accounts pool
                let targetDir = QuotaFailoverManager.shared.poolDir.appendingPathComponent(email)
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                
                // Copy all existing credential files
                for f in ["google_accounts.json", "oauth_creds.json", "jetski-standalone-oauth-token"] {
                    let src = signinGemini.appendingPathComponent(f)
                    let dst = targetDir.appendingPathComponent(f)
                    if FileManager.default.fileExists(atPath: src.path) {
                        try? FileManager.default.removeItem(at: dst)
                        try? FileManager.default.copyItem(at: src, to: dst)
                    }
                }
                
                // Ensure google_accounts.json exists
                let gaPath = targetDir.appendingPathComponent("google_accounts.json")
                if !FileManager.default.fileExists(atPath: gaPath.path) {
                    let gaDict: [String: Any] = ["active": email, "old": []]
                    if let d = try? JSONSerialization.data(withJSONObject: gaDict, options: .prettyPrinted) {
                        try? d.write(to: gaPath)
                    }
                }
                
                // Ensure oauth_creds.json exists
                let credsPath = targetDir.appendingPathComponent("oauth_creds.json")
                if !FileManager.default.fileExists(atPath: credsPath.path),
                   let tokenData = try? Data(contentsOf: standalone),
                   let tokenJson = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
                   let t = tokenJson["token"] as? [String: Any] {
                    let credsDict: [String: Any] = [
                        "access_token": t["access_token"] as? String ?? "",
                        "refresh_token": t["refresh_token"] as? String ?? "",
                        "token_type": t["token_type"] as? String ?? "Bearer",
                        "scope": "https://www.googleapis.com/auth/cloud-platform openid https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email"
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: credsDict, options: .prettyPrinted) {
                        try? d.write(to: credsPath)
                    }
                }
                
                // Clean up and terminate temp window
                timer.invalidate()
                self.signinTimer = nil
                self.signinApp?.terminate()
                self.signinApp = nil
                self.signinProcess?.terminate()
                self.signinProcess = nil
                try? FileManager.default.removeItem(at: signinDir)
                
                // Notify UI and user
                self.sendProfiles()
                self.dispatchNotification(title: "Google Account Added", body: "\(email) has been linked to your Personal profile.")
                
                // Tell WebKit that signin succeeded
                DispatchQueue.main.async {
                    self.webView.evaluateJavaScript("if (window.onSignInHelperComplete) window.onSignInHelperComplete('\(email)');", completionHandler: nil)
                }
            }
        }
    
    func cancelAccountCSignIn() {
        signinTimer?.invalidate()
        signinTimer = nil
        signinApp?.terminate()
        signinApp = nil
        signinProcess?.terminate()
        signinProcess = nil
        let signinDir = profilesDir.appendingPathComponent("signin-helper")
        try? FileManager.default.removeItem(at: signinDir)
    }
    
    func dispatchNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    func cleanAntigravityCaches() {
        let pyScript = Bundle.main.url(forResource: "account_switcher_core", withExtension: "py")?.path ??
            homeDir.appendingPathComponent(".antigravity-profiles/account_switcher_core.py").path
        if FileManager.default.fileExists(atPath: pyScript) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [pyScript, "clean-caches"]
            try? p.run()
            p.waitUntilExit()
        }
    }
    
    func resyncActiveKeychain() {
        let pyScript = Bundle.main.url(forResource: "account_switcher_core", withExtension: "py")?.path ??
            homeDir.appendingPathComponent(".antigravity-profiles/account_switcher_core.py").path
        if FileManager.default.fileExists(atPath: pyScript) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [pyScript, "resync-keychain"]
            try? p.run()
            p.waitUntilExit()
        }
    }
    
    func restartAntigravity() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity")
        for app in apps {
            app.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Wait up to 1.5 seconds for graceful exit
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity").filter { !$0.isTerminated }
                if remaining.isEmpty {
                    break
                }
                usleep(100000)
            }
            
            // Force terminate any stubborn lingering instances
            let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity").filter { !$0.isTerminated }
            for r in remaining {
                r.forceTerminate()
            }
            
            usleep(300000) // Grace period for SQLite locks to fully release
            
            // Re-apply the target active account to state.vscdb now that Antigravity is closed!
            if let active = QuotaFailoverManager.shared.getActiveAccount() {
                _ = QuotaFailoverManager.shared.switchToAccount(email: active)
            }
            
            DispatchQueue.main.async {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Antigravity.app"), configuration: config, completionHandler: nil)
            }
        }
    }
    
    func launchProfile(name: String, ide: Bool) {
        let pName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let status = getProfileStatus(name: pName)
        
        // If already running, activate window immediately via standard AppKit API
        if status.running, let pid = status.pid {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.activate()
            }
            sendProfiles()
            return
        }
        
        let appBundlePath = ide ?
            "/Applications/Antigravity IDE.app" :
            "/Applications/Antigravity.app"
        let appURL = URL(fileURLWithPath: appBundlePath)
        
        guard FileManager.default.fileExists(atPath: appBundlePath) else {
            print("Application not found: \(appBundlePath)")
            return
        }
        
        var procArgs: [String] = []
        var env = ProcessInfo.processInfo.environment
        
        if pName == "personal" && !ide {
            // Launch the REAL primary Antigravity app with all existing conversations & projects intact!
            // Clean stale update caches to permanently prevent "Restart to update" prompt
            let cacheDir = homeDir.appendingPathComponent("Library/Caches/com.google.antigravity")
            let shipItDir = homeDir.appendingPathComponent("Library/Caches/com.google.antigravity.ShipIt")
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("pending"))
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("update.zip"))
            try? FileManager.default.removeItem(at: shipItDir.appendingPathComponent("ShipItState.plist"))
            
            let appStorage = homeDir.appendingPathComponent("Library/Application Support/Antigravity/app_storage.json")
            if let data = try? Data(contentsOf: appStorage),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["autoCheckForUpdates"] as? String != "false" {
                    json["autoCheckForUpdates"] = "false"
                    if let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                        try? updated.write(to: appStorage)
                    }
                }
            }
            
            env["HOME"] = homeDir.path
            env.removeValue(forKey: "ANTIGRAVITY_GEMINI_DIR")
            procArgs = []
        } else {
            // Dedicated isolated profile
            let pDir = profilesDir.appendingPathComponent(pName)
            let pHome = pDir.appendingPathComponent("home")
            let geminiDir = pHome.appendingPathComponent(".gemini")
            let userDataDir = ide ? pDir.appendingPathComponent("user-data-ide") : pDir.appendingPathComponent("user-data")
            
            try? FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
            
            // Disable autoCheckForUpdates and clean update cache to eliminate "Restart to update" loop
            let storageFile = userDataDir.appendingPathComponent("app_storage.json")
            var storageDict: [String: Any] = [:]
            if let data = try? Data(contentsOf: storageFile),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                storageDict = parsed
            }
            storageDict["autoCheckForUpdates"] = "false"
            if let updatedData = try? JSONSerialization.data(withJSONObject: storageDict, options: .prettyPrinted) {
                try? updatedData.write(to: storageFile)
            }
            
            let cacheDir = pHome.appendingPathComponent("Library/Caches/com.google.antigravity")
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("pending"))
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("update.zip"))
            
            env["HOME"] = pHome.path
            env["ANTIGRAVITY_GEMINI_DIR"] = geminiDir.path
            procArgs = ["--user-data-dir=\(userDataDir.path)"]
        }
        
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = procArgs
        config.environment = env
        config.createsNewApplicationInstance = (pName != "personal")
        config.activates = true
        
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] runningApp, error in
            guard let self = self else { return }
            if let error = error {
                print("Failed to launch \(pName) via NSWorkspace: \(error)")
                let fallback = Process()
                fallback.executableURL = URL(fileURLWithPath: ide ? "\(appBundlePath)/Contents/MacOS/Electron" : "\(appBundlePath)/Contents/MacOS/Antigravity")
                fallback.arguments = procArgs
                fallback.environment = env
                try? fallback.run()
                if let pid = fallback.processIdentifier as pid_t?, pName != "personal" {
                    let pidFile = self.profilesDir.appendingPathComponent("\(pName)/run.pid")
                    try? "\(pid)\n".write(to: pidFile, atomically: true, encoding: .utf8)
                }
            } else if let app = runningApp {
                let spawnedPid = app.processIdentifier
                if pName != "personal" {
                    let pidFile = self.profilesDir.appendingPathComponent("\(pName)/run.pid")
                    try? "\(spawnedPid)\n".write(to: pidFile, atomically: true, encoding: .utf8)
                }
            }
            
            // Fast status refresh loop after launching
            for delay in [0.3, 0.8, 1.5, 3.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendProfiles()
                }
            }
        }
    }
    
    func stopProfile(name: String) {
        let pName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let status = getProfileStatus(name: pName)
        if let pid = status.pid {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.terminate()
            } else {
                kill(pid_t(pid), SIGTERM)
            }
            
            if pName != "personal" {
                let pidFile = profilesDir.appendingPathComponent("\(pName)/run.pid")
                try? FileManager.default.removeItem(at: pidFile)
            }
            
            for delay in [0.2, 0.6, 1.2, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendProfiles()
                }
            }
        }
    }
    
    func deleteProfile(name: String) {
        let pName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard pName != "personal" && !pName.isEmpty else { return }
        
        stopProfile(name: pName)
        
        let pDir = profilesDir.appendingPathComponent(pName)
        try? FileManager.default.removeItem(at: pDir)
        
        let regFile = profilesDir.appendingPathComponent("profiles.json")
        var reg: [String: [String: Any]] = [:]
        if let data = try? Data(contentsOf: regFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            reg = parsed
        }
        reg.removeValue(forKey: pName)
        if let data = try? JSONSerialization.data(withJSONObject: reg, options: .prettyPrinted) {
            try? data.write(to: regFile)
        }
        
        sendProfiles()
    }
    
    func safeCopy(from src: URL, to dst: URL) {
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }
        if FileManager.default.fileExists(atPath: src.path) {
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }
    
    func createProfile(name: String, label: String, cloneFromPersonal: Bool) {
        let pName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pName.isEmpty else { return }
        
        let pDir = profilesDir.appendingPathComponent(pName)
        let pHome = pDir.appendingPathComponent("home")
        let geminiDir = pHome.appendingPathComponent(".gemini")
        let userDataDir = pDir.appendingPathComponent("user-data")
        
        try? FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        
        // Link developer configs (NO .ssh to avoid macOS privacy alerts)
        for item in [".gitconfig", ".zshrc", ".bashrc", ".local", ".config"] {
            let src = homeDir.appendingPathComponent(item)
            let dst = pHome.appendingPathComponent(item)
            if FileManager.default.fileExists(atPath: src.path) && !FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
            }
        }
        
        // Link skills and plugins
        let profileConfig = geminiDir.appendingPathComponent("config")
        try? FileManager.default.createDirectory(at: profileConfig, withIntermediateDirectories: true)
        for sub in ["skills", "plugins"] {
            let src = homeDir.appendingPathComponent(".gemini/config/\(sub)")
            let dst = profileConfig.appendingPathComponent(sub)
            if FileManager.default.fileExists(atPath: src.path) && !FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
            }
        }
        
        let targetAntigravity = geminiDir.appendingPathComponent("antigravity")
        let targetProjects = geminiDir.appendingPathComponent("projects.json")
        
        if cloneFromPersonal {
            // Clone snapshot of conversations & projects from Personal (A)
            let realAntigravity = homeDir.appendingPathComponent(".gemini/antigravity")
            let realProjects = homeDir.appendingPathComponent(".gemini/projects.json")
            
            safeCopy(from: realProjects, to: targetProjects)
            try? FileManager.default.createDirectory(at: targetAntigravity, withIntermediateDirectories: true)
            
            for f in ["conversation_summaries.db", "conversation_summaries.db-shm", "conversation_summaries.db-wal"] {
                let src = realAntigravity.appendingPathComponent(f)
                let dst = targetAntigravity.appendingPathComponent(f)
                safeCopy(from: src, to: dst)
            }
            safeCopy(from: realAntigravity.appendingPathComponent("conversations"), to: targetAntigravity.appendingPathComponent("conversations"))
            safeCopy(from: realAntigravity.appendingPathComponent("brain"), to: targetAntigravity.appendingPathComponent("brain"))
        } else {
            // Clean isolated workspace: starts with 0 conversations and empty projects
            try? FileManager.default.createDirectory(at: targetAntigravity, withIntermediateDirectories: true)
            try? "{\"projects\": {}}".write(to: targetProjects, atomically: true, encoding: .utf8)
        }
        
        // Initialize app_storage.json with autoCheckForUpdates disabled
        let storageFile = userDataDir.appendingPathComponent("app_storage.json")
        var storageDict: [String: Any] = [:]
        if let data = try? Data(contentsOf: storageFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            storageDict = parsed
        }
        storageDict["autoCheckForUpdates"] = "false"
        if let updatedData = try? JSONSerialization.data(withJSONObject: storageDict, options: .prettyPrinted) {
            try? updatedData.write(to: storageFile)
        }
        
        // Update registry
        let regFile = profilesDir.appendingPathComponent("profiles.json")
        var reg: [String: [String: Any]] = [:]
        if let data = try? Data(contentsOf: regFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            reg = parsed
        }
        
        let pLabel = label.isEmpty ? pName.capitalized : label
        let color = cloneFromPersonal ? "#1A73E8" : "#137333"
        reg[pName] = [
            "name": pName,
            "label": pLabel,
            "color": color,
            "mode": cloneFromPersonal ? "clone" : "clean",
            "created_at": ISO8601DateFormatter().string(from: Date())
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: reg, options: .prettyPrinted) {
            try? data.write(to: regFile)
        }
        
        sendProfiles()
        launchProfile(name: pName, ide: false)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sendProfiles()
    }
}

let app = NSApplication.shared
let delegate = SwitcherWindowController()
app.delegate = delegate
app.run()
