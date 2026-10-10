import Foundation

/// What Murmur does when you dictate into one particular app.
///
/// This replaces two separate per-app rule systems (`StyleSettings.overrides`
/// and `TemplateSettings.overrides`) that were both keyed by bundle ID and
/// both edited on different pages. Splitting them meant "what happens when I
/// dictate into Slack?" was one question with its answer scattered across
/// two screens — and, worse, a template rule silently suppressed a style
/// rule for the same app with nothing in the UI saying so.
struct AppProfile: Codable, Equatable {
    var appName: String
    /// `nil` inherits the global default tone rather than pinning one, so a
    /// profile created purely to attach a template doesn't have to make a
    /// tone decision it didn't ask to make.
    var style: WritingStyle?
    /// `nil` means no template is auto-applied in this app.
    var templateID: UUID?
    /// `nil` means this profile can only be reached by dictating into the
    /// app itself. Set, it also force-starts a dictation resolved against
    /// this profile from anywhere, via `ProfileHotkeyMonitor`.
    var hotkeySlot: ProfileHotkeySlot?
    /// `nil` inherits the auto-detected default for this app's bundle ID
    /// (`DeveloperVocabulary.developerContextBundleIDs`) rather than
    /// pinning one — set `true`/`false` only to override that guess for
    /// this specific app, in either direction.
    var developerVocabulary: Bool?
    /// `nil` inherits the global auto-paste setting. Set `false` only for
    /// an app where you'd rather review a dictation on the clipboard before
    /// it lands — e.g. a form field where a stray paste is hard to undo.
    var autoPaste: Bool?
    /// `nil` inherits the global recognition engine (`Settings.engine`).
    /// Set to run a specific app through a different engine than
    /// everywhere else — e.g. the fastest engine for chat apps, the most
    /// accurate for long-form writing.
    var engine: String?
    /// `nil` inherits the global model for whichever engine is actually in
    /// effect (this profile's own `engine` override if set, else
    /// `Settings.engine`) — `Settings.whisperModel`/`.whisperCppModel`/
    /// `.parakeetModel`/`.sherpaModel` depending on which. Set to pick a
    /// specific model within that engine for this app — e.g. sherpa-onnx's
    /// Canary specifically, not whichever sherpa-onnx model happens to be
    /// selected globally. Meaningless (and not offered) for the Apple
    /// engine, which has no model choice.
    var model: String?
    /// `nil` inherits the global dictation language (`Settings
    /// .localeIdentifier`). Set to dictate in a different language into a
    /// specific app without switching your everywhere-else language back
    /// and forth — e.g. Spanish into WhatsApp, English elsewhere.
    var localeIdentifier: String?
    /// `nil` follows Settings ▸ Dictation ▸ Translate into. A language code translates what's dictated into this app
    /// into it; "" turns translation off here — see `TranslateInto`.
    var translateInto: String?

    /// A profile with none of the fields below set does nothing; used to
    /// prune empties. A hotkey-only profile (everything else nil) is still
    /// meaningful — pressing it forces resolution to this bundle ID, which
    /// without any other override just falls back to the global defaults —
    /// so it must survive pruning just like the other fields.
    var isEmpty: Bool {
        style == nil && templateID == nil && hotkeySlot == nil
            && developerVocabulary == nil && autoPaste == nil
            && engine == nil && model == nil && localeIdentifier == nil && translateInto == nil
    }
}

enum AppProfileStore {
    private static let defaults = UserDefaults.standard
    private static let key = "appProfiles"
    private static let migratedKey = "appProfilesMigrated"

