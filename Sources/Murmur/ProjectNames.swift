import Foundation

/// The names of the files in the project being worked on, spelled the way the repo spells them: "add a retry to the
/// upload client" → "add a retry to UploadClient", "open the voice snicket store" (misheard) → `open
/// VoiceSnippetStore.swift`. Names only — a file's contents are never read.
///
/// Built 2026-10-01 to match Flit's "Names from your project". The project is the one the app in front is working in
/// (`CodeField`); its file list comes from `git ls-files` (or, outside git, a short walk that skips build folders),
/// kept for two minutes. Only names of two or more words count ("UploadClient", "voice_snippet_store") — a one-word
/// file name is an ordinary word too often. A near miss is accepted only where the recognizer clearly misheard:
/// "voice snicket store" is close to "voice snippet store" and "snicket" isn't an everyday word; "the upload clients"
/// in a sentence about clients is left alone unless it's the exact name.
enum ProjectNames {
    struct Name: Equatable {
        /// "UploadClient.swift"
        let file: String
        /// "UploadClient"
        let stem: String
        /// "swift"
        let ext: String
        /// ["upload", "client"]
        let spoken: [String]
    }

    /// How a matched name is written.
    enum Style {
        /// A prompt: the name as a word ("UploadClient"), the file name only when the extension was said too.
        case prose
        /// A code editor: the name as an identifier, the same as prose.
        case editor
        /// A shell: the file name ("UploadClient.swift"), since a command takes files.
        case shell
    }

    // MARK: - Reading a project

    nonisolated(unsafe) private static var cache: [String: (read: Date, names: [Name], folders: [String: String])] = [:]
    private static let cacheLock = NSLock()
    private static let maxFiles = 20_000

    /// The project's multi-word file names. Read at most every two minutes per project.
    static func names(in root: URL) -> [Name] { project(root).names }

    /// The project's folder and file names, lower-cased → as the repo spells them ("sources" → "Sources"), for paths
    /// said in a shell or editor.
    static func folders(in root: URL) -> [String: String] { project(root).folders }

    private static func project(_ root: URL) -> (names: [Name], folders: [String: String]) {
        let key = root.standardizedFileURL.path
        cacheLock.lock()
        if let cached = cache[key], Date().timeIntervalSince(cached.read) < 120 {
            cacheLock.unlock()
            return (cached.names, cached.folders)
        }
        cacheLock.unlock()
        let files = (gitFiles(in: root) ?? walkedFiles(in: root)).map { path in
            path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
        }
        let names = index(files)
        var folders: [String: String] = [:]
        for path in files.prefix(maxFiles) {
            for part in path.split(separator: "/") where folders[part.lowercased()] == nil { folders[part.lowercased()] = String(part) }
        }
        cacheLock.lock()
        cache[key] = (Date(), names, folders)
        cacheLock.unlock()
        return (names, folders)
    }

