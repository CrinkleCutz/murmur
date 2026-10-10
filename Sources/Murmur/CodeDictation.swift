import Foundation

/// Spoken code, written as code — for a shell or a code editor (`CodeField.Kind.shell` / `.editor`), where the words
/// are exact and nothing is reworded: "git rebase dash i head tilde three" → `git rebase -i HEAD~3`, "npm run test dash
/// dash watch" → `npm run test --watch`, "camel case like this instead" → `likeThisInstead`, "star dot swift" →
/// `*.swift`. Done by fixed rules, never the model — anything with one right answer is the same every time.
///
/// Built 2026-10-01 to match Flit's "Agents" section (exact words in the shell, flags keep their dashes, spoken
/// punctuation in terminals and editors). Say "literally" before a word to keep it as a word: "literally dash".
enum CodeDictation {
    /// How a symbol sits against its neighbours.
    private enum Glue { case both, next, previous, spaced }

    private struct Symbol {
        let text: String
        let glue: Glue
    }

    /// Spoken symbols, longest phrases first. `shellGlue` overrides the glue in a shell, where "x equals y" is an
    /// assignment (`X=y`) and "star dot swift" a glob.
    private static let symbols: [(words: [String], symbol: Symbol, shellGlue: Glue?)] = {
        let table: [(String, String, Glue, Glue?)] = [
            ("dash dash", "--", .next, nil), ("double dash", "--", .next, nil),
            ("triple equals", "===", .spaced, nil), ("double equals", "==", .spaced, nil),
            ("not equals", "!=", .spaced, nil), ("plus equals", "+=", .spaced, nil), ("minus equals", "-=", .spaced, nil),
            ("fat arrow", "=>", .spaced, nil), ("double ampersand", "&&", .spaced, nil), ("and and", "&&", .spaced, nil),
            ("double pipe", "||", .spaced, nil), ("or or", "||", .spaced, nil),
            ("double underscore", "__", .both, nil), ("double slash", "//", .spaced, nil),
            ("open paren", "(", .next, nil), ("open parenthesis", "(", .next, nil), ("close paren", ")", .previous, nil),
            ("close parenthesis", ")", .previous, nil), ("open bracket", "[", .next, nil),
            ("open square bracket", "[", .next, nil), ("close bracket", "]", .previous, nil),
            ("close square bracket", "]", .previous, nil), ("open brace", "{", .next, nil),
            ("open curly brace", "{", .next, nil), ("open curly", "{", .next, nil), ("close brace", "}", .previous, nil),
            ("close curly brace", "}", .previous, nil), ("close curly", "}", .previous, nil),
            ("less than", "<", .spaced, nil), ("greater than", ">", .spaced, nil),
            ("question mark", "?", .previous, nil), ("exclamation mark", "!", .previous, nil),
            ("dollar sign", "$", .next, nil), ("at sign", "@", .both, nil), ("pound sign", "#", .next, nil),
            ("hash sign", "#", .next, nil), ("forward slash", "/", .both, nil), ("equal sign", "=", .spaced, .both),
            ("new line", "\n", .both, nil),
            ("dash", "-", .next, nil), ("minus", "-", .spaced, nil), ("hyphen", "-", .both, nil),
            ("dot", ".", .both, nil), ("slash", "/", .both, nil), ("backslash", "\\", .both, nil),
            ("underscore", "_", .both, nil), ("tilde", "~", .both, nil), ("caret", "^", .both, nil),
            ("equals", "=", .spaced, .both), ("plus", "+", .spaced, nil), ("star", "*", .spaced, .next),
            ("asterisk", "*", .spaced, .next), ("pipe", "|", .spaced, nil), ("ampersand", "&", .spaced, nil),
            ("semicolon", ";", .previous, nil), ("colon", ":", .previous, .both), ("comma", ",", .previous, nil),
            ("arrow", "->", .spaced, nil), ("backtick", "`", .both, nil), ("dollar", "$", .next, nil),
            ("hash", "#", .next, nil), ("bang", "!", .next, nil), ("percent", "%", .previous, nil),
        ]
        return table.map { (words: $0.0.split(separator: " ").map(String.init), symbol: Symbol(text: $0.1, glue: $0.2),
                            shellGlue: $0.3) }
            .sorted { $0.words.count > $1.words.count }
    }()