    /// bundleID → profile.
    static var profiles: [String: AppProfile] {
        get {
            migrateIfNeeded()
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(
                    [String: AppProfile].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            // Drop profiles that no longer say anything, so deleting both
            // halves of a rule removes the row instead of leaving a ghost.
            let pruned = newValue.filter { !$0.value.isEmpty }
            if let data = try? JSONEncoder().encode(pruned) {
                defaults.set(data, forKey: key)
            }
        }
    }

    static func profile(forBundleID bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return profiles[bundleID]
    }

    // MARK: - Site rules
    //
    // A site rule ("this profile applies to mail.google.com, not just
    // Chrome generally") reuses the exact same `[String: AppProfile]` store
    // instead of a second dictionary keyed a different way — its "bundle
    // ID" is a synthetic `"site:<url substring>"` string that every
    // resolver below (`style(forBundleID:)`, `template(forBundleID:)`, …)
    // already treats as an opaque dictionary key, so none of them needed
    // to change. The one new piece is `siteProfileKey(forURL:)`, called
    // from `AppDelegate.stopAndTranscribe()` to substitute this synthetic
    // key in for the browser's own real bundle ID when the active tab
    // matches — everywhere downstream then resolves against the site
    // profile exactly as if it were a normal app profile.

    private static let sitePrefix = "site:"

    static func isSiteKey(_ bundleID: String) -> Bool {
        bundleID.hasPrefix(sitePrefix)
    }

    static func sitePattern(forKey bundleID: String) -> String? {
        guard isSiteKey(bundleID) else { return nil }
        return String(bundleID.dropFirst(sitePrefix.count))
    }

    static func siteKey(forPattern pattern: String) -> String { sitePrefix + pattern }

    /// Cheap existence check so `stopAndTranscribe()` can skip reading the
    /// browser's active tab URL entirely (an AppleScript round-trip) for
    /// the common case where no one has set up a site rule.
    static var hasSiteProfiles: Bool {
        profiles.keys.contains { isSiteKey($0) }
    }

    /// The synthetic bundle-ID key of the first site rule whose pattern is
    /// a substring of `url`, if any — case-insensitive, since a URL's
    /// scheme/host casing isn't meaningful to match against. Iteration
    /// order over site rules isn't guaranteed if more than one pattern
    /// matches the same URL; treated the same as `ProfileHotkeySlot`'s own
    /// "first match wins, don't promise more" house style.
    static func siteProfileKey(forURL url: String) -> String? {
        let lowered = url.lowercased()
        for (bundleID, _) in profiles {
            guard let pattern = sitePattern(forKey: bundleID), !pattern.isEmpty,
                  lowered.contains(pattern.lowercased())
            else { continue }
            return bundleID
        }
        return nil
    }

    /// The tone to use for an app: its own override, else Raw if this is a
    /// recognized literal terminal (`DeveloperVocabulary.terminalBundleIDs`
    /// — Terminal, iTerm, Warp, ... where Claude Code/Codex CLI actually
    /// run), else the global default. Scoped to terminals specifically,
    /// not the broader developer-context list `developerVocabularyEnabled`
    /// uses: a terminal has no use for capitalized, LLM-polished prose
    /// (dictated text there is shell syntax, where that rewrite is
    /// actively risky, not just slow), but a code editor or an AI chat
    /// app is often prose that benefits from the same cleanup any other
    /// app gets — auto-silencing it there would be a regression, not a fix.
    static func style(forBundleID bundleID: String?) -> WritingStyle {
        rewriteStyle(from: effectiveStyle(forBundleID: bundleID))
    }

    /// The style in force for this app before "Auto" is resolved: the profile's own choice, else Raw for a terminal,
    /// else the global default.
    static func effectiveStyle(forBundleID bundleID: String?) -> WritingStyle {
        if let override = profile(forBundleID: bundleID)?.style {
            return override
        }
        if let bundleID, DeveloperVocabulary.terminalBundleIDs.contains(bundleID) {
            return .raw
        }
        return StyleSettings.defaultStyle
    }

    /// What the rewrite pipeline sees. "Auto" is not a rewrite: it only shapes the finished text afterwards, so the
    /// cleanup, its guard and everything else read it as "As spoken" and behave exactly as they always have.
    static func rewriteStyle(from effective: WritingStyle) -> WritingStyle {
        effective == .auto ? .none : effective
    }

    /// The kind of place to shape the finished text for when "Auto (match app)" is in effect for this app; nil when it
    /// isn't, or when the app is not an email or messaging app (which then stays exactly as spoken).
    /// Uses what key-down read from the app's window (`DestinationDetector`) — Gmail in Chrome is email, Slack on the web
    /// is messaging — and otherwise what the app alone says.
    static func autoDestination(forBundleID bundleID: String?) -> Destination? {
        autoDestination(effective: effectiveStyle(forBundleID: bundleID), bundleID: bundleID,
                        detected: DestinationDetector.current(for: bundleID))
    }

    static func autoDestination(effective: WritingStyle, bundleID: String?, detected: Destination? = nil) -> Destination? {
        effective == .auto ? (detected ?? DestinationShaper.destination(forBundleID: bundleID)) : nil
    }

    /// Whether Murmur's built-in developer vocabulary (terms + corrections)
    /// should bias recognition for this app: the profile's own override if
    /// one is set, else whether the bundle ID is a recognized developer
    /// context. A `nil` bundle ID (no resolvable frontmost app) has no
    /// profile to check and isn't in the built-in list either, so it
    /// resolves to `false` — the same safe-by-default the built-in list
    /// itself follows.
    static func developerVocabularyEnabled(forBundleID bundleID: String?) -> Bool {
        if let override = profile(forBundleID: bundleID)?.developerVocabulary {
            return override
        }
        guard let bundleID else { return false }
        return DeveloperVocabulary.developerContextBundleIDs.contains(bundleID)
    }

    /// The template to auto-apply in an app, resolved against the current
    /// template list (a profile can outlive the template it points at).
    static func template(forBundleID bundleID: String?) -> NoteTemplate? {
        guard let templateID = profile(forBundleID: bundleID)?.templateID
        else { return nil }
        return NoteTemplateStore.all().first { $0.id == templateID }
    }

    /// Whether a dictation into this app should auto-paste — the profile's
    /// own override if set, else the global default.
    static func autoPasteEnabled(forBundleID bundleID: String?) -> Bool {
        profile(forBundleID: bundleID)?.autoPaste ?? Settings.autoPasteEnabled
    }

    /// The recognition engine to use for this app — the profile's own
    /// override if set, else the global default (`Settings.engine`).
    static func engine(forBundleID bundleID: String?) -> String {
        profile(forBundleID: bundleID)?.engine ?? Settings.engine
    }

    /// The model to use for this app, within whichever engine is actually
    /// in effect (`engine(forBundleID:)`) — the profile's own override if
    /// set, else that engine's own global model setting. Apple has no
    /// model concept, so this resolves to `""` for it (never read; every
    /// call site branches on the engine first).
    static func model(forBundleID bundleID: String?) -> String {
        if let override = profile(forBundleID: bundleID)?.model { return override }
        switch engine(forBundleID: bundleID) {
        case "whisper": return Settings.whisperModel
        case "whispercpp": return Settings.whisperCppModel
        case "parakeet": return Settings.parakeetModel
        case "sherpa": return Settings.sherpaModel
        default: return ""
        }
    }

    /// The dictation language to use for this app — the profile's own
    /// override if set, else the global default
    /// (`Settings.localeIdentifier`).
    static func localeIdentifier(forBundleID bundleID: String?) -> String {
        profile(forBundleID: bundleID)?.localeIdentifier ?? Settings.localeIdentifier
    }

    // MARK: - Migration

    /// Folds the two legacy rule dictionaries into one profile map, once.
    /// Both are keyed by bundle ID, so an app with a style rule *and* a
    /// template rule becomes a single profile carrying both — which is
    /// exactly the combination the old pipeline couldn't honour.
    private static func migrateIfNeeded() {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        var styleRules: [String: AppStyleRule] = [:]
        if let data = defaults.data(forKey: "styleOverrides"),
           let legacy = try? JSONDecoder().decode(
            [String: AppStyleRule].self, from: data) {
            styleRules = legacy
        }

        var templateRules: [String: AppTemplateRule] = [:]
        if let data = defaults.data(forKey: "templateOverrides"),
           let legacy = try? JSONDecoder().decode(
            [String: AppTemplateRule].self, from: data) {
            templateRules = legacy
        }

        let merged = merge(styleRules: styleRules, templateRules: templateRules)
        guard !merged.isEmpty else { return }
        if let data = try? JSONEncoder().encode(merged) {
            defaults.set(data, forKey: key)
        }
    }

    /// Pure merge of the two legacy maps, split out so it can be tested
    /// without touching UserDefaults.
    static func merge(
        styleRules: [String: AppStyleRule],
        templateRules: [String: AppTemplateRule]
    ) -> [String: AppProfile] {
        var merged: [String: AppProfile] = [:]
        for (bundleID, rule) in styleRules {
            merged[bundleID] = AppProfile(
                appName: rule.appName, style: rule.style, templateID: nil)
        }
        for (bundleID, rule) in templateRules {
            if var existing = merged[bundleID] {
                existing.templateID = rule.templateID
                merged[bundleID] = existing
            } else {
                merged[bundleID] = AppProfile(
                    appName: rule.appName, style: nil, templateID: rule.templateID)
            }
        }
        return merged.filter { !$0.value.isEmpty }
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        // An app configured on BOTH old pages must end up as one profile
        // carrying both halves — the combination the old pipeline dropped.
        let templateID = UUID()
        let merged = merge(
            styleRules: [
                "com.slack": AppStyleRule(appName: "Slack", style: .casual),
                "com.mail": AppStyleRule(appName: "Mail", style: .formal),
            ],
            templateRules: [
                "com.slack": AppTemplateRule(appName: "Slack", templateID: templateID),
                "com.notes": AppTemplateRule(appName: "Notes", templateID: templateID),
            ])
        check(merged.count == 3, "merge unions both maps (got \(merged.count), want 3)")
        check(merged["com.slack"]?.style == .casual
              && merged["com.slack"]?.templateID == templateID,
              "app in both maps keeps style AND template")
        check(merged["com.mail"]?.style == .formal
              && merged["com.mail"]?.templateID == nil,
              "style-only app migrates with no template")
        check(merged["com.notes"]?.style == nil
              && merged["com.notes"]?.templateID == templateID,
              "template-only app inherits default tone (style nil)")

        // Composition: a template must no longer silently discard the tone.
        let template = NoteTemplate(
            name: "T", icon: "", instructions: "STRUCTURE", isBuiltIn: true)
        check(RewritePlan.instructions(template: template, style: .none) == "STRUCTURE",
              "template only = template instructions")
        let both = RewritePlan.instructions(template: template, style: .formal)
        check(both?.contains("STRUCTURE") == true
              && both?.contains("formal") == true,
              "template + tone composes BOTH into one pass")

        // Raw means "don't touch my words at all" — the one case with
        // truly no rewrite pass, regardless of what else is set.
        check(RewritePlan.instructions(template: nil, style: .raw) == nil,
              "Raw never triggers a rewrite pass")
        check(RewritePlan.instructions(template: template, style: .raw) == nil,
              "Raw overrides even an app's own template")

        // Default cleanup: "As spoken" used to mean no rewrite pass ran at
        // all. It now means a cleanup-only pass — filler/false-start
        // removal and grammar, no tone shift.
        let cleanupOnly = RewritePlan.instructions(template: nil, style: .none)
        check(cleanupOnly != nil, "no template + no tone still runs a cleanup pass")
        check(cleanupOnly?.contains("false starts") == true,
              "default pass targets what TextFormatter's regex can't")
        check(cleanupOnly?.localizedCaseInsensitiveContains("formal") == false
              && cleanupOnly?.localizedCaseInsensitiveContains("casual") == false,
              "cleanup-only pass carries no tone instructions")

        // A tone style still gets the cleanup baseline underneath it, not
        // just the tone instructions alone — the actual gap being closed.
        let toneOnly = RewritePlan.instructions(template: nil, style: .formal)
        check(toneOnly?.contains("false starts") == true
              && toneOnly?.contains(WritingStyle.formal.instructions ?? "\0") == true,
              "tone-only pass composes cleanup baseline + tone, not tone alone")

        // Voice profile colours an existing pass but never creates one.
        let voice = VoiceProfile(
            title: "Habit Architect", summary: "Detailed and precise.",
            traits: ["Detailed", "Frequent pauses"], wordCountAtGeneration: 100)
        check(RewritePlan.instructions(template: nil, style: .raw, voice: voice) == nil,
              "voice never overrides Raw into running a pass")
        let voiced = RewritePlan.instructions(
            template: nil, style: .formal, voice: voice)
        check(voiced?.contains("Detailed and precise.") == true
              && voiced?.contains("Frequent pauses") == true,
              "voice profile summary + traits reach the instructions")

        // Cleanup level: an explicit new axis, independent of tone/template,
        // defaulting to today's unchanged behavior.
        check(RewritePlan.instructions(template: nil, style: .none) ==
              RewritePlan.instructions(template: nil, style: .none, cleanupLevel: .light),
              "cleanupLevel defaults to .light, matching pre-existing behavior exactly")
        let concise = RewritePlan.instructions(template: nil, style: .none, cleanupLevel: .concise)
        check(concise?.contains("tighten this for concision") == true,
              "concise cleanup level adds its own instructions")
        check(RewritePlan.instructions(template: nil, style: .raw, cleanupLevel: .concise) == nil,
              "Raw overrides concise cleanup the same way it overrides everything else")
        let conciseWithTone = RewritePlan.instructions(
            template: nil, style: .formal, cleanupLevel: .concise)
        check(conciseWithTone?.contains("tighten this for concision") == true
              && conciseWithTone?.contains(WritingStyle.formal.instructions ?? "\0") == true,
              "concise composes with tone rather than replacing it")

        // "Auto (match app)": invisible to the rewrite pipeline, and only active where it was chosen.
        check(rewriteStyle(from: .auto) == .none, "Auto reads as \"As spoken\" to the rewrite pipeline")
        check(rewriteStyle(from: .formal) == .formal && rewriteStyle(from: .raw) == .raw, "other styles pass through unchanged")
        check(autoDestination(effective: .auto, bundleID: "com.apple.mail") == .email, "Auto in Mail shapes for email")
        check(autoDestination(effective: .auto, bundleID: "com.openai.codex") == nil, "Auto in Codex changes nothing")
        check(autoDestination(effective: .none, bundleID: "com.apple.mail") == nil, "Mail without Auto changes nothing")
        check(autoDestination(effective: .formal, bundleID: "com.tinyspeck.slackmacgap") == nil, "an explicit style is never overridden")
        return passed
    }
}

// MARK: - Instruction composition

enum RewritePlan {
    /// Dedicated correction-resolution guidance, factored out of
    /// `cleanupInstructions` so it reads as its own paragraph rather than
    /// one word buried in a filler-removal list — tested standalone
    /// first (a throwaway on-device probe using this exact wording) against
    /// five real cases before landing here, including the one this
    /// paragraph's own worked example exists for: an earlier, terser
    /// version of this instruction (just the word "self-corrections" in
    /// the list above) correctly left "I actually enjoyed the movie more
    /// than I expected to" alone but failed to resolve "5pm, actually
    /// 6pm" or a same-utterance restatement with no signal word at all
    /// ("can we meet Tuesday — I'd rather meet Wednesday"). This fuller
    /// version fixes both, verified against the same real dictation
    /// pipeline (`Murmur --edit`), not just in isolation.
    private static let correctionInstructions = """
        The speaker sometimes verbally corrects themselves mid-dictation — \
        restating a value, saying "actually," "no wait," or simply \
        contradicting something they said moments earlier, with or without \
        a signal word. When that happens, output ONLY the final, corrected \
        version they meant: remove the parts they walked back, keep the \
        parts they didn't — even if the correction replaces just one word \
        or number in the middle of a sentence rather than a whole clause. \
        Do not treat every instance of "actually" as a correction, though: \
        if it's just a normal word in an otherwise consistent sentence — \
        nothing before or after it is contradicted — leave the sentence \
        exactly as dictated.

        Example — dictated text "I actually enjoyed the movie more than I \
        expected to": the correct output is that exact text, unchanged. \
        "Actually" contradicts nothing said before it, so it stays.
        """

