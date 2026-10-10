import AppKit
import Carbon.HIToolbox
import Foundation

struct Transform: Identifiable {
    /// What a transform is for — decides its safety check (`TransformGuard`) and how long its output may be.
    enum Kind {
        /// Rewrites the text itself: same meaning, same length, better written.
        case polish
        /// Builds a structured prompt out of rough notes: longer, organized.
        case prompt
        /// The user's own instructions — anything from "translate to German" to "make it a list".
        case custom
    }

    let id: String
    let name: String
    let keyLabel: String
    let keyCode: UInt16
    let description: String
    let instructions: String
    var kind: Kind = .custom
    /// Worked examples (input → output) given to the model with the instructions — the most reliable way to steer a
    /// small model (measured: a rule alone was satisfied in spirit and ignored in practice; an example wasn't).
    var examples: [(input: String, output: String)] = []
    /// Only true for `CustomTransform`-backed entries — gates the edit/
    /// delete affordances `TransformsPage` shows on a card, so a built-in
    /// never offers to delete itself.
    var isCustom = false

    /// The two built-ins. Rewritten 2026-09-30 after measuring the originals on 12 real dictations: under dictation
    /// cleanup's "lightly edit, stay short" rules Polish only moved commas, and Prompt Engineer squeezed every request
    /// into one line ending in its own instruction ("Constraints/Format: Structured prompt for AI assistant."), dropped
    /// details and invented requirements. Prompt Engineer follows the 2026 guidance of Anthropic (Claude and Claude
    /// Code), OpenAI (GPT-6, Codex) and Google (Gemini): the outcome first, the context with every specific detail, each
    /// request on its own, only the constraints actually stated, how to tell it's done, and what the user was unsure of
    /// as a question rather than a guess.
    static let all: [Transform] = [
        Transform(
            id: "polish",
            name: "Polish",
            keyLabel: "⌥1",
            keyCode: UInt16(kVK_ANSI_1),
            description: "Fixes grammar, spelling and punctuation and tightens " +
                         "the wording without changing meaning or tone.",
            instructions: """
                Polish the text so it reads as if it had been written with care rather than spoken. It was usually \
                dictated, so it can contain run-on sentences, false starts, repeated words and spoken grammar.
                - Fix grammar, spelling and punctuation ("needs fixed" → "needs to be fixed", "Mac OS" → "macOS").
                - Remove false starts, stumbles and accidentally repeated words.
                - Split run-on sentences into clear, complete sentences, in the speaker's order.
                - Keep the meaning, the voice and the tone: "I" stays "I", a question stays a question, a request stays \
                a request, and "I think", "maybe" and "not sure" stay, because they say how sure the speaker is.
                - Keep contractions such as can't, it's, there's and I'm: expanding them makes the speaker sound stiff.
                - Keep about the same length, and keep existing line breaks and lists.
                - Write times like 3pm and 10:30am.
                """,
            kind: .polish,
            examples: [
                ("so the new onboarding it works but the permissions screen it shows twice when you restart the app and "
                    + "that needs fixed before friday i think",
                 "The new onboarding works, but the permissions screen shows twice when you restart the app. That needs "
                    + "to be fixed before Friday, I think."),
                ("Can you send me the the updated numbers for Q3, I need them for the the board meeting at 10.30 am on "
                    + "Tuesday",
                 "Can you send me the updated numbers for Q3? I need them for the board meeting at 10:30am on Tuesday."),
                ("We tried moving the database to Supabase but the migration it failed twice, the second time because of "
                    + "the auth tables, so maybe we stay on Postgres for now",
                 "We tried moving the database to Supabase, but the migration failed twice, the second time because of "
                    + "the auth tables. So maybe we stay on Postgres for now."),
            ]),
        Transform(
            id: "promptEngineer",
            name: "Prompt Engineer",
            keyLabel: "⌥2",
            keyCode: UInt16(kVK_ANSI_2),
            description: "Turns a rough idea into a clear, well-structured " +
                         "prompt for an AI assistant.",
            instructions: """
                Turn the text into a clear prompt that the user will send to an AI assistant such as Claude, ChatGPT \
                or Codex. The text is the user's own rough, spoken description of what they want, so write the prompt \
                in their voice ("I", "my"), addressed to the assistant.
                Use this structure, and leave out any part the text gives you nothing for:
                1. First line: the goal, as one direct sentence: what the user wants done or answered. When the user \
                asks for a plan, an explanation, research or a review, the goal is exactly that, not the work itself.
                2. "Context:" what the text describes: the current behaviour, where it happens, what they have seen or \
                tried, and why it matters. Keep every specific detail: names, files, numbers, places on screen.
                3. "What I need:" each separate request or question as its own line starting with "- ".
                4. "Constraints:" only limits the user actually stated, such as "don't change the API".
                5. "Done when:" how to check the result, only when the text says or clearly implies it.
                6. "Open questions:" whatever the user said they were unsure about, asked as a question.
                Put each section name on its own line, as plain words followed by a colon. Keep the user's own \
                uncertainty ("I think the file is called …"). The assistant will act on this prompt, so a requirement \
                the user never mentioned sends it the wrong way: add no files, technologies, steps or requirements of \
                your own, and never answer the request yourself. A one-line request stays one line.
                """,
            kind: .prompt,
            examples: [
                ("ok so the search in the notes app it's really slow when you have like a thousand notes, it takes maybe "
                    + "two seconds per keystroke, I think it's the filter in NotesListViewModel it re-sorts everything "
                    + "every time. can you make it fast but don't change how the results are ordered",
                 """
                 Make search in the notes app fast with around a thousand notes.

                 Context:
                 With about a thousand notes, each keystroke in search takes around two seconds. I think the cause is \
                 the filter in NotesListViewModel, which re-sorts every note on each keystroke.

                 What I need:
                 - Find what makes search slow and fix it.

                 Constraints:
                 - Keep the order of the search results exactly as it is now.

                 Done when:
                 - Typing in search responds without a noticeable delay with about a thousand notes, and the results \
                 come back in the same order as before.

                 Open questions:
                 - Is the re-sort in NotesListViewModel really the cause? Check before changing it.
                 """),
                ("I want to understand how Linear does their command menu, the one you open with command K, how they "
                    + "group the commands and how the search works, because ours feels cluttered. not sure if we should "
                    + "copy it or do something simpler",
                 """
                 Explain how Linear designs its ⌘K command menu, so I can decide how to improve ours.

                 Context:
                 Our command menu feels cluttered. I'm looking at Linear's menu, the one that opens with ⌘K.

                 What I need:
                 - How Linear groups the commands in the menu.
                 - How its search works.

                 Open questions:
                 - Should we copy Linear's approach or do something simpler? Give me the trade-offs.
                 """),
                ("the header on the pricing page used to be bigger and bolder, now it looks thin and small, I think it "
                    + "changed with the last update",
                 """
                 Bring the header on the pricing page back to how it looked before the last update: bigger and bolder.

                 Context:
                 The header on the pricing page now looks thin and small. It used to be bigger and bolder, and I think \
                 it changed with the last update.

                 Open questions:
                 - Did the last update change it? Check before changing anything.
                 """),
                ("rename the variable tmp to retryCount in the upload function",
                 "Rename the variable tmp to retryCount in the upload function."),
            ]),
    ]

