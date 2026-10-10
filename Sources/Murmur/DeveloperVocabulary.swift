import Foundation

/// A curated, built-in set of software-development terms — AI coding
/// tools, frameworks, languages, and common jargon — fed into a
/// dictation's bias terms alongside the user's own learned vocabulary,
/// when `AppProfileStore.developerVocabularyEnabled(forBundleID:)` says
/// this app should get it.
///
/// Not a mode the user switches, but not unconditionally on either
/// anymore: these are hints, not hard constraints (`biasTerms()`'s
/// consumers use them to nudge an ambiguous decode toward a known word,
/// never to force one an ASR engine's actual acoustic evidence doesn't
/// support) — but a hint is still a real risk for a word that happens to
/// sound like one of these terms ("Germany" against "Gemini", "database"
/// against "Supabase"). `developerContextBundleIDs` below auto-detects
/// terminals/editors/AI-coding-tools so this vocabulary is there when
/// it's actually likely to help and out of the way everywhere else,
/// without the user ever flipping a switch — the per-app override in App
/// Profiles exists for the cases the auto-detection gets wrong either
/// direction. This is the "Murmur Developer Dictionary" layer beneath the
/// user's own Dictionary and learned corrections — see
/// [[feedback_gate_language_specific_processing]] for why the whole
/// mechanism (this included) only fires for English dictation.
///
/// Deliberately a static, hand-curated list rather than scraped from
/// anywhere: it needs to be *dense* with the terms most likely to be
/// misheard (short, unusual proper nouns — "Codex", "Supabase" — rather
/// than obscure long-tail packages), since `LearnedStore.biasTerms()`
/// caps the combined list at 300 entries shared with the user's own
/// dictionary and corrections. A sprawling list would dilute the bias
/// signal for exactly the terms that need it most.
enum DeveloperVocabulary {
    static let terms: [String] = [
        // AI coding agents & assistants — the motivating case: these are
        // the terms most likely to appear mid-sentence in ordinary
        // developer speech and least likely to already be in anyone's
        // personal dictionary.
        "Claude", "Claude Code", "Anthropic", "Codex", "OpenAI", "ChatGPT",
        "GPT-4", "GPT-5", "Copilot", "GitHub Copilot", "Cursor", "Windsurf",
        "Gemini", "Grok", "Perplexity", "MCP", "Model Context Protocol",
        "Claude Desktop", "Claude Sonnet", "Claude Opus", "Claude Haiku",

        // Editors & terminals
        "Xcode", "VS Code", "JetBrains", "Zed", "Neovim", "Vim", "Warp",
        "iTerm", "iTerm2",

        // Version control & hosting
        "GitHub", "GitLab", "Bitbucket", "npm", "pnpm", "Homebrew",

        // Web frameworks & frontend
        "React", "Next.js", "Vue", "Nuxt", "Svelte", "SvelteKit", "Angular",
        "Tailwind", "shadcn", "Vite", "Webpack", "Astro", "Remix",

        // Backend, data & infra
        "Node.js", "Supabase", "Firebase", "PostgreSQL", "MySQL", "SQLite",
        "MongoDB", "Redis", "Docker", "Kubernetes", "Vercel", "Netlify",
        "Cloudflare", "AWS", "S3", "Lambda", "Prisma", "Drizzle", "Zod",
        "GraphQL", "REST API", "WebSocket", "OAuth", "JWT",

        // Languages & runtimes
        "TypeScript", "JavaScript", "Python", "Swift", "SwiftUI", "Rust",
        "Golang", "Kotlin", "Ruby", "PHP", "C++", "Bash", "Zsh",

        // Common jargon that gets phonetically mangled
        "API", "JSON", "YAML", "URL", "UUID", "localhost", "README",
        "package.json", "tsconfig", "gitignore", "changelog", "backend",
        "frontend", "middleware", "webhook", "endpoint", "repo",
        "pull request", "merge conflict", "commit", "branch", "npm install",

        // This project's own dependencies — relevant to anyone dictating
        // about Murmur itself, not just a generic developer-terms list.
        "FluidAudio", "Parakeet", "whisper.cpp", "WhisperKit", "Harper",
        "SwiftUI", "CoreML", "Metal",
    ]