    /// The baseline pass every non-Raw dictation gets when nothing else
    /// applies. `TextFormatter` already strips a fixed list of standalone
    /// filler tokens ("um", "uh", …) deterministically before this ever
    /// runs — this covers what regex can't: phrasal filler ("you know",
    /// "like", "I mean"), false starts, stumbled or repeated words, actual
    /// grammar, and rambling that needs restructuring rather than just
    /// trimming. Previously "As spoken" meant *no* rewrite pass ran at
    /// all; this is what makes it mean "cleaned up, same register"
    /// instead — the gap between the deterministic formatter and an
    /// explicit Style/Template.
    ///
    /// Deliberately not extended to the template branches below —
    /// `RewritePlan.instructions`'s own doc comment already explains why a
    /// template's instructions stay the sole primary instruction, and this
    /// codebase's self-test (`RewritePlan.instructions(template:style:.none)
    /// == "STRUCTURE"`, exact equality) locks that in on purpose. Template
    /// dictation still gets no correction-resolution as a result — a
    /// narrower fix than "everywhere," left for a deliberate follow-up
    /// rather than folded in here.
    private static let cleanupInstructions = """
        Clean up this dictated transcript: remove verbal filler and false \
        starts ("you know", "like", "I mean", stumbled or repeated words), \
        fix grammar and punctuation, and tighten rambling or run-on \
        phrasing into clear, well-formed sentences.

        \(correctionInstructions)

        Preserve the speaker's meaning, facts, and intent exactly — do not \
        add information that wasn't said, and do not change their tone \
        unless instructed to below. This is light editing, not rewriting: \
        keep the same paragraph breaks as the original (do not add new \
        ones, and do not add quotation marks, headings, or any other \
        formatting the speaker didn't ask for), and output a plain \
        continuation of their sentences, never a description or \
        restructuring of what they said.
        """