    /// Prompt Engineer for a coding agent (Claude Code, Codex, a terminal or an editor — `DestinationDetector`): the
    /// general instructions and examples plus one sentence about who reads the prompt. Measured 2026-09-30 on 9 real
    /// dictations to Claude Code and Codex: a separate, fully coding-specific set of instructions and examples read the
    /// user less faithfully on Apple's small model ("make a plan" became "build it", "whiter" became "more gray"), so
    /// the difference is kept to what an agent needs — names kept exactly, and how to check a problem is gone.
    static let promptEngineerForCoding = Transform(
        id: "promptEngineer",
        name: "Prompt Engineer",
        keyLabel: "⌥2",
        keyCode: UInt16(kVK_ANSI_2),
        description: all[1].description,
        instructions: all[1].instructions + """

            This prompt goes to a coding agent, such as Claude Code or Codex, working in the user's project: keep every \
            file, screen, function and error message exactly as written, and when the text describes a problem, say \
            under "Done when:" how the agent can tell it is fixed.
            """,
        kind: .prompt,
        examples: all[1].examples)

    /// This transform as it should run for `destination`: Prompt Engineer writes a coding agent a coding task.
    func adapted(to destination: Destination?) -> Transform {
        id == "promptEngineer" && destination == .codingAgent ? Self.promptEngineerForCoding : self
    }