    /// Recognizers' spellings of the symbol words.
    private static let aliases: [String: String] = [
        "tilda": "tilde", "tildy": "tilde", "tildeh": "tilde", "underscore.": "underscore", "dashed": "dash",
        "slashed": "slash", "astrix": "asterisk", "asterix": "asterisk", "backtic": "backtick", "periods": "dot",
    ]

    private enum Case { case camel, pascal, snake, kebab, constant, upper }
    private static let caseCommands: [(words: [String], style: Case)] = [
        (["screaming", "snake", "case"], .constant), (["constant", "case"], .constant), (["camel", "case"], .camel),
        (["pascal", "case"], .pascal), (["snake", "case"], .snake), (["kebab", "case"], .kebab),
        (["all", "caps"], .upper), (["upper", "case"], .upper), (["camelcase"], .camel), (["pascalcase"], .pascal),
    ]

    /// Code keywords that begin a line.
    private static let keywords: Set<String> = [
        "if", "else", "for", "while", "let", "var", "const", "return", "func", "function", "def", "class", "struct",
        "enum", "import", "switch", "case", "guard", "try", "await", "async", "public", "private", "static", "print"]

    /// Words that start a shell command — "Git rebase…" from the recognizer is `git rebase…`.
    private static let shellCommands: Set<String> = [
        "git", "npm", "npx", "pnpm", "yarn", "bun", "node", "deno", "cd", "ls", "open", "cat", "less", "brew", "swift",
        "python", "python3", "pip", "pip3", "docker", "kubectl", "make", "cargo", "go", "rm", "mv", "cp", "mkdir", "touch",
        "echo", "grep", "rg", "find", "curl", "wget", "ssh", "scp", "sudo", "xcodebuild", "xcrun", "gh", "claude",
        "codex", "vim", "nano", "code", "chmod", "chown", "export", "source", "tail", "head", "kill", "ps", "top", "uv",
        "ruby", "rails", "bundle", "java", "gradle", "mvn", "terraform", "aws", "gcloud", "firebase", "vercel", "heroku",
        "pod", "flutter", "dart", "rustc", "clang", "gcc", "tar", "zip", "unzip", "say", "defaults", "launchctl", "lsof",
    ]

    // MARK: - Applying

    /// The dictation with its spoken code written out. `shell`: commands lower-case, numbers as digits, assignments
    /// and globs joined, no sentence punctuation.
    static func apply(_ text: String, shell: Bool) -> String {
        var source = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        if shell {
            // The recognizer's shorthand: "rebase-i" is `rebase -i`, "tilde-3" is "tilde 3".
            source = source.replacingOccurrences(of: "(?i)\\b(tilde|tilda|dash|dot|slash|underscore)-(?=\\w)", with: "$1 ",
                                                 options: .regularExpression)
            source = source.replacingOccurrences(of: "(?<=[a-z]{2})-([a-zA-Z])(?=[\\s,.]|$)", with: " -$1",
                                                 options: .regularExpression)
            // "star.swift", "/star" — a glob whisper half-wrote.
            source = source.replacingOccurrences(of: "(?i)(?<=/)(star|asterisk)(?=\\.)", with: "*",
                                                 options: .regularExpression)
        }
        let hasCommand = containsSpokenCode(source)
        let firstWord = source.split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() } ?? ""
        // The recognizer's sentence punctuation means nothing in a command: "Git rebase, dash i, head tilde three."
        if hasCommand || (shell && shellCommands.contains(firstWord)) {
            source = source.replacingOccurrences(of: "(?<=\\S),(?=\\s)", with: "", options: .regularExpression)
            while let last = source.last, ".!?".contains(last) { source.removeLast() }
        }
        // Only what reads as code is touched: a spoken symbol, or a shell line that starts with a command. Anything else
        // — a sentence typed at some other program's prompt — stays exactly as said.
        guard hasCommand || (shell && shellCommands.contains(firstWord)) else { return text }