    /// Known, common mishearings for the terms above — fed into
    /// `LearnedStore.apply(in:)`'s exact-phrase post-correction alongside
    /// the user's own personal corrections.
    ///
    /// This is the layer `terms` above cannot be: prompt-based biasing is
    /// a soft nudge on the decode, not a guarantee, and confirmed in
    /// practice not to be enough on its own — "Supabase" was in the
    /// prompt (once the truncation bug above was fixed) and whisper.cpp
    /// *still* transcribed "super base" for it. A specific, known
    /// heard→intended mapping is the only mechanism that can actually
    /// promise "right every time" for a given term, because it doesn't
    /// depend on the acoustic model's confidence at all — it runs after,
    /// unconditionally, exactly like the user's own taught corrections.
    /// The tradeoff is coverage: this only fixes mishearings common
    /// enough to hard-code, not arbitrary ones a real coding-cleanup pass
    /// (the "second-pass" layer, still unbuilt) would need to catch.
    static let corrections: [(heard: String, intended: String)] = [
        ("super base", "Supabase"),
        // "bass"/"base" are homophones here — a real live dictation in
        // Claude Desktop produced this exact spelling for "Supabase" said
        // on its own with no surrounding sentence (0.60 similarity to
        // "Supabase", below even the loosened 0.68 CTC floor, so only this
        // exact-phrase correction catches it, not the acoustic rescorer).
        ("super bass", "Supabase"),
        ("superbase", "Supabase"),
        ("soup base", "Supabase"),
        ("cloud code", "Claude Code"),
        ("clawed code", "Claude Code"),
        ("clod code", "Claude Code"),
        ("codecs", "Codex"),
        ("co decks", "Codex"),
        ("cod ex", "Codex"),
        ("and tropic", "Anthropic"),
        ("an thropic", "Anthropic"),
        ("get hub", "GitHub"),
        ("get lab", "GitLab"),
        ("type script", "TypeScript"),
        ("java script", "JavaScript"),
        ("next js", "Next.js"),
        ("post grez", "PostgreSQL"),
        ("post gres", "PostgreSQL"),
        ("postgres", "PostgreSQL"),
        ("postgress", "PostgreSQL"),
        ("mongo db", "MongoDB"),
        ("chat gpt", "ChatGPT"),
        ("chat gbt", "ChatGPT"),
        ("co pilot", "Copilot"),
        ("cursor ai", "Cursor"),
        ("swift ui", "SwiftUI"),
        ("core ml", "CoreML"),
        ("kubernetes", "Kubernetes"),
        ("cuber netties", "Kubernetes"),
        ("sequel", "SQL"),
        ("oh auth", "OAuth"),
        ("jot", "JWT"),
        ("graph ql", "GraphQL"),
        ("web sockets", "WebSockets"),
        ("dot m. c. p.", "MCP"),
        ("m. c. p.", "MCP"),
    ]