    /// ⌥1/⌥2 are the two built-ins' own territory (see `ProfileHotkeySlot`'s
    /// own comment on why Option+digit is `TransformManager`'s) — a custom
    /// transform gets the next slot up, ⌥3 through ⌥9, assigned by its
    /// position in `CustomTransformStore.load()` rather than stored on the
    /// transform itself, so deleting one automatically closes the gap
    /// instead of leaving a dead slot behind. An 8th+ custom transform is
    /// still fully usable from the page itself, just without a global
    /// shortcut — seven is what the keyboard's own top row has left.
    private static let customSlotKeyCodes: [UInt16] = [
        UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
        UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
    ]

    /// `Transform.all` plus a given list of custom ones, mapped into the
    /// same display/runnable shape — the one place slot-to-shortcut
    /// assignment happens, shared by `allIncludingCustom` below (reads the
    /// store fresh) and `TransformsPage` (passes its own `@State` mirror,
    /// so the card grid updates immediately on edit/delete without a
    /// round-trip through disk).
    static func merging(_ customs: [CustomTransform]) -> [Transform] {
        let mapped = customs.enumerated().map { index, custom -> Transform in
            let keyCode = customSlotKeyCodes.indices.contains(index) ? customSlotKeyCodes[index] : nil
            return Transform(
                id: "custom-\(custom.id.uuidString)",
                name: custom.name,
                keyLabel: keyCode.map { _ in "⌥\(index + 3)" } ?? "—",
                keyCode: keyCode ?? .max,
                description: custom.instructions,
                instructions: custom.instructions,
                kind: .custom,
                isCustom: true)
        }
        return all + mapped
    }

    /// `Transform.all` plus every saved `CustomTransform`, freshly resolved
    /// — never cached, the same "read the store, don't hold a stale copy"
    /// rule every other `*Store.load()` in this app already follows.
    static var allIncludingCustom: [Transform] { merging(CustomTransformStore.load()) }

    // MARK: - Self test (slot assignment)

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        check(merging([]).count == all.count,
              "no customs: merging([]) is exactly the two built-ins")

        let three = (1...3).map { CustomTransform(name: "Custom \($0)", instructions: "Do thing \($0)") }
        let mergedThree = merging(three)
        check(mergedThree.count == all.count + 3, "three customs appended after the built-ins")
        check(mergedThree[2].keyLabel == "⌥3" && mergedThree[3].keyLabel == "⌥4"
              && mergedThree[4].keyLabel == "⌥5",
              "custom slots start at ⌥3 and count up in order")
        check(mergedThree[2].isCustom && !mergedThree[0].isCustom,
              "isCustom distinguishes a custom entry from a built-in")
        check(mergedThree[2].id == "custom-\(three[0].id.uuidString)",
              "a custom entry's id round-trips its own CustomTransform.id")

        // Only 7 slots (⌥3…9) exist — an 8th custom transform is still
        // listed (runnable manually) but gets no working shortcut.
        let eight = (1...8).map { CustomTransform(name: "Custom \($0)", instructions: "x") }
        let mergedEight = merging(eight)
        check(mergedEight.count == all.count + 8, "an 8th custom transform still appears in the list")
        check(mergedEight.last?.keyLabel == "—", "the 8th custom transform has no shortcut slot left")

        // No keyCode collisions between built-ins and customs, or between
        // two customs — a real hotkey monitor picks the *first* match, so
        // a collision would silently make one transform unreachable.
        let keyCodes = mergedEight.map(\.keyCode).filter { $0 != .max }
        check(Set(keyCodes).count == keyCodes.count, "every assigned keyCode is unique, no collisions")