    /// Each part of a path that the project has, spelled its way: "ls sources/murmur/*.swift" → "ls
    /// Sources/Murmur/*.swift". Only inside a path (something with a "/"), only for parts the project really has.
    static func fixPaths(_ text: String, folders: [String: String]) -> String {
        guard !folders.isEmpty, text.contains("/") else { return text }
        // "sources /murmur" — a folder the project has, split from the rest of its path by the recognizer.
        var chunks = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var k = 0
        while k + 1 < chunks.count {
            if chunks[k + 1].hasPrefix("/"), chunks[k + 1].count > 1, !chunks[k].isEmpty,
               folders[chunks[k].lowercased()] != nil || chunks[k].hasSuffix("/") {
                chunks[k] += chunks[k + 1]
                chunks.remove(at: k + 1)
            } else {
                k += 1
            }
        }
        return chunks.map { chunk -> String in
            guard chunk.contains("/") else { return String(chunk) }
            return chunk.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
                folders[part.lowercased()] ?? String(part)
            }.joined(separator: "/")
        }.joined(separator: " ")
    }

    /// Source files whose names are worth saying.
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "ts", "tsx", "js", "jsx", "mjs", "vue", "svelte", "py", "go",
        "rs", "kt", "kts", "java", "scala", "rb", "php", "dart", "ex", "exs", "lua", "sh", "zsh", "sql", "proto",
        "graphql", "gql", "astro", "elm", "clj", "hs", "ml", "zig", "nim", "r", "jl", "metal", "storyboard", "xib"]

    /// File names, from the paths a project lists: the multi-word ones, each stem once (source files first).
    static func index(_ paths: [String]) -> [Name] {
        let preferred = ["swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "kt", "java", "rb", "m", "h", "cs", "cpp", "c",
                         "vue", "svelte", "dart", "php", "json", "md", "yml", "yaml", "toml", "html", "css"]
        var byStem: [String: Name] = [:]
        for path in paths.prefix(maxFiles) {
            let file = (path as NSString).lastPathComponent
            let ext = (file as NSString).pathExtension
            let stem = (file as NSString).deletingPathExtension
            // Code only: a document's title ("Speech to text architecture research.md") is a sentence, not a name.
            guard !stem.isEmpty, !file.hasPrefix("."), !stem.contains(" "), codeExtensions.contains(ext.lowercased())
            else { continue }
            let spoken = parts(of: stem).map { $0.lowercased() }
            guard spoken.count >= 2, spoken.allSatisfy({ $0.count >= 2 || $0.allSatisfy(\.isNumber) }),
                  spoken.joined().count >= 6 else { continue }
            let key = spoken.joined()
            if let existing = byStem[key] {
                let rank = { (e: String) in preferred.firstIndex(of: e.lowercased()) ?? preferred.count }
                if rank(ext) >= rank(existing.ext) { continue }
            }
            byStem[key] = Name(file: file, stem: stem, ext: ext, spoken: spoken)
        }
        return byStem.values.sorted { $0.spoken.count != $1.spoken.count ? $0.spoken.count > $1.spoken.count : $0.stem < $1.stem }
    }

    /// "UploadClient" → ["Upload", "Client"], "URLSessionHelper" → ["URL", "Session", "Helper"], "voice_snippet-store"
    /// → ["voice", "snippet", "store"], "v2Engine" → ["v2", "Engine"].
    static func parts(of stem: String) -> [String] {
        var result: [String] = []
        for chunk in stem.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " || $0 == "." }) {
            var current = ""
            let chars = Array(chunk)
            for (i, c) in chars.enumerated() {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let startsWord = c.isUppercase && !current.isEmpty
                    && (current.last?.isLowercase == true || current.last?.isNumber == true
                        || (next?.isLowercase == true && current.last?.isUppercase == true))
                if startsWord { result.append(current); current = "" }
                current.append(c)
            }
            if !current.isEmpty { result.append(current) }
        }
        return result
    }

    private static func gitFiles(in root: URL) -> [String]? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Given a second at most rather than hold dictation; stopping it ends the read below.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || !data.isEmpty else { return nil }
        return data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private static func walkedFiles(in root: URL) -> [String] {
        let skip: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", "dist", "vendor", "target",
                                 ".git", ".venv", "venv", "__pycache__", ".next", "out", "Carthage"]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [String] = []
        let deadline = Date().addingTimeInterval(0.5)
        for case let url as URL in walker {
            if Date() > deadline || files.count >= 5_000 { break }
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false { files.append(url.path) }
        }
        return files
    }

    // MARK: - Finding them in what was said (pure, self-tested)

    /// The text with project names spelled the repo's way, and the names it used.
    static func apply(_ text: String, names: [Name], style: Style,
                      isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord) -> (text: String, used: [String]) {
        guard !names.isEmpty else { return (text, []) }
        // Words with their ranges in the text.
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}]+)?")
        let ns = text as NSString
        var words = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (range: $0.range, word: ns.substring(with: $0.range))
        }
        var replacements: [(range: NSRange, text: String)] = []
        var used: [String] = []
        var taken = Set<Int>()
        let byFirstLetter = Dictionary(grouping: names) { $0.spoken.first?.first ?? " " }

        var i = 0
        while i < words.count {
            guard !taken.contains(i), let first = words[i].word.lowercased().first,
                  let candidates = byFirstLetter[first] else { i += 1; continue }
            var matched: (name: Name, length: Int)?
            for name in candidates {
                // The name said as its words ("upload client"), or run together ("Uploadclient").
                for length in Set([name.spoken.count, 1]) where i + length <= words.count {
                    let window = words[i..<i + length].map { $0.word.lowercased() }
                    if (i..<i + length).contains(where: taken.contains) { continue }
                    if isMatch(window, name, isKnownWord: isKnownWord) { matched = (name, length); break }
                }
                if matched != nil { break }
            }
            guard let (name, length) = matched else { i += 1; continue }
            var start = words[i].range.location
            var end = words[i + length - 1].range.location + words[i + length - 1].range.length
            var written = style == .shell ? name.file : name.stem
            // "upload client dot swift" / "UploadClient.swift": the file name, said in full.
            var consumed = length
            if i + length + 1 < words.count, words[i + length].word.lowercased() == "dot",
               words[i + length + 1].word.lowercased() == name.ext.lowercased() {
                written = name.file
                end = words[i + length + 1].range.location + words[i + length + 1].range.length
                consumed += 2
            } else if end < ns.length, ns.substring(from: end).lowercased().hasPrefix("." + name.ext.lowercased()) {
                written = name.file
                end += name.ext.count + 1
            }
            // "to the upload client and…" → "to UploadClient and…" — but "the ProjectNames index" and a sentence's
            // opening "The" stay.
            let after = i + consumed < words.count ? words[i + consumed].word.lowercased() : nil
            if i > 0, words[i - 1].word == "the", !taken.contains(i - 1),
               after == nil || Self.joiningWords.contains(after!) {
                start = words[i - 1].range.location
            }
            replacements.append((NSRange(location: start, length: end - start), written))
            used.append(written)
            for k in i..<i + consumed { taken.insert(k) }
            i += consumed
        }
        guard !replacements.isEmpty else { return (text, []) }
        var result = text
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result = (result as NSString).replacingCharacters(in: replacement.range, with: replacement.text)
        }
        words.removeAll()
        return (result, used)
    }

    /// Words that can follow a name standing on its own ("to UploadClient and run…", "…in UploadClient so it…").
    private static let joiningWords: Set<String> = [
        "and", "or", "but", "so", "then", "to", "in", "on", "at", "for", "from", "with", "by", "of", "into", "is", "are",
        "was", "were", "has", "have", "had", "should", "could", "would", "will", "can", "does", "do", "did", "because",
        "when", "if", "that", "which", "where", "while", "after", "before", "too", "as", "it", "first", "now", "please"]

    /// Whether the words said are this name: exactly its words (or run together), or within two letters of them when
    /// it's clearly the recognizer mishearing — at least two of the name's words came out right ("voice snicket
    /// store"), or the word that differs isn't an everyday one. "upload clients" is not "UploadClient".
    private static func isMatch(_ window: [String], _ name: Name, isKnownWord: (String) -> Bool) -> Bool {
        let said = window.joined(), wanted = name.spoken.joined()
        if said == wanted { return window.count == name.spoken.count || window.count == 1 }
        guard window.count == name.spoken.count, abs(said.count - wanted.count) <= 2 else { return false }
        let letters = distance(said, wanted)
        guard letters <= 2, letters * 100 <= wanted.count * 15 else { return false }
        let pairs = Array(zip(window, name.spoken))
        let right = pairs.filter { $0.0 == $0.1 }.count
        let differing = pairs.filter { $0.0 != $0.1 }
        return right >= 2 || differing.allSatisfy { !isKnownWord($0.0) }
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return x.isEmpty ? y.count : previous[y.count]
    }

    // MARK: - Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ got: String, _ want: String, _ label: String) {
            let ok = got == want
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): project names: \(label)\(ok ? "" : " — got \u{201c}\(got)\u{201d}")")
        }
        check(parts(of: "UploadClient").joined(separator: " "), "Upload Client", "camel case split")
        check(parts(of: "URLSessionHelper").joined(separator: " "), "URL Session Helper", "an acronym")
        check(parts(of: "voice_snippet-store").joined(separator: " "), "voice snippet store", "snake and kebab")
        let names = index(["Sources/App/UploadClient.swift", "Sources/App/VoiceSnippetStore.swift", "README.md",
                           "Sources/App/Main.swift", "Tests/UploadClientTests.swift", "web/src/upload-client.ts"])
        check(names.map(\.stem).sorted().joined(separator: ","), "UploadClient,UploadClientTests,VoiceSnippetStore",
              "only multi-word names, one per stem, source first")
        let known: (String) -> Bool = { ["upload", "client", "the", "voice", "store", "open", "add", "a", "retry", "to",
                                          "with", "backoff", "and", "run", "tests", "clients", "snippet"].contains($0) }
        func run(_ text: String, _ style: Style) -> String { apply(text, names: names, style: style, isKnownWord: known).text }
        check(run("Add a retry with backoff to the upload client and run the tests.", .prose),
              "Add a retry with backoff to UploadClient and run the tests.", "a prompt gets the name")
        check(run("open the voice snicket store", .shell), "open VoiceSnippetStore.swift", "a misheard name in a shell")
        check(run("open the upload client", .shell), "open UploadClient.swift", "a shell gets the file name")
        check(run("Check upload client dot swift.", .prose), "Check UploadClient.swift.", "\u{201c}dot swift\u{201d} said")
        check(run("Fix the upload client tests.", .prose), "Fix UploadClientTests.", "the longest name wins")
        check(run("The upload client classifier misses it.", .prose), "The UploadClient classifier misses it.",
              "\u{201c}The\u{201d} before another noun stays")
        check(fixPaths("ls sources/app/*.swift", folders: ["sources": "Sources", "app": "App"]), "ls Sources/App/*.swift",
              "path parts spelled the repo's way")
        check(fixPaths("ls sources /app/*.swift", folders: ["sources": "Sources", "app": "App"]), "ls Sources/App/*.swift",
              "a path the recognizer split")
        check(fixPaths("cd /usr/local", folders: ["sources": "Sources"]), "cd /usr/local", "a real absolute path stays")
        check(run("Our upload clients are slow.", .prose), "Our upload clients are slow.",
              "an ordinary word that's close isn't changed")
        return passed
    }
}