        var tokens = tokenize(source).map { token -> String in
            // What recognizers write for the spoken symbols: "Tilda", "under score", "back slash".
            Self.aliases[token.lowercased()] ?? token
        }
        // "had tilde three" in git is "head tilde three": the recognizer's guess at an unfamiliar "head".
        for i in tokens.indices.dropLast() where tokens[i].lowercased() == "had" && tokens[i + 1].lowercased() == "tilde" {
            tokens[i] = "head"
        }
        var pieces: [(text: String, glueLeft: Bool, glueRight: Bool, isNumberSlot: Bool)] = []
        var index = 0
        var literalNext = false
        var openQuotes: Set<String> = []
        var handled = false
        func lower(_ i: Int) -> String { tokens[i].lowercased() }
        func matches(_ words: [String], at i: Int) -> Bool {
            i + words.count <= tokens.count && words.indices.allSatisfy { lower(i + $0) == words[$0] }
        }
        while index < tokens.count {
            let token = tokens[index]
            if literalNext { pieces.append((token, false, false, false)); literalNext = false; index += 1; continue }
            if ["literally", "literal"].contains(lower(index)), index + 1 < tokens.count {
                literalNext = true
                index += 1
                continue
            }
            if let command = caseCommands.first(where: { matches($0.words, at: index) }) {
                var words: [String] = []
                var next = index + command.words.count
                let limit = command.style == .upper ? 1 : .max
                while next < tokens.count, words.count < limit, tokens[next].first?.isLetter == true,
                      !symbols.contains(where: { matches($0.words, at: next) }) {
                    words.append(tokens[next])
                    next += 1
                }
                if !words.isEmpty {
                    pieces.append((cased(words, command.style), false, false, false))
                    index = next
                    continue
                }
            }
            // Quotes open and close in turn: "quote fix the login quote" → "fix the login".
            for (words, mark) in [(["double", "quote"], "\""), (["single", "quote"], "'"), (["open", "quote"], "\""),
                                  (["close", "quote"], "\""), (["end", "quote"], "\""), (["unquote"], "\""),
                                  (["quote"], "\"")] where matches(words, at: index) {
                let isOpen = openQuotes.contains(mark) && words != ["open", "quote"]
                if isOpen { openQuotes.remove(mark) } else { openQuotes.insert(mark) }
                pieces.append((mark, isOpen, !isOpen, false))
                index += words.count
                handled = true
                break
            }
            if handled { handled = false; continue }
            if let entry = symbols.first(where: { matches($0.words, at: index) }) {
                let glue = shell ? (entry.shellGlue ?? entry.symbol.glue) : entry.symbol.glue
                var glueLeft = glue == .both || glue == .previous
                let previous = pieces.last?.text ?? ""
                // A call or a subscript sits on its name ("send(request)", "items[0]"); after a keyword it doesn't.
                if ["(", "["].contains(entry.symbol.text), let last = previous.last,
                   last.isLetter || last.isNumber || last == ")" || last == "]",
                   !["if", "for", "while", "switch", "return", "and", "or", "in", "guard", "case", "else"]
                    .contains(previous.lowercased()) {
                    glueLeft = true
                }
                // "cd tilde slash projects": the command's first word keeps its space.
                if entry.symbol.text == "~", pieces.count <= 1 || pieces[pieces.count - 2].text == "\n" { glueLeft = false }
                pieces.append((entry.symbol.text, glueLeft, glue == .both || glue == .next, false))
                index += entry.words.count
                // A flag's letter: "dash I" is the recognizer capitalising a pronoun — `-i`.
                if entry.symbol.text == "-", glue == .next, index < tokens.count, tokens[index] == "I" { tokens[index] = "i" }
                continue
            }
            pieces.append((token, false, false, token.first?.isLetter == true))
            index += 1
        }

        // Number words to digits: in a shell everywhere, in an editor only right after a symbol ("tilde three").
        var merged: [(text: String, glueLeft: Bool, glueRight: Bool)] = []
        var i = 0
        while i < pieces.count {
            let afterSymbol = merged.last.map { piece in piece.text.first.map { !$0.isLetter && !$0.isNumber } ?? false }
                ?? false
            if pieces[i].isNumberSlot, shell || afterSymbol,
               let (value, used) = number(at: i, in: pieces.map(\.text)) {
                merged.append((String(value), false, false))
                i += used
                continue
            }
            merged.append((pieces[i].text, pieces[i].glueLeft, pieces[i].glueRight))
            i += 1
        }