        return passed
    }
}

struct CustomTransform: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var instructions: String
}

/// User-created Transforms — Wispr Flow's own "Create your own" / "Upload
/// your own prompt" card, which the two hardcoded built-ins above had no
/// equivalent of. Same file-backed JSON pattern as `SnippetStore`.
enum CustomTransformStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("custom_transforms.json")
    }

    static func load() -> [CustomTransform] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([CustomTransform].self, from: data)
        else { return [] }
        return items
    }

    static func save(_ items: [CustomTransform]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Global ⌥1 / ⌥2 (plus ⌥3…9 for any custom transform) hotkeys that rewrite
/// the currently selected text in place, in any app — like Wispr Flow's
/// Transforms. Uses the on-device model.
///
/// The keys are taken with an event tap (`TransformKeyTap`), not watched with an `NSEvent` monitor as they were: a
/// monitor can't stop a key, so the app in front also got ⌥1 and typed "¡" over the selection before Murmur could
/// copy it — the transform then found nothing selected, and the text was gone.
@MainActor
final class TransformManager {
    private let engine: RewriteEngine
    private var monitor: Any?
    private let keyTap = TransformKeyTap()
    private var isRunning = false
    /// Set right after a transform successfully pastes its result, cleared
    /// once `undoLast()` is used (or another transform runs) — a plain
    /// flag rather than tracking the original text, since forwarding to
    /// the target app's own ⌘Z is what actually restores it correctly.
    /// Reconstructing the paste ourselves would need to know and re-select
    /// the exact range that's now on screen in an arbitrary third-party
    /// app, which nothing here has any way to do reliably.
    private var canUndo = false

    /// Status line for the UI; nil clears it.
    var onStatus: ((String?) -> Void)?
    var onError: ((String) -> Void)?
    /// The same, said briefly in the HUD over the app you're in — with an SF Symbol to go with it — since a transform
    /// runs from a key or the nav bar, not from Murmur's window where `onError` shows.
    var onFailure: ((_ message: String, _ symbol: String) -> Void)?

    init(engine: RewriteEngine) {
        self.engine = engine
    }

    func startMonitoring() {
        stopMonitoring()
        // Both are called on the main queue (`TransformKeyTap.handle`).
        keyTap.onTransform = { [weak self] keyCode, pressed in
            guard let transform = Transform.allIncludingCustom.first(where: { $0.keyCode == keyCode }) else { return }
            MainActor.assumeIsolated { self?.run(transform, pressed: pressed) }
        }
        keyTap.onUndo = { [weak self] in MainActor.assumeIsolated { self?.undoLast() } }
        if keyTap.start() {
            dictationLog.notice("transform keys: taken with an event tap")
            return
        }
        dictationLog.notice("transform keys: no event tap (Accessibility not granted yet), only watching")
        // No Accessibility yet, so no tap: watch the keys instead, as before. They can't be stopped this way, but
        // nothing can be pasted without Accessibility either.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return }
            let modifiers = event.modifierFlags.intersection(
                [.command, .option, .control, .shift])
            // ⌥⇧Z: undo the last transform via the target app's own ⌘Z,
            // not a combo any other global-hotkey consumer in this app
            // touches (Option+digit is Transforms' own, Control+Shift+digit
            // is App Profiles', Scratchpad/Notetaker's own combos are both
            // user-rebindable away from this by default).
            if modifiers == [.option, .shift], event.keyCode == UInt16(kVK_ANSI_Z) {
                Task { @MainActor in self.undoLast() }
                return
            }
            guard modifiers == .option else { return }
            guard let transform = Transform.allIncludingCustom.first(
                where: { $0.keyCode == event.keyCode }) else { return }
            Task { @MainActor in self.run(transform) }
        }
    }

    func stopMonitoring() {
        keyTap.stop()
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// `pressed` is the key that asked for it, when a key did (not the nav bar): with nothing selected the key is
    /// given back to the app in front, so ⌥2 still types "€" or "™" there as it always has.
    func run(_ transform: Transform, pressed: CGEvent? = nil) {
        guard !isRunning else { return }
        if let paused = LicenseStore.shared.pausedExplanation {
            onError?(paused)
            SoundEffect.play("Basso")
            return
        }
        guard engine.isAvailable else {
            onError?(engine.availabilityNote ?? "On-device model unavailable.")
            SoundEffect.play("Basso")
            return
        }
        isRunning = true
        onStatus?("\(transform.name): reading selection")
        // The model that writes the prompt loads while the selection is read.
        if transform.kind == .prompt, SpokenCommand.usesGemma { Task { await Translator.shared.prewarm(.gemma) } }

        Task {
            defer {
                isRunning = false
                onStatus?(nil)
            }
            // The field says outright that nothing is selected: the key was meant for typing.
            if let pressed, await Task.detached(priority: .userInitiated, operation: { CursorContext.nothingIsSelected() }).value {
                TransformKeyTap.type(pressed)
                return
            }
            let saved = TextInserter.saveClipboard()
            guard let selection = await TextInserter.copySelection(),
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                TextInserter.restoreClipboard(saved)
                // A field that doesn't say what's selected, and ⌘C copied nothing: the key was meant for typing too.
                if let pressed {
                    TransformKeyTap.type(pressed)
                    return
                }
                onError?("Select some text first, then press " +
                         "\(transform.keyLabel).")
                onFailure?("Select some text first", "character.cursor.ibeam")
                SoundEffect.play("Basso")
                return
            }

            onStatus?("\(transform.name): rewriting")
            // Where the selection is — Prompt Engineer writes Claude Code or Codex a coding task (`DestinationDetector`).
            let front = NSWorkspace.shared.frontmostApplication
            let (bundleID, pid) = (front?.bundleIdentifier, front?.processIdentifier)
            let destination = await Task.detached { DestinationDetector.detect(bundleID: bundleID, pid: pid) }.value
            do {
                let rewritten = try await Self.perform(transform, on: selection, engine: engine, destination: destination)
                // The same reliable paste as dictation (`TextInserter`), handing back the clipboard the user had
                // before the selection was copied.
                TextInserter.insert(rewritten, restoring: saved) { [weak self] outcome in
                    guard outcome == .notObserved else { return }
                    self?.onError?("The app in front never took the rewritten text. It's on the clipboard.")
                    self?.onFailure?("Not pasted", "doc.on.clipboard")
                }
                canUndo = true
                keyTap.canUndo = true
                SoundEffect.play("Tink")
            } catch let failure as TransformFailure {
                TextInserter.restoreClipboard(saved)
                onError?(failure.localizedDescription)
                onFailure?(failure.shortMessage, "arrow.uturn.backward")
                SoundEffect.play("Basso")
            } catch {
                TextInserter.restoreClipboard(saved)
                onError?("\(transform.name) failed: \(error.localizedDescription)")
                onFailure?("Couldn’t rewrite that", "exclamationmark.triangle")
                SoundEffect.play("Basso")
            }
        }
    }

    /// Runs a transform on arbitrary text (used by the Transforms page).
    func apply(_ transform: Transform, to text: String) async throws -> String {
        try await Self.perform(transform, on: text, engine: engine)
    }

    /// Why a transform gave nothing back to paste.
    enum TransformFailure: LocalizedError {
        case refused(name: String, TransformGuard.Rejection)
        case empty(name: String)

        var errorDescription: String? {
            switch self {
            case let .refused(name, why): "\(name) left your text as it was: \(why.rawValue)."
            case let .empty(name): "\(name) came back empty — try again."
            }
        }
        /// For the HUD.
        var shortMessage: String {
            switch self {
            // Not failures: there was nothing to do.
            case .refused(_, .notShorter): "Already concise"
            case .refused(_, .unchanged): "Nothing to change"
            case .refused: "Left your text as it was"
            case .empty: "Came back empty"
            }
        }
        /// The text was fine as it was — said quietly, without the error sound.
        var isNothingToDo: Bool {
            switch self {
            case .refused(_, .notShorter), .refused(_, .unchanged): true
            default: false
            }
        }
    }

    /// The model's rewrite and the safety check's verdict on it — shared by the keys, the Transforms page and the
    /// command line (`--transform`), so they can't drift.
    nonisolated static func attempt(_ transform: Transform, on text: String, engine: RewriteEngine,
                                    destination: Destination? = nil) async throws
        -> (output: String, rejection: TransformGuard.Rejection?) {
        // Prompt Engineer is written by Gemma 4 when it is on this Mac, as a spoken edit is (`PromptDraft.byGemma`):
        // already checked there. Apple's model writes it when Gemma isn't here or what it wrote was refused.
        if transform.kind == .prompt,
           let prompt = await PromptDraft.byGemma(text, coding: destination == .codingAgent) {
            dictationLog.notice("prompt engineer: Gemma 4 wrote \(prompt.count) characters")
            return (prompt, nil)
        }
        let output = try await engine.transform(text, with: transform.adapted(to: destination), destination: destination)
        return (output, output.isEmpty ? nil : TransformGuard.rejection(original: text, output: output, kind: transform.kind))
    }

    /// The rewritten text, or `TransformFailure` when there's nothing safe to use.
    nonisolated static func perform(_ transform: Transform, on text: String, engine: RewriteEngine,
                                    destination: Destination? = nil) async throws -> String {
        let (output, rejection) = try await attempt(transform, on: text, engine: engine, destination: destination)
        guard !output.isEmpty else { throw TransformFailure.empty(name: transform.name) }
        if let rejection { throw TransformFailure.refused(name: transform.name, rejection) }
        return output
    }

    /// Reverts the most recent transform by sending the target app its own
    /// ⌘Z — the safety net Transforms didn't have: a transform used to
    /// paste over your selection with no way back except whatever the
    /// target app's own undo happened to still remember unprompted.
    func undoLast() {
        guard canUndo, !isRunning else {
            onError?("Nothing to undo.")
            onFailure?("Nothing to undo", "arrow.uturn.backward")
            SoundEffect.play("Basso")
            return
        }
        canUndo = false
        keyTap.canUndo = false
        isRunning = true
        onStatus?("Undoing last transform")
        TextInserter.sendKeystroke(ShortcutKeys.undo, flags: .maskCommand)
        SoundEffect.play("Tink")
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            isRunning = false
            onStatus?(nil)
        }
    }
}

