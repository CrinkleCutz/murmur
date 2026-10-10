import AppKit
import ApplicationServices
import Darwin

/// What kind of coding field the dictation is going into, and which project it's for — read at key-down from the field
/// itself, not from a list of app names (Flit's "Agents" section, matched 2026-10-01):
///  - a prompt box — Claude Code or Codex in a terminal, Cursor's or Copilot's chat, Claude's Code tab, the Codex app:
///    a clean paragraph, the dictation's usual clean-up;
///  - a code editor or a shell: the exact words, with spoken code written as code (`CodeDictation`).
/// Claude Code running in Terminal is a prompt box; the same Terminal at a shell prompt is a shell. Then the project —
/// from the window's document, a path in its title, or the folder the app's own agent or shell is working in — gives
/// the names to spell the repo's way (`ProjectNames`).
///
/// Through Accessibility and the process list, which need nothing new; nothing is kept beyond the dictation, and a
/// file's contents are never read.
enum CodeField {
    enum Kind: String { case prompt, editor, shell }

    struct Context {
        let kind: Kind
        let projectRoot: URL?
        let names: [ProjectNames.Name]
        /// The project's folder and file names, lower-cased → the repo's spelling.
        var folders: [String: String] = [:]
    }

    /// What was read from the app at key-down — everything `kind(for:)` decides from.
    struct Facts {
        var bundleID: String
        var windowTitle = ""
        /// The focused element's description, title, placeholder and help, together.
        var focusedLabel = ""
        /// A terminal's last screenful, roughly.
        var terminalTail = ""
        var destination: Destination?
    }

    /// Kill switch, no UI: `defaults write local.murmur codeFields -bool false`.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "codeFields") as? Bool ?? true }

    static let terminalBundleIDs: Set<String> = Set(DeveloperVocabulary.terminalBundleIDs.union([
        "dev.warp.Warp", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper",
        "com.raphaelamorim.rio", "app.tabby"]).map { $0.lowercased() })

    static let editorBundleIDs: Set<String> = Set([
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "dev.zed.Zed", "dev.zed.Zed-Preview", "com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.CLion", "com.jetbrains.goland", "com.jetbrains.rider",
        "com.jetbrains.rubymine", "com.jetbrains.PhpStorm", "com.google.android.studio", "com.panic.Nova",
        "com.barebones.bbedit", "com.macromates.TextMate", "org.vim.MacVim", "com.vscodium", "ai.cursor.cursor",
    ].map { $0.lowercased() })

    /// On a terminal's screen or in its title: a coding agent is running and waiting for a prompt.
    private static let agentMarkers = [
        "claude code", "? for shortcuts", "esc to interrupt", "⏵⏵", "✻ welcome", "✳", "openai codex", ">_ openai",
        "codex>", "ctrl+j newline", "gemini cli", "type your message", "aider v", "cursor agent", "cursor-agent",
        "copilot cli", "opencode", "qwen code",
    ]
    /// In an editor's focused element: it's a chat or agent box, not the code.
    private static let chatMarkers = [
        "chat", "ask", "message", "prompt", "composer", "agent", "copilot", "claude", "codex", "plan, search",
        "describe", "follow-up", "follow up", "add context", "@ to", "question", "instruction", "inline edit",
    ]

    // MARK: - Deciding (pure, self-tested)

    static func kind(for facts: Facts) -> Kind? {
        let id = facts.bundleID.lowercased()
        if terminalBundleIDs.contains(id) {
            let screen = (facts.windowTitle + "\n" + facts.terminalTail).lowercased()
            return agentMarkers.contains { screen.contains($0) } ? .prompt : .shell
        }
        if editorBundleIDs.contains(id) {
            let label = facts.focusedLabel.lowercased()
            if label.contains("editor content") || label.contains("source editor") { return .editor }
            let words = Set(label.split { !$0.isLetter && $0 != "@" && $0 != "," && $0 != "-" }.map(String.init))
            let isChat = chatMarkers.contains { marker in
                marker.contains(" ") || marker.contains(",") ? label.contains(marker) : words.contains(marker)
            }
            return isChat ? .prompt : .editor
        }
        return facts.destination == .codingAgent ? .prompt : nil
    }