        var result = ""
        for (n, piece) in merged.enumerated() {
            if n > 0, !merged[n - 1].glueRight, !piece.glueLeft, !result.hasSuffix("\n"), piece.text != "\n" {
                result += " "
            }
            result += piece.text
        }
        result = result.replacingOccurrences(of: " \n", with: "\n").replacingOccurrences(of: "\n ", with: "\n")
        if shell {
            result = shellTidy(result)
        } else if let first = result.split(separator: " ").first, Self.keywords.contains(first.lowercased()),
                  first.first?.isUppercase == true, first.dropFirst().allSatisfy(\.isLowercase) {
            // "If items.count > 0" from the recognizer: a line of code starts with its keyword, lower case.
            result = first.lowercased() + result.dropFirst(first.count)
        }
        return result
    }

    /// Whether any spoken symbol or case command is in the text.
    static func containsSpokenCode(_ text: String) -> Bool {
        let words = tokenize(text).map { $0.lowercased() }
        return words.indices.contains { i in
            (symbols.contains { entry in
                i + entry.words.count <= words.count && entry.words.indices.allSatisfy { words[i + $0] == entry.words[$0] }
                    && !(entry.words.count == 1 && ["dash", "minus", "star", "plus", "hash", "pipe", "bang", "dollar",
                                                     "colon", "comma", "percent", "arrow"].contains(entry.words[0]))
            }) || caseCommands.contains { entry in
                i + entry.words.count <= words.count && entry.words.indices.allSatisfy { words[i + $0] == entry.words[$0] }
            }
        } || words.indices.dropLast().contains { words[$0] == "dash" || words[$0] == "star" }
    }

    /// A command's first word in lower case, `HEAD` in git, no trailing full stop, and the recognizer's capitals off
    /// ordinary words ("swift Build -c Release" → `swift build -c release`) — but not inside quotes.
    private static func shellTidy(_ text: String, isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord)
        -> String {
        var lines = text.components(separatedBy: "\n")
        for (n, line) in lines.enumerated() {
            var words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard let first = words.first, !first.isEmpty else { continue }
            // "Git" or "NPM" from the recognizer: commands are lower case.
            if first.count > 1, first.allSatisfy(\.isLetter),
               shellCommands.contains(first.lowercased()) || first.dropFirst().allSatisfy({ !$0.isUppercase }) {
                words[0] = first.lowercased()
            }
            var quoted = false
            for (k, word) in words.enumerated() where k > 0 {
                if word.filter({ $0 == "\"" || $0 == "'" }).count % 2 == 1 { quoted.toggle(); continue }
                if !quoted, word.count > 1, word.first?.isUppercase == true, word.dropFirst().allSatisfy(\.isLowercase),
                   isKnownWord(word.lowercased()) {
                    words[k] = word.lowercased()
                }
            }
            if words[0] == "git" {
                words = words.map { word in
                    word.replacingOccurrences(of: "(?i)^head(?=$|[~^])", with: "HEAD", options: .regularExpression)
                }
            }
            var joined = words.joined(separator: " ")
            while let last = joined.last, ".".contains(last) { joined.removeLast() }
            lines[n] = joined
        }
        return lines.joined(separator: "\n")
    }

    /// The text as tokens: whitespace-separated chunks, with a comma or other sentence mark the recognizer stuck on a
    /// word split off — "npm run test, dash dash watch" → ["npm", "run", "test", ",", "dash", "dash", "watch"]. A chunk
    /// that's already code ("HEAD~3", "--watch", "items.count") stays whole.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            if n > 0 { tokens.append("\n") }
            for chunk in line.split(whereSeparator: \.isWhitespace) {
                var core = Substring(chunk)
                var trailing: [String] = []
                while core.count > 1, let last = core.last, ",;!?".contains(last) {
                    trailing.insert(String(last), at: 0)
                    core = core.dropLast()
                }
                tokens.append(String(core))
                tokens += trailing
            }
        }
        return tokens
    }

    private static func cased(_ words: [String], _ style: Case) -> String {
        let lower = words.map { $0.lowercased() }
        switch style {
        case .camel: return lower.enumerated().map { $0.offset == 0 ? $0.element : $0.element.capitalized }.joined()
        case .pascal: return lower.map(\.capitalized).joined()
        case .snake: return lower.joined(separator: "_")
        case .kebab: return lower.joined(separator: "-")
        case .constant: return lower.map { $0.uppercased() }.joined(separator: "_")
        case .upper: return lower.map { $0.uppercased() }.joined(separator: " ")
        }
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// A run of number words starting at `start`: its value and how many words it used. "twenty five" → (25, 2).
    private static func number(at start: Int, in words: [String]) -> (Int, Int)? {
        var total = 0, current = 0, used = 0
        var i = start
        while i < words.count {
            let word = words[i].lowercased()
            if let value = units[word] { current += value }
            else if let value = tens[word] { current += value }
            else if word == "hundred", current > 0 { current *= 100 }
            else if word == "thousand", current > 0 { total += current * 1000; current = 0 }
            else { break }
            used += 1
            i += 1
            if units[word] != nil, i < words.count, units[words[i].lowercased()] != nil || tens[words[i].lowercased()] != nil {
                break   // "one two" are two numbers, not twelve
            }
        }
        return used > 0 ? (total + current, used) : nil
    }

    // MARK: - Self-test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ got: String, _ want: String, _ label: String) {
            let ok = got == want
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): spoken code: \(label)\(ok ? "" : " — got \u{201c}\(got)\u{201d}")")
        }
        check(apply("Git rebase dash i head tilde three.", shell: true), "git rebase -i HEAD~3", "git rebase -i HEAD~3")
        check(apply("git rebase dash I head tilde three", shell: true), "git rebase -i HEAD~3", "a capital I after dash")
        check(apply("Npm run test, dash dash watch.", shell: true), "npm run test --watch", "npm run test --watch")
        check(apply("NPM run test dash dash watch.", shell: true), "npm run test --watch", "\u{201c}NPM\u{201d} as said")
        check(apply("git rebase-i, head tilde-3.", shell: true), "git rebase -i HEAD~3",
              "\u{201c}rebase-i\u{201d} and \u{201c}tilde-3\u{201d}, as whisper writes them")
        check(apply("Git rebase dash I had Tilda 3.", shell: true), "git rebase -i HEAD~3",
              "\u{201c}had Tilda\u{201d}, as the recognizer heard it")
        check(apply("ls star dot swift", shell: true), "ls *.swift", "a glob")
        check(apply("Swift Build -c Release", shell: true), "swift build -c release", "the recognizer's capitals off")
        check(apply("ls sources/murmur/star.swift", shell: true), "ls sources/murmur/*.swift", "a half-written glob")
        check(apply("git commit dash m quote Fix Login quote", shell: true), "git commit -m \"Fix Login\"",
              "capitals inside quotes stay")
        check(apply("cd tilde slash projects slash murmur", shell: true), "cd ~/projects/murmur", "a path")
        check(apply("git log dash n five", shell: true), "git log -n 5", "numbers as digits in a shell")
        check(apply("curl localhost colon three thousand", shell: true), "curl localhost:3000", "host and port")
        check(apply("export node env equals production", shell: true), "export node env=production",
              "an assignment joins in a shell")
        check(apply("git commit dash m quote fix the login quote", shell: true), "git commit -m \"fix the login\"",
              "a commit message in quotes")
        check(apply("let count equals items dot count", shell: false), "let count = items.count", "an editor spaces =")
        check(apply("camel case upload client retry", shell: false), "uploadClientRetry", "camel case")
        check(apply("snake case max retry count", shell: false), "max_retry_count", "snake case")
        check(apply("Call send open paren request close paren", shell: false), "Call send(request)", "brackets")
        check(apply("if open paren ready close paren", shell: false), "if (ready)", "a keyword keeps its space")
        check(apply("items open bracket zero close bracket", shell: false), "items[0]", "a subscript")
        check(apply("If items.count greater than zero return items open bracket zero close bracket.", shell: false),
              "if items.count > 0 return items[0]", "a line of code as the recognizer wrote it")
        check(apply("say literally dash", shell: true), "say dash", "\u{201c}literally\u{201d} keeps a word a word")
        check(apply("Thanks, that looks right to me.", shell: true), "Thanks, that looks right to me.",
              "a sentence at a terminal prompt stays as said")
        check(apply("Add a retry with backoff to the upload client.", shell: false),
              "Add a retry with backoff to the upload client.", "prose without spoken code is left alone")
        check(apply("Make the deck better, and run the tests.", shell: false),
              "Make the deck better, and run the tests.", "a sentence with ordinary words is left alone")
        return passed
    }
}