// MARK: - Taking the keys

/// Takes ⌥1…⌥9 (the ones a transform is assigned to) and ⌥⇧Z (while there is a transform to undo) before the app in
/// front sees them, key-up and repeats included. Every other key passes through untouched, as does everything while
/// Murmur's own window is in front. Like `EscapeInterceptor`, but kept for as long as the app runs. Needs
/// Accessibility; without it `start()` returns false.
final class TransformKeyTap {
    /// A transform's key was pressed: its key code, and the key itself to give back if there's nothing to transform.
    var onTransform: (_ keyCode: UInt16, _ pressed: CGEvent?) -> Void = { _, _ in }
    var onUndo: () -> Void = {}
    /// Whether ⌥⇧Z has something to undo; when it hasn't, the key is left to the app in front.
    var canUndo = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys taken at key-down, so the app never gets their key-up or repeats either.
    private var held: Set<UInt16> = []

    /// Marks a key Murmur is giving back, so this tap lets it through.
    private static let givenBack: Int64 = 0x4D75726D

    enum Action: Equatable { case pass, swallow, transform, undo }

    /// What to do with a key — the whole decision, apart from the tap that carries it out.
    static func action(keyDown: Bool, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool, isHeld: Bool, givenBack: Bool,
                       ownAppActive: Bool, canUndo: Bool, assigned: (UInt16) -> Bool) -> Action {
        if givenBack { return .pass }
        if !keyDown { return isHeld ? .swallow : .pass }
        if isHeld, isRepeat { return .swallow }
        if ownAppActive { return .pass }
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        if modifiers == [.maskAlternate, .maskShift], keyCode == UInt16(kVK_ANSI_Z) {
            return canUndo ? (isRepeat ? .swallow : .undo) : .pass
        }
        guard modifiers == .maskAlternate, assigned(keyCode) else { return .pass }
        return isRepeat ? .swallow : .transform
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: transformTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        held = []
    }