    /// Layered on top of `base` below when `CleanupLevel.concise` is
    /// chosen — deliberately permits what `cleanupInstructions`'s own
    /// wording just above rules out (restructuring, shortening), rather
    /// than replacing it outright, so a template's own structure or an
    /// applied tone still governs everything concision doesn't touch.
    private static let conciseInstructions = """
        Also tighten this for concision: cut redundant phrasing, combine \
        related sentences, and drop words that don't carry meaning. Unlike \
        the instructions above, you may restructure sentences and shorten \
        the overall result — just never invent information or drop a fact \
        that was actually said.
        """

    /// Whether the pass is the plain "As spoken" cleanup — the only one whose
    /// output is held to the words that went in (`LLMEditGuard`). A Style or a
    /// Template is *meant* to change the wording, and Concise to shorten it.
    /// What a template gets besides its own instructions (`TemplateEngine`): the app's tone and the Voice Profile —
    /// the same additions `instructions(template:…)` composes, without the template text itself.
    static func templateExtras(style: WritingStyle, cleanupLevel: CleanupLevel, voice: VoiceProfile?) -> String? {
        var parts: [String] = []
        if let tone = style.instructions {
            parts.append("Apply this tone throughout, without changing the structure described above: \(tone)")
        }
        if cleanupLevel == .concise { parts.append(conciseInstructions) }
        if let voice {
            parts.append("For context, the author habitually writes like this: \(voice.voiceContext) Preserve their "
                + "vocabulary and characteristic phrasing where doing so doesn't conflict with the instructions above.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func isPlainCleanup(
        template: NoteTemplate?, style: WritingStyle, cleanupLevel: CleanupLevel
    ) -> Bool {
        template == nil && style == .none && cleanupLevel == .light
    }

    /// The plain clean-up for a dictation in another language (`CleanupLanguage`): the same light edit, said for
    /// that language, and told outright to stay in it. What the stricter guard keeps is what this asks for.
    static func cleanupInstructions(for language: CleanupLanguage.Rules) -> String {
        let sounds = language.fillers.sorted().prefix(3).map { "\u{201c}\($0)\u{201d}" }.joined(separator: ", ")
        return """
            Clean up this dictated transcript. It is in \(language.name): keep it in \(language.name) and never \
            translate it. Remove hesitation sounds (\(sounds)) and words said twice by mistake, fix punctuation and \
            capital letters, and fix a wrong word ending or article (for example the case or gender of a noun).

            Keep every other word exactly as it was said: do not replace words with other words, do not drop words, \
            and do not add anything. This is light editing, not rewriting: keep the same paragraph breaks, add no \
            quotation marks, headings or formatting, and never reply to the text or describe it.
            """
    }

    /// Builds the single instruction string for a dictation's rewrite pass.
    ///
    /// The old pipeline ran template *or* style and never both: if an app
    /// had an auto-template, its style was quietly discarded. Composing the
    /// two into one instruction keeps both effects — the template governs
    /// structure, the style governs tone — without paying for a second
    /// round-trip through the model.
    ///
    /// Returns `nil` only for Raw, which means "don't touch my words at
    /// all" — terminals and code editors, where even cleanup would be
    /// corruption. Every other style always returns instructions now: at
    /// minimum the cleanup baseline above.
    ///
    /// Template instructions are deliberately left as the sole primary
    /// instruction when a template is set, rather than layered under the
    /// cleanup baseline too — they already imply clean output as a side
    /// effect of restructuring into a specific shape, and demoting a
    /// carefully-worded template instruction to an "additionally" clause
    /// under a generic preamble risks the model weighting it less.
    ///
    /// `voice` is the user's generated Voice Profile. It never triggers a
    /// pass on its own — Raw is unaffected by it either way — it only
    /// colours a pass that was already going to happen.
    static func instructions(
        template: NoteTemplate?, style: WritingStyle, cleanupLevel: CleanupLevel = .light,
        voice: VoiceProfile? = nil, language: CleanupLanguage.Rules? = nil
    ) -> String? {
        guard !style.skipsAllProcessing else { return nil }
        // Another language: only the plain clean-up, worded for it (no English filler examples, no English persona).
        if let language {
            return isPlainCleanup(template: template, style: style, cleanupLevel: cleanupLevel)
                ? cleanupInstructions(for: language) : nil
        }

        let tone = style.instructions
        var base: String
        switch (template, tone) {
        case (nil, nil):
            base = cleanupInstructions
        case (nil, let tone?):
            base = cleanupInstructions + """


                Additionally, apply this tone throughout: \(tone)
                """
        case (let template?, nil):
            base = template.instructions + template.workedExampleBlock
        case (let template?, let tone?):
            base = template.instructions + template.workedExampleBlock + """


                Additionally, apply this tone throughout, without changing \
                the structure described above: \(tone)
                """
        }

        if cleanupLevel == .concise {
            base += """


                \(conciseInstructions)
                """
        }

        guard let voice else { return base }
        // Deliberately subordinate to the instructions above: the profile
        // says *whose* voice to keep, not what tone to write in, so a
        // "Formal" rule can't be overridden by a casual-sounding persona.
        return base + """


            For context, the author habitually writes like this: \
            \(voice.voiceContext) Preserve their vocabulary and characteristic \
            phrasing where doing so doesn't conflict with the instructions above.
            """
    }
}
