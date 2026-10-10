import AppKit
import ApplicationServices

/// Where a dictation or a Transform's text is going. The app says most of it — Mail is email, Codex is a coding
/// agent — but a browser can be Gmail, Slack or claude.ai, and Claude's own app is a chat or Claude Code depending on
/// the tab. For those the focused window is read, the way Wispr Flow and VoiceInk read the app you're in: the web
/// address of the page (Claude's Code tab is `claude.ai/epitaxy/…`, a chat `claude.ai/chat/…`), or a browser's address
/// bar. Through Accessibility, which Murmur already has; read at key-down in the background while the user talks, and
/// nothing is kept. Used by "Auto (match app)" formatting (`DestinationShaper`) and by Prompt Engineer, which writes a
/// coding agent a different prompt than a chat assistant.
enum DestinationDetector {
    static let browserBundleIDs: Set<String> = [
        "com.google.chrome", "com.google.chrome.canary", "com.apple.safari", "com.apple.safaritechnologypreview",
        "company.thebrowser.browser", "company.thebrowser.dia", "com.microsoft.edgemac", "com.brave.browser",
        "org.mozilla.firefox", "com.operasoftware.opera", "com.vivaldi.vivaldi", "ai.perplexity.comet"]

    /// Apps that only ever hold a prompt for a coding agent: Codex, terminals (Claude Code and Codex CLI), editors.
    static let codingBundleIDs: Set<String> = Set((DeveloperVocabulary.terminalBundleIDs.union([
        "com.openai.codex", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders", "dev.zed.Zed", "com.apple.dt.Xcode", "dev.warp.Warp", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty"])).map { $0.lowercased() })

    static let chatBundleIDs: Set<String> = ["com.openai.chat", "ai.perplexity.mac", "com.google.geminimacos"]

    // MARK: - Deciding (pure, self-tested)

    /// From the app and, when it was readable, the address of the page its focused window shows.
    static func destination(bundleID: String?, pageURL: URL?) -> Destination? {
        guard let id = bundleID?.lowercased() else { return nil }
        if let known = DestinationShaper.destination(forBundleID: id) { return known }
        if id == "com.anthropic.claudefordesktop" {
            // The Code tab is Claude Code; everything else in the app is a chat.
            return pageURL.flatMap(webDestination) ?? .aiChat
        }
        if codingBundleIDs.contains(id) { return .codingAgent }
        if chatBundleIDs.contains(id) { return .aiChat }
        if browserBundleIDs.contains(id), let pageURL { return webDestination(pageURL) }
        return nil
    }