    /// Per-term *looser* similarity floors for `ParakeetEngine`'s CTC-based
    /// vocabulary-boosting rescorer — see `CustomVocabularyTerm.minSimilarity`
    /// in the FluidAudio checkout. `ParakeetEngine`'s global floor (0.85) is
    /// deliberately strict; an entry here loosens it back down for one
    /// specific, individually-tested term.
    ///
    /// Safe-by-default, not risky-by-default: this vocabulary is full of
    /// short brand names built from ordinary English words — "Supabase" is
    /// "Supa" + "base", "Codex"/"Xcode" are both "code" plus one affix —
    /// and short common words measure textually close enough to them that
    /// a floor loose enough to *fix* a mis-hearing is often also loose
    /// enough to *cause* one on an unrelated, correctly-heard word. Direct
    /// testing (`say`-synthesized audio through the real rescorer) found
    /// three such collisions just among the ~20 terms tried by hand:
    /// "database" → "Supabase" (0.63 similarity), "code" → "Codex"/"Xcode"
    /// (0.80 each), "cloud" → "Claude" (0.67) — the last two only visible
    /// once testing moved from a short hand-picked term list to Murmur's
    /// full ~145-term vocabulary, so there's no reason to assume those
    /// three are the only ones among terms not yet tested this way. A
    /// global floor loose enough to admit any of these also admits the
    /// fix this mechanism exists for ("Superbase" → "Supabase", 0.78
    /// similarity) — they're too close together for one global number to
    /// separate cleanly. Rather than hunt for every future collision by
    /// hand and deny-list each one (already missed "Xcode" once doing
    /// exactly that), the global floor stays high enough to be safe
    /// against terms nobody has tested yet, and only a term with its own
    /// direct, positive test result gets listed here to loosen it back
    /// down. "Supabase" is the one term with that evidence so far — see
    /// `ParakeetEngine.transcribeWithVocabularyBoosting`'s doc comment for
    /// the full measurements this is built on.
    ///
    /// 0.68, not 0.75: a live dictation still produced "super base" (two
    /// words, 0.70 similarity to "Supabase") after the 0.75 cut — narrower
    /// than "Superbase" (one word, 0.78) and just above 0.75, so the fix
    /// missed it by a small margin. Every confirmed-dangerous collision
    /// found for this term still sits at 0.63 or below ("database",
    /// "separate", "suitcase" — see the doc comment above), so there's
    /// 0.05 of headroom to drop the floor without reopening any of them.
    /// Caveat: `say`-synthesized speech won't reliably reproduce "super
    /// base" as literal decoded text (it collapses to the same "Superbase"
    /// hypothesis Parakeet already gets right), so unlike the rest of this
    /// file this specific value couldn't be directly confirmed by the
    /// audio-based testing this file otherwise relies on — it's a
    /// text-similarity calculation plus the safety margin against known
    /// collisions, not a repeated measurement. `LearnedStore.corrections`'
    /// own `("super base", "Supabase")` entry is the other, independent
    /// safety net for this exact phrase if the acoustic floor still misses
    /// it in practice.
    ///
    /// Only reachable when `ParakeetEngine.transcribe`'s boosting path
    /// runs `UnifiedAsrManager` (English dictation with developer
    /// vocabulary active) — see that method's doc comment. A non-English
    /// dictation always gets the plain decode with no rescoring at all;
    /// `LearnedStore`'s exact-phrase/fuzzy corrections are the only
    /// remaining safety net for a mis-hearing there.
    static let parakeetMinSimilarityOverrides: [String: Float] = [
        "Supabase": 0.68,
    ]

    /// Known mis-hearing spellings per term, for FluidAudio's own
    /// `CustomVocabularyTerm.aliases` — derived from `corrections` above
    /// rather than duplicated, so there's one list of "known variants of
    /// Supabase" feeding both the deterministic post-hoc correction and
    /// this acoustic-stage one, not two that can drift apart.
    ///
    /// This is a materially different mechanism from
    /// `parakeetMinSimilarityOverrides`, not a restatement of it: an alias
    /// is its own comparison target inside FluidAudio's rescorer (see
    /// `VocabularyRescorer+Utilities.buildNormalizedForms`), scored against
    /// the decoded span directly, rather than requiring the span to be
    /// textually close to the canonical term itself. That's what lets it
    /// reach mis-hearings the similarity override can't: "super bass"
    /// measures only 0.60 against "Supabase" (below "database"'s own 0.63,
    /// so no shared threshold can safely admit it that way — see the
    /// override's own doc comment) — but registered as an alias, the
    /// rescorer compares the decoded span against "super bass" itself, a
    /// near-exact match, independent of how far that string sits from
    /// "Supabase". Confirmed against altic-dev/FluidVoice (a comparable
    /// open-source dictation app) actually shipping this exact mechanism
    /// for their own vocabulary boosting, not just a theoretical reading
    /// of FluidAudio's API — see
    /// [[project_murmur_fluidvoice_competitor_research]].
    static var parakeetAliases: [String: [String]] {
        Dictionary(grouping: corrections, by: \.intended)
            .mapValues { $0.map(\.heard) }
    }