    // MARK: - Reading the app

    /// The coding field and project for the app in front, or nil when it isn't a coding place. Run off the main
    /// thread: Accessibility and `git ls-files` can take a moment.
    static func detect(bundleID: String?, pid: pid_t?) -> Context? {
        guard enabled, let bundleID, let pid else { return nil }
        let id = bundleID.lowercased()
        let isTerminal = terminalBundleIDs.contains(id), isEditor = editorBundleIDs.contains(id)
        var facts = Facts(bundleID: bundleID)
        if !isTerminal, !isEditor {
            facts.destination = DestinationDetector.detect(bundleID: bundleID, pid: pid)
            guard facts.destination == .codingAgent else { return nil }
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var windowValue: CFTypeRef?
        let window = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success
            ? windowValue.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil } : nil
        if let window { facts.windowTitle = string(window, kAXTitleAttribute) ?? "" }
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
           let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focused = focusedValue as! AXUIElement
            AXUIElementSetMessagingTimeout(focused, 0.15)
            facts.focusedLabel = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute,
                                  kAXHelpAttribute, kAXRoleDescriptionAttribute, "AXIdentifier"]
                .compactMap { string(focused, $0) }.joined(separator: " · ")
            if isTerminal { facts.terminalTail = tail(of: focused) }
        }
        guard let kind = kind(for: facts) else { return nil }
        let root = projectRoot(window: window, title: facts.windowTitle, pid: pid)
        return Context(kind: kind, projectRoot: root, names: root.map(ProjectNames.names(in:)) ?? [],
                       folders: root.map(ProjectNames.folders(in:)) ?? [:])
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let text = value as? String, !text.isEmpty { return text }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    /// The end of a terminal's text — where a coding agent's prompt box and hints are.
    private static func tail(of element: AXUIElement, characters: Int = 1_500) -> String {
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let total = count as? Int, total > 0 {
            var range = CFRange(location: max(0, total - characters), length: min(characters, total))
            if let rangeValue = AXValueCreate(.cfRange, &range) {
                var text: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &text) == .success,
                   let text = text as? String {
                    return text
                }
            }
        }
        return String((string(element, kAXValueAttribute) ?? "").suffix(characters))
    }

    // MARK: - Finding the project

    /// The project the app is working in: the window's document, a path in its title, or the folder its own agent or
    /// shell is in — the top of its git repository when there is one.
    static func projectRoot(window: AXUIElement?, title: String, pid: pid_t) -> URL? {
        if let window, let document = string(window, "AXDocument"), let url = URL(string: document), url.isFileURL,
           let root = repositoryRoot(of: url) {
            return root
        }
        if let path = pathInTitle(title), let root = repositoryRoot(of: URL(fileURLWithPath: path)) { return root }
        let roots = Set(workingFolders(under: pid).compactMap { repositoryRoot(of: URL(fileURLWithPath: $0)) })
        if roots.count == 1 { return roots.first }
        // Several sessions or tabs: the one whose folder the window names.
        let lowerTitle = title.lowercased()
        let named = roots.filter { lowerTitle.contains($0.lastPathComponent.lowercased()) }
        return named.count == 1 ? named.first : nil
    }

    /// "~/work/upload-service — zsh" → "/Users/me/work/upload-service".
    static func pathInTitle(_ title: String) -> String? {
        guard let range = title.range(of: "~(/[^\\s:—–|·()]+)*|(/[^\\s:—–|·()]+){2,}", options: .regularExpression)
        else { return nil }
        let path = (String(title[range]) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) ? path : nil
    }

    /// The top of the git repository a file or folder is in; the folder itself when it's in none (but never the home
    /// folder or the disk).
    static func repositoryRoot(of url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let start = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        var folder = start.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path || parent.path == home || folder.path == home { break }
            folder = parent
        }
        let path = start.standardizedFileURL.path
        return path == home || path == "/" || path.hasPrefix("/private") || path.hasPrefix("/System")
            || path.contains("/Library/") || path.hasSuffix(".app") ? nil : start
    }

    /// The working folders of the processes the app started (its agents, its shells), nearest first.
    static func workingFolders(under pid: pid_t, depth: Int = 4) -> [String] {
        var children: [pid_t: [pid_t]] = [:]
        let capacity = proc_listallpids(nil, 0) + 64
        var pids = [pid_t](repeating: 0, count: Int(max(capacity, 64)))
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for child in pids.prefix(Int(max(0, count))) where child > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size) == size {
                children[pid_t(info.pbi_ppid), default: []].append(child)
            }
        }
        var folders: [String] = []
        var level = [pid]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for _ in 0..<depth {
            level = level.flatMap { children[$0] ?? [] }
            for child in level {
                guard let folder = workingFolder(of: child), folder != "/", folder != home,
                      !folder.hasPrefix("/Applications"), !folder.hasPrefix("/System"), !folder.hasPrefix("/private"),
                      !folder.contains("/Library/") else { continue }
                if !folders.contains(folder) { folders.append(folder) }
            }
        }
        return folders
    }

    private static func workingFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - Writing it (shared by dictation and the command line)

    /// A code editor or shell: the exact words, with spoken code written as code and project names spelled the repo's way.
    static func exactText(_ text: String, context: Context) -> String {
        let coded = ProjectNames.fixPaths(CodeDictation.apply(text, shell: context.kind == .shell), folders: context.folders)
        return ProjectNames.apply(coded, names: context.names, style: context.kind == .shell ? .shell : .editor).text
    }

    /// A prompt box: project names spelled the repo's way (the clean-up follows, and keeps them), and the names used.
    static func promptText(_ text: String, context: Context) -> (text: String, used: [String]) {
        ProjectNames.apply(text, names: context.names, style: .prose)
    }

    // MARK: - Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): coding fields: \(label)")
        }
        func kindOf(_ id: String, title: String = "", label: String = "", tail: String = "",
                    destination: Destination? = nil) -> Kind? {
            kind(for: Facts(bundleID: id, windowTitle: title, focusedLabel: label, terminalTail: tail,
                            destination: destination))
        }
        check(kindOf("com.apple.Terminal", title: "upload-service — -zsh — 80×24", tail: "% git status\n% ") == .shell,
              "a shell prompt in Terminal is a shell")
        check(kindOf("com.apple.Terminal", title: "✳ Upload retry", tail: "╭─────╮\n│ > \n╰─────╯\n  ? for shortcuts")
              == .prompt, "Claude Code in Terminal is a prompt box")
        check(kindOf("com.googlecode.iterm2", tail: ">_ OpenAI Codex (v0.40)\n▌ ") == .prompt, "Codex in iTerm is too")
        check(kindOf("com.microsoft.VSCode", label: "Editor content;Press Alt+F1 for Accessibility Options.") == .editor,
              "VS Code's code is an editor")
        check(kindOf("com.microsoft.VSCode", label: "Chat input · Ask Copilot") == .prompt, "its chat box is a prompt")
        check(kindOf("com.todesktop.230313mzl4w4u92", label: "Plan, search, build anything") == .prompt,
              "Cursor's agent box is a prompt")
        check(kindOf("com.apple.dt.Xcode", label: "Source Editor") == .editor, "Xcode's source editor is an editor")
        check(kindOf("com.anthropic.claudefordesktop", destination: .codingAgent) == .prompt,
              "Claude's Code tab is a prompt")
        check(kindOf("com.anthropic.claudefordesktop", destination: .aiChat) == nil, "a Claude chat isn't a coding field")
        check(kindOf("com.apple.mail") == nil, "Mail isn't one")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-codefield-\(getpid())")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Sources/App/UploadClient.swift")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        check(repositoryRoot(of: file)?.standardizedFileURL.path == root.standardizedFileURL.path,
              "a file's project is the top of its repository")
        check(pathInTitle("upload — " + root.path + "/Sources — zsh").map { URL(fileURLWithPath: $0).lastPathComponent }
              == "Sources", "a folder in the window title")
        try? FileManager.default.removeItem(at: root)
        return passed
    }
}