    /// What kind of place a web page is, by its address.
    static func webDestination(_ url: URL) -> Destination? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func on(_ domains: [String]) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        if on(["claude.ai"]) { return path.hasPrefix("/code") || path.hasPrefix("/epitaxy") ? .codingAgent : .aiChat }
        if on(["chatgpt.com", "chat.openai.com"]) { return path.hasPrefix("/codex") ? .codingAgent : .aiChat }
        if on(["gemini.google.com", "perplexity.ai", "grok.com", "chat.mistral.ai", "copilot.microsoft.com",
               "chat.deepseek.com"]) { return .aiChat }
        if on(["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "mail.yahoo.com",
               "app.fastmail.com", "mail.proton.me", "app.hey.com"]) { return .email }
        if on(["app.slack.com", "web.whatsapp.com", "discord.com", "teams.microsoft.com", "teams.live.com",
               "web.telegram.org", "messenger.com", "chat.google.com"]) { return .messaging }
        if on(["linkedin.com"]), path.hasPrefix("/messaging") { return .messaging }
        return nil
    }

    // MARK: - Reading the window

    /// The address of the page the app's focused window shows: a web view's own address, or a browser's address bar.
    static func pageURL(pid: pid_t, budget: TimeInterval = 0.3, maxElements: Int = 2_500) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL, FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let attributes = [kAXRoleAttribute, "AXURL", kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute,
                          "AXChildrenInNavigationOrder"] as CFArray
        let deadline = Date().addingTimeInterval(budget)
        var stack: [AXUIElement] = [window as! AXUIElement]
        var visited = 0
        var addressBar: URL?
        while let element = stack.popLast(), visited < maxElements, Date() < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
                  let list = values as? [AnyObject], list.count == 6 else { continue }
            let role = list[0] as? String ?? ""
            if role == kAXMenuBarRole as String { continue }
            if role == "AXWebArea", let url = list[1] as? URL, url.scheme == "https" || url.scheme == "http" {
                return url
            }
            if addressBar == nil, role == kAXTextFieldRole as String,
               (list[2] as? String)?.lowercased().contains("address") == true,
               let typed = (list[3] as? String)?.trimmingCharacters(in: .whitespaces), !typed.contains(" "),
               typed.contains(".") {
                addressBar = URL(string: typed.contains("://") ? typed : "https://" + typed)
            }
            var children = list[4] as? [AXUIElement] ?? []
            if children.isEmpty { children = list[5] as? [AXUIElement] ?? [] }
            stack.append(contentsOf: children.reversed())
        }
        return addressBar
    }

    /// Reads the window only where the app alone can't tell (browsers, Claude).
    static func detect(bundleID: String?, pid: pid_t?) -> Destination? {
        let id = bundleID?.lowercased() ?? ""
        let needsWindow = browserBundleIDs.contains(id) || id == "com.anthropic.claudefordesktop"
        let url = needsWindow ? pid.flatMap { pageURL(pid: $0) } : nil
        return destination(bundleID: bundleID, pageURL: url)
    }

    // MARK: - The dictation in progress

    private static let lock = NSLock()
    nonisolated(unsafe) private static var detected: (bundleID: String, destination: Destination?)?

    /// Key-down: work out where this dictation is going, in the background while the user talks.
    static func refresh(bundleID: String?, pid: pid_t?) {
        lock.lock(); detected = nil; lock.unlock()
        guard let bundleID, pid != ProcessInfo.processInfo.processIdentifier else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let destination = detect(bundleID: bundleID, pid: pid)
            lock.lock(); detected = (bundleID, destination); lock.unlock()
        }
    }

    /// Where the dictation for `bundleID` is going: what key-down found in its window, else what the app alone says.
    static func current(for bundleID: String?) -> Destination? {
        lock.lock()
        let found = detected
        lock.unlock()
        if let found, found.bundleID == bundleID { return found.destination }
        return destination(bundleID: bundleID, pageURL: nil)
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): destination: \(label)")
        }
        let claude = "com.anthropic.claudefordesktop", chrome = "com.google.Chrome"
        check(destination(bundleID: claude, pageURL: URL(string: "https://claude.ai/epitaxy/local_1234")) == .codingAgent,
              "Claude's Code tab is Claude Code")
        check(destination(bundleID: claude, pageURL: URL(string: "https://claude.ai/chat/5f2e")) == .aiChat
              && destination(bundleID: claude, pageURL: nil) == .aiChat, "Claude's chat (or an unreadable tab) is a chat")
        check(destination(bundleID: "com.openai.codex", pageURL: nil) == .codingAgent
              && destination(bundleID: "com.googlecode.iterm2", pageURL: nil) == .codingAgent,
              "Codex and a terminal are coding agents")
        check(destination(bundleID: chrome, pageURL: URL(string: "https://mail.google.com/mail/u/0/#inbox")) == .email,
              "Gmail in Chrome is email")
        check(destination(bundleID: chrome, pageURL: URL(string: "https://app.slack.com/client/T1/C2")) == .messaging,
              "Slack in Chrome is messaging")
        check(destination(bundleID: chrome, pageURL: URL(string: "https://claude.ai/code/session_9")) == .codingAgent
              && destination(bundleID: chrome, pageURL: URL(string: "https://chatgpt.com/codex/tasks")) == .codingAgent,
              "Claude Code and Codex on the web are coding agents")
        check(destination(bundleID: chrome, pageURL: URL(string: "https://chatgpt.com/c/abc")) == .aiChat,
              "ChatGPT on the web is a chat")
        check(destination(bundleID: chrome, pageURL: URL(string: "https://www.bbc.co.uk/news")) == nil
              && destination(bundleID: chrome, pageURL: nil) == nil, "any other page, or none, stays as spoken")
        check(destination(bundleID: "com.apple.mail", pageURL: nil) == .email, "Mail is still email")
        return passed
    }
}