    /// Terms `LearnedStore.apply(in:includeDeveloperVocabulary:)` fuzzy-
    /// matches against arbitrary decoded text (`fuzzyCorrect(in:)` below),
    /// keyed by the minimum similarity a candidate word/phrase must clear
    /// — same 0...1 Levenshtein measure as `parakeetMinSimilarityOverrides`
    /// ("Superbase" vs "Supabase" → 0.78), and currently the same 0.68
    /// value for the one term both apply to, though the two thresholds are
    /// independent and could diverge: this layer has no acoustic
    /// corroboration to lean on the way Parakeet's CTC rescorer does, it's
    /// a pure text-similarity check against whatever the engine already
    /// decided the word was.
    ///
    /// Built after enumerating individual mis-hearing spellings by hand
    /// stopped scaling — five variants of "Supabase" found this way
    /// ("Superbase", "super base", "super bass", "soup base", "Supervise"
    /// only partially) with no reason to believe that's the last one.
    /// Fuzzy matching catches whatever clears the threshold, known variant
    /// or not, at the cost of being real string-similarity math rather
    /// than an exact, auditable lookup — which is exactly why the
    /// threshold matters so much and why this only runs for terms listed
    /// here, not the full ~150-term `terms` list: every one of these still
    /// needs the same false-positive audit `parakeetMinSimilarityOverrides`
    /// went through before being added.
    ///
    /// This does not replace `corrections`' exact-phrase list — it
    /// complements it. "super bass" measures only 0.60 against "Supabase",
    /// *below* "database"'s own 0.63 similarity to it, so no fuzzy
    /// threshold can admit "super bass" without also admitting "database"
    /// — they're mathematically inseparable by this method alone. Only an
    /// exact, hand-vetted phrase match can safely catch a variant that
    /// close without that risk, which is why `corrections` keeps its own
    /// entry for it rather than relying on this layer to generalize that
    /// far.
    static let fuzzyCorrectionTargets: [String: Float] = [
        "Supabase": 0.68,
    ]