    /// Gives a taken key back to the app in front: the key-down as it was pressed, then its key-up.
    static func type(_ pressed: CGEvent) {
        pressed.setIntegerValueField(.eventSourceUserData, value: givenBack)
        pressed.post(tap: .cgSessionEventTap)
        let keyCode = CGKeyCode(pressed.getIntegerValueField(.keyboardEventKeycode))
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        up.flags = pressed.flags
        up.setIntegerValueField(.eventSourceUserData, value: givenBack)
        up.post(tap: .cgSessionEventTap)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off if it's ever slow, or while a password is typed; switch it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let action = Self.action(
            keyDown: type == .keyDown, keyCode: keyCode, flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, isHeld: held.contains(keyCode),
            givenBack: event.getIntegerValueField(.eventSourceUserData) == Self.givenBack,
            ownAppActive: NSRunningApplication.current.isActive, canUndo: canUndo,
            assigned: { key in Transform.allIncludingCustom.contains { $0.keyCode == key } })
        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            if type == .keyUp { held.remove(keyCode) }
        case .transform:
            held.insert(keyCode)
            let pressed = event.copy()
            DispatchQueue.main.async { [weak self] in self?.onTransform(keyCode, pressed) }
        case .undo:
            held.insert(keyCode)
            DispatchQueue.main.async { [weak self] in self?.onUndo() }
        }
        return nil
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ got: Action, _ expected: Action, _ label: String) {
            if got != expected { passed = false }
            print("\(got == expected ? "PASS" : "FAIL"): transform keys: \(label)\(got == expected ? "" : " — got \(got)")")
        }
        let one = UInt16(kVK_ANSI_1), nine = UInt16(kVK_ANSI_9), z = UInt16(kVK_ANSI_Z)
        func act(down: Bool = true, _ key: UInt16, _ flags: CGEventFlags, isRepeat: Bool = false, held: Bool = false,
                 givenBack: Bool = false, own: Bool = false, canUndo: Bool = false) -> Action {
            action(keyDown: down, keyCode: key, flags: flags, isRepeat: isRepeat, isHeld: held, givenBack: givenBack,
                   ownAppActive: own, canUndo: canUndo, assigned: { $0 == one })
        }
        check(act(one, .maskAlternate), .transform, "⌥1 is taken and runs its transform")
        check(act(one, [.maskAlternate, .maskNumericPad, .maskNonCoalesced]), .transform, "…whatever other flags the key carries")
        check(act(one, .maskAlternate, isRepeat: true, held: true), .swallow, "its repeats are taken too")
        check(act(down: false, one, .maskAlternate, held: true), .swallow, "and its key-up")
        check(act(down: false, one, [], held: true), .swallow, "…even if Option was let go first")
        check(act(down: false, one, .maskAlternate), .pass, "a key-up that wasn't taken passes")
        check(act(one, []), .pass, "a plain 1 passes")
        check(act(one, [.maskAlternate, .maskCommand]), .pass, "⌥⌘1 passes")
        check(act(one, [.maskAlternate, .maskShift]), .pass, "⌥⇧1 passes")
        check(act(nine, .maskAlternate), .pass, "⌥9 passes when no transform has it")
        check(act(one, .maskAlternate, own: true), .pass, "nothing is taken in Murmur's own window")
        check(act(one, .maskAlternate, givenBack: true), .pass, "a key Murmur gave back passes")
        check(act(z, [.maskAlternate, .maskShift], canUndo: true), .undo, "⌥⇧Z undoes when there is something to undo")
        check(act(z, [.maskAlternate, .maskShift]), .pass, "…and passes when there isn't")
        return passed
    }
}

private func transformTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<TransformKeyTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