    /// Scans `text` for runs of one or two words that measure similar
    /// enough to a `targets` entry to replace, catching mis-hearing
    /// spellings an exact-phrase list doesn't enumerate. Word-only
    /// tokenizing (letters, via `Character.isLetter`) means surrounding
    /// punctuation and whatever separates the two words in a two-word span
    /// (space, hyphen, double space) survive untouched — only the matched
    /// span itself is replaced, with the target's own canonical
    /// spelling/casing.
    ///
    /// Takes its target list as a parameter rather than reading
    /// `fuzzyCorrectionTargets` directly: this mechanism isn't
    /// developer-vocabulary-specific, just first proven out on it.
    /// `LearnedStore.apply(in:includeDeveloperVocabulary:)` also runs it,
    /// unconditionally, against the user's own taught corrections — so
    /// someone dictating an email or an article gets the same fuzzy
    /// rescue for a name or term *they* taught Murmur, not just a
    /// developer mid-coding-session for a term Murmur shipped with.
    ///
    /// One- and two-word spans at each position are both scored, and the
    /// *better-scoring* one wins — never a fixed "longest first" —
    /// because a naive longest-first search has a real failure mode this
    /// was caught doing in testing: "Supabase is" (the correct word, plus
    /// the next word in the sentence) measures 0.73 similar to
    /// "Supabase", which cleared the threshold and swallowed "is" into
    /// the replacement, deleting a real word that had nothing wrong with
    /// it. Scoring one-word alongside two-word fixes this at the root:
    /// "Supabase" alone against "Supabase" is an exact match (short-
    /// circuits immediately, whole position skipped, two-word span never
    /// considered), while "super" alone against "Supabase" (0.375) loses
    /// to "super base" as a whole (0.70), so a genuine two-word
    /// mis-hearing still wins the way it needs to.
    ///
    /// A two-word span is also compared with its internal space stripped
    /// ("super base" → "superbase") against the target's own compact form,
    /// and the *better* of the two scores wins — a technique borrowed from
    /// cjpais/Handy (MIT), a comparable open-source dictation app, whose
    /// own custom-word matcher does the same before Levenshtein-scoring.
    /// A literal space is just another character to edit-distance, so a
    /// genuine multi-word mis-hearing of a one-word brand name is
    /// penalized by the space itself on top of the real spelling
    /// difference; stripping it first removes a penalty that was never
    /// about the actual mis-hearing. Confirmed by direct computation, not
    /// just theory: "super base" rises from 0.700 to 0.778 similar to
    /// "Supabase" (more margin above the 0.68 floor, though it already
    /// cleared it), "super based" 0.636→0.700. Checked for new
    /// false-positive risk the same way — every existing safe-word
    /// regression case in the self-test below, plus their two-word
    /// neighbors ("the database", "database is", ...) and the literal
    /// two-word phrase "data base", all stay well under 0.68 even with
    /// the compact-form score included (highest was "data base" at 0.625)
    /// — so this raises real mis-hearings without moving anything else
    /// across the line.
    static func fuzzyCorrect(in text: String, against targets: [String: Float]) -> String {
        guard !targets.isEmpty else { return text }
        let tokens = wordTokens(in: text)
        guard !tokens.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, replacement: String)] = []
        var index = 0
        while index < tokens.count {
            var bestMatch: (windowSize: Int, term: String, similarity: Float)?
            var alreadyCorrect = false

            windowSearch: for windowSize in 1...2 {
                guard index + windowSize <= tokens.count else { continue }
                let window = tokens[index..<(index + windowSize)]
                // A two-word window that already contains an exact target
                // is not a mis-hearing: the term is right and the other
                // word is just its neighbour. Without this, any word of
                // three letters or fewer *before* a correct "Supabase"
                // ("the", "use", "for", "on", "a", "via", …) measured
                // 0.73 as a two-word span (compact form: only the short
                // word differs) — above the 0.68 floor — and got swallowed
                // into the replacement: "We use Supabase for auth." became
                // "We Supabase for auth.". The `alreadyCorrect` check below
                // only protects a window that *starts* on the term, i.e.
                // the word after it; this covers the word before.
                if windowSize > 1, window.contains(where: { token in
                    targets.keys.contains { token.word.caseInsensitiveCompare($0) == .orderedSame }
                }) { continue }
                let candidate = window.map(\.word).joined(separator: " ")
                for (term, threshold) in targets {
                    guard candidate.caseInsensitiveCompare(term) != .orderedSame else {
                        // Already correct — this position needs no
                        // replacement, and a *longer* window starting
                        // here should not be allowed to override that by
                        // scoring higher on some unrelated trailing word.
                        alreadyCorrect = true
                        break windowSearch
                    }
                    let spacedSimilarity = levenshteinSimilarity(candidate, term)
                    let compactSimilarity = levenshteinSimilarity(
                        candidate.filter { !$0.isWhitespace },
                        term.filter { !$0.isWhitespace })
                    let similarity = max(spacedSimilarity, compactSimilarity)
                    guard similarity >= threshold,
                          similarity > (bestMatch?.similarity ?? 0)
                    else { continue }
                    bestMatch = (windowSize, term, similarity)
                }
            }

            guard !alreadyCorrect, let bestMatch else {
                index += 1
                continue
            }
            let window = tokens[index..<(index + bestMatch.windowSize)]
            let range = window.first!.range.lowerBound..<window.last!.range.upperBound
            replacements.append((range, bestMatch.term))
            index += bestMatch.windowSize
        }

        guard !replacements.isEmpty else { return text }
        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// Maximal runs of letters in `text`, each paired with its exact
    /// source range so a caller can replace a matched span without
    /// disturbing anything around it (punctuation, spacing, case of
    /// untouched words).
    private static func wordTokens(in text: String) -> [(word: String, range: Range<String.Index>)] {
        var tokens: [(word: String, range: Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, text[index].isLetter {
                index = text.index(after: index)
            }
            tokens.append((String(text[start..<index]), start..<index))
        }
        return tokens
    }

    /// Case-insensitive string similarity in 0...1: `1 - editDistance /
    /// longerLength`. The same measure used throughout this file's other
    /// documentation (computed against real examples, not just asserted)
    /// — kept as one shared implementation rather than reproducing the
    /// formula ad hoc wherever a threshold needs checking against it.
    static func levenshteinSimilarity(_ a: String, _ b: String) -> Float {
        let a = Array(a.lowercased())
        let b = Array(b.lowercased())
        if a.isEmpty || b.isEmpty { return a.isEmpty && b.isEmpty ? 1 : 0 }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Float(previous[b.count]) / Float(max(a.count, b.count))
    }

    /// Bundle IDs `AppProfileStore.developerVocabularyEnabled(forBundleID:)`
    /// treats as a developer context by default: terminals, code editors,
    /// and AI coding tools, where a Supabase/Codex/Claude Code mention is
    /// far more likely mid-sentence than in general use — and everyday
    /// words this vocabulary could collide with ("Germany", "team",
    /// "database") are correspondingly less likely.
    ///
    /// Best-effort, not exhaustive by construction: an app missing from
    /// this list just means the smart default is "off" there, the same as
    /// it now is everywhere without this list at all — not a safety
    /// problem, and fixable per-app from its App Profile in Settings
    /// regardless of whether it's listed here. IDs were taken from public
    /// documentation/community reports for apps not installed on the
    /// machine this was written on to check directly (`osascript -e 'id
    /// of app "Name"'` against an actually-installed copy is the more
    /// reliable source when in doubt) — Xcode, Terminal, and the
    /// Anthropic/OpenAI desktop apps were confirmed this way; the rest
    /// weren't and could be stale if a vendor changes their bundle ID.
    /// Literal command-line terminals — a strict subset of
    /// `developerContextBundleIDs` below, broken out separately because
    /// `AppProfileStore.style(forBundleID:)` auto-defaults *these specific
    /// apps* to Raw (skip grammar/punctuation cleanup and the Apple
    /// Intelligence rewrite pass), not the whole developer-context list.
    /// A terminal is the one place that rewrite pass is actively
    /// dangerous rather than just slow — capitalization and punctuation
    /// don't apply to shell syntax, and an LLM asked to "tighten rambling
    /// phrasing" could plausibly reshape `git commit -m "fix bug"` into
    /// something that no longer runs. Code editors (Xcode, VS Code, ...)
    /// and AI chat desktop apps (Claude, ChatGPT) stay off this list on
    /// purpose: dictation there is often prose — comments, commit
    /// messages, chat prompts — that genuinely benefits from the same
    /// cleanup pass a terminal has no use for. Claude Code/Codex CLI don't
    /// need their own entry here; they run inside one of these terminal
    /// apps, not as a separate bundle ID.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
    ]

    static let developerContextBundleIDs: Set<String> = terminalBundleIDs.union([
        // Editors & IDEs
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.datagrip",
        "com.jetbrains.rubymine",
        "com.jetbrains.PhpStorm",
        "org.vim.MacVim",
        "com.macromates.textmate",
        "com.barebones.bbedit",
        "com.panic.Nova",

        // AI coding assistants (desktop apps — Claude Code/Codex CLI runs
        // inside a terminal, already covered above)
        "com.anthropic.claudefordesktop",
        "com.openai.codex",

        // Dev infra & version control
        "com.docker.docker",
        "com.github.GitHubDesktop",
        "com.postmanlabs.mac",
        "com.konghq.insomnia",
    ])

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        // Never-hardcoded spellings — none of these appear in `corrections`
        // — proving the fuzzy layer generalizes rather than only replaying
        // known variants.
        for variant in ["Soupabase", "Supperbase", "Supabass", "Supebase", "Suparbase"] {
            let result = fuzzyCorrect(in: "using \(variant) for the backend", against: fuzzyCorrectionTargets)
            check(result == "using Supabase for the backend", "fuzzy-corrects unseen variant \(variant.debugDescription)")
        }

        // The exact false positives this threshold was tuned against —
        // regressing any of these silently reopens a confirmed bug.
        for safeWord in ["database", "suitcase", "separate", "cloud", "code", "supervise"] {
            let sentence = "the \(safeWord) is ready"
            check(fuzzyCorrect(in: sentence, against: fuzzyCorrectionTargets) == sentence, "leaves \(safeWord.debugDescription) untouched")
        }

        // Already-correct text shouldn't be rewritten into an
        // identical-looking no-op (case normalization would be a silent
        // behavior change even if invisible in this instance).
        check(fuzzyCorrect(in: "using Supabase already", against: fuzzyCorrectionTargets) == "using Supabase already",
              "leaves already-correct \"Supabase\" untouched")

        // Regression: a correct "Supabase" immediately followed by a
        // short word ("is") measures deceptively similar to "Supabase"
        // as a two-word span (0.73) — high enough to have cleared the
        // threshold and swallowed "is" into the replacement, silently
        // deleting a real word. Caught live testing this exact sentence.
        check(fuzzyCorrect(in: "Supabase is set up and working now", against: fuzzyCorrectionTargets)
              == "Supabase is set up and working now",
              "an already-correct \"Supabase\" doesn't consume the next word")
        check(fuzzyCorrect(in: "Supabase was the right call", against: fuzzyCorrectionTargets)
              == "Supabase was the right call",
              "an already-correct \"Supabase\" doesn't consume \"was\" either")

        // The mirror image of the two cases above, found in a full-pipeline
        // audit: a correct "Supabase" preceded by a short word used to
        // swallow that word ("We use Supabase for auth." → "We Supabase
        // for auth.") — any word of ≤3 letters scores ≥0.68 as a two-word
        // span. Every one of these must come back byte-identical.
        for sentence in [
            "We use Supabase for auth.", "Open the Supabase dashboard.",
            "Set up a Supabase project.", "It runs on Supabase now.",
            "Log in via Supabase today.", "Check our Supabase logs.",
            "Pay for Supabase monthly.", "Is it the Supabase database?",
        ] {
            check(fuzzyCorrect(in: sentence, against: fuzzyCorrectionTargets) == sentence,
                  "an already-correct \"Supabase\" doesn't consume the word before it: \(sentence.debugDescription)")
        }
        // …while a genuine mis-hearing right after a short word is still
        // caught, and the short word survives.
        check(fuzzyCorrect(in: "we use super base for auth", against: fuzzyCorrectionTargets)
              == "we use Supabase for auth",
              "still fixes a mis-heard \"super base\" after a short word, keeping that word")
        check(fuzzyCorrect(in: "open the Soupabase dashboard", against: fuzzyCorrectionTargets)
              == "open the Supabase dashboard",
              "still fixes a mis-heard single-word variant after a short word, keeping that word")

        // "super bass" sits below the fuzzy floor by design (0.60,
        // *below* database's own 0.63) — it must stay unmatched here, or
        // the whole reason `corrections` still carries it becomes false.
        check(fuzzyCorrect(in: "check the super bass on this", against: fuzzyCorrectionTargets) == "check the super bass on this",
              "leaves below-floor \"super bass\" for the exact-phrase list to catch")

        // "super base" as a two-word span already cleared 0.68 before the
        // compact-form comparison existed (0.700) — this locks in that it
        // still does now that the score is a max() over two comparisons,
        // not a regression risk in the other direction.
        check(fuzzyCorrect(in: "check the super base on this", against: fuzzyCorrectionTargets)
              == "check the Supabase on this",
              "still fuzzy-corrects two-word \"super base\"")

        // The literal two-word phrase "data base" is the nearest real
        // English phrase to "Supabase" that the compact-form comparison
        // (stripping the space to "database") could plausibly have pulled
        // over the line, since single-word "database" is already the
        // closest known false-positive risk for this term. It doesn't
        // (0.625 computed, still well under 0.68) — see `fuzzyCorrect`'s
        // doc comment for the fuller check this was verified against.
        check(fuzzyCorrect(in: "the data base is ready", against: fuzzyCorrectionTargets)
              == "the data base is ready",
              "leaves two-word \"data base\" untouched even with compact-form scoring")

        check(levenshteinSimilarity("Superbase", "Supabase") > 0.7, "similarity: Superbase vs Supabase")
        check(levenshteinSimilarity("Supabase", "Supabase") == 1, "similarity: identical strings")
        check(levenshteinSimilarity("", "Supabase") == 0, "similarity: empty vs non-empty")

        return passed
    }
}
