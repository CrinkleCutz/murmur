import AppKit
import SwiftUI
import AVFoundation
import Foundation
import FluidAudio
import FoundationModels

/// Every command-line mode ends through here. `Darwin.exit` runs C++ static destructors, and whisper.cpp's Metal backend
/// aborts in its own when a model is still loaded — so each whisper.cpp check ended in a crash report and a non-zero
/// status after printing the right answer. The app itself already quits with `_exit` for the same reason
/// (`AppDelegate.applicationShouldTerminate`).
private func exit(_ status: Int32) -> Never {
    fflush(stdout)
    fflush(stderr)
    _exit(status)
}

@main
struct MurmurMain {
    @MainActor
    static func main() async {
        Settings.migrateLegacyDefaults()
        var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
        var mode: Mode = .app
        var localeIdentifier = "en-US"
        var engineName = "apple"
        var whisperModel = Settings.whisperModel
        var sherpaModel = Settings.sherpaModel
        var templateName: String?
        /// --command: the text that's selected when the command is said.
        var commandSelection: String?
        /// --code / --transcribe: the coding field to act as (shell, editor or prompt) and its project folder.
        var probeBundleID: String?
        var codeFieldKind: CodeField.Kind?
        var codeProject: URL?
        /// The `CodeField.Context` the options describe, as a dictation into that field would have it.
        func codeContext() -> CodeField.Context? {
            guard let kind = codeFieldKind else { return nil }
            let root = codeProject.flatMap(CodeField.repositoryRoot(of:))
            return CodeField.Context(kind: kind, projectRoot: root, names: root.map(ProjectNames.names(in:)) ?? [],
                                     folders: root.map(ProjectNames.folders(in:)) ?? [:])
        }
        var transformID: String?
        var bundleID: String?
        var ctcVariant: String?
        var noTrim = false
        var transcribeList = false
        var chunked = false
        var noGuard = false
        var benchRuns = 6
        var usePrewarm = false
        var benchWait = 1.5
        var licensePublicKey: String?
        var licenseMachineHash: String?
        /// --translate: the language spoken, the one to write, and which translator (gemma, eurollm, apple; default: the
        /// one Murmur would pick).
        var translateFrom = "en"
        var translateTo = "de"
        var translateVia: TranslateInto.Engine?

        while let argument = arguments.next() {
            switch argument {
            case "--transcribe":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .transcribe(path)
            case "--mic-check":
                mode = .micCheck
            case "--ax-probe":
                mode = .axProbe
            case "--screen-probe":
                mode = .screenProbe
            case "--dest-probe":
                mode = .destProbe
            case "--own-field-check":
                mode = .ownFieldCheck
            case "--render-settings":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .renderSettings(path)
            case "--learn-check":
                guard let original = arguments.next(), let edited = arguments.next() else { usageAndExit() }
                mode = .learnCheck(original, edited)
            case "--duck-check":
                mode = .duckCheck
            case "--mic-compare":
                guard let seconds = arguments.next().flatMap(Double.init), let dir = arguments.next() else { usageAndExit() }
                mode = .micCompare(seconds, dir)
            case "--edit-records":
                mode = .editRecords
            case "--render-shell":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .renderShell(path)
            case "--render-sheets":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .renderSheets(path)
            case "--render-toast":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .renderToast(path)
            case "--render-snippets":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .renderSnippets(path)
            case "--render-template-sheet":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .renderTemplateSheet(path)
            case "--transcribe-list":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .transcribe(path)
                transcribeList = true
            case "--engine":
                engineName = arguments.next() ?? engineName
            case "--no-trim":
                noTrim = true
            case "--chunked":
                chunked = true
            case "--no-guard":
                noGuard = true
            case "--guard-check":
                mode = .guardCheck
            case "--secure-input":
                mode = .secureInput
            case "--license-verify":
                guard let raw = arguments.next() else { usageAndExit() }
                mode = .licenseVerify(raw)
            case "--public-key":
                licensePublicKey = arguments.next()
            case "--machine-hash":
                licenseMachineHash = arguments.next()
            case "--license-live-check":
                let server = arguments.next() ?? ""
                let key = arguments.next() ?? ""
                guard !server.isEmpty, !key.isEmpty else { usageAndExit() }
                mode = .licenseLiveCheck(server, key)
            case "--support-check":
                let server = arguments.next() ?? ""
                let text = arguments.next() ?? ""
                guard !server.isEmpty, !text.isEmpty else { usageAndExit() }
                mode = .supportCheck(server, text)
            case "--render-support":
                mode = .renderSupport(arguments.next() ?? NSTemporaryDirectory() + "murmur-support")
            case "--license-ui-check":
                mode = .licenseUICheck(arguments.next() ?? NSTemporaryDirectory() + "murmur-license-ui")
            case "--notetaker-check":
                let micPath = arguments.next() ?? ""
                let systemPath = arguments.next() ?? ""
                guard !micPath.isEmpty, !systemPath.isEmpty else { usageAndExit() }
                mode = .notetakerCheck(micPath, systemPath)
            case "--hud-check":
                mode = .hudCheck(arguments.next() ?? NSTemporaryDirectory() + "murmur-hud-check")
            case "--navbar-check":
                mode = .navBarCheck(arguments.next() ?? NSTemporaryDirectory() + "murmur-navbar-check")
            case "--prewarm":
                usePrewarm = true
            case "--wait":
                benchWait = Double(arguments.next() ?? "") ?? benchWait
            case "--runs":
                benchRuns = Int(arguments.next() ?? "") ?? benchRuns
            case "--pipeline-bench":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .pipelineBench(path)
            case "--edit-bench":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .editBench(text)
            case "--bench-text":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .benchText(text)
            case "--vad":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .vad(path)
            case "--whisper-model":
                whisperModel = arguments.next() ?? whisperModel
            case "--sherpa-model":
                sherpaModel = arguments.next() ?? sherpaModel
            case "--format":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .format(text)
            case "--transform":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .transform(text)
            case "--command":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .spokenCommand(text)
            case "--gemma-edit":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .gemmaEdit(text)
            case "--whisper-prompt":
                mode = .whisperPrompt
            case "--layout":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .layout(text)
            case "--selection":
                commandSelection = arguments.next()
            case "--field":
                codeFieldKind = arguments.next().flatMap(CodeField.Kind.init(rawValue:))
            case "--project":
                codeProject = arguments.next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            case "--code":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .code(text)
            case "--translate":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .translate(text)
            case "--translate-download":
                guard let name = arguments.next(), let model = TranslationModel(rawValue: name) else { usageAndExit() }
                mode = .translateDownload(model)
            case "--from":
                translateFrom = arguments.next() ?? translateFrom
            case "--to":
                translateTo = arguments.next() ?? translateTo
            case "--via":
                translateVia = arguments.next().flatMap { TranslateInto.Engine(rawValue: $0 == "eurollm" ? "euroLLM" : $0) }
            case "--canary-batch":
                guard let list = arguments.next() else { usageAndExit() }
                mode = .canaryBatch(list)
            case "--field-probe":
                mode = .fieldProbe
                // An optional bundle ID: probe that running app instead of the one in front (read in the background).
                if let next = arguments.next() { probeBundleID = next }
            case "--edit":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .edit(text)
            case "--harper-fix":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .harperFix(text)
            case "--ask":
                guard let question = arguments.next() else { usageAndExit() }
                mode = .ask(question)
            case "--history":
                mode = .history
            case "--history-search":
                guard let query = arguments.next() else { usageAndExit() }
                mode = .historySearch(query)
            case "--history-export":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .historyExport(path)
            case "--template":
                templateName = arguments.next() ?? templateName
            case "--transform-id":
                transformID = arguments.next() ?? transformID
            case "--selftest":
                mode = .selftest
            case "--locale":
                localeIdentifier = arguments.next() ?? localeIdentifier
            case "--bundle-id":
                bundleID = arguments.next() ?? bundleID
            case "--ctc-variant":
                ctcVariant = arguments.next() ?? ctcVariant
            case "--help", "-h":
                usageAndExit()
            default:
                usageAndExit()
            }
        }

        switch mode {
        case .selftest:
            let formatterPassed = TextFormatter.runSelfTest()
            let learnedPassed = LearnedStore.runSelfTest()
            let templatesPassed = NoteTemplateStore.runSelfTest()
            let askPassed = AskMurmur.runSelfTest()
            let profilesPassed = AppProfileStore.runSelfTest()
            let audioPassed = AudioRecorder.runSelfTest()
            let hallucinationPassed = HallucinationFilter.runSelfTest()
            let developerVocabPassed = DeveloperVocabulary.runSelfTest()
            let transformKeysPassed = TransformKeyTap.runSelfTest()
            let transformsPassed = Transform.runSelfTest() && transformKeysPassed
            let plausibilityPassed = TranscriptionPlausibility.runSelfTest()
            let harperPassed = HarperChecker.runSelfTest()
            let guardPassed = LLMEditGuard.runSelfTest()
            let trimmerPassed = TrailingSilenceTrimmer.runSelfTest()
            let correctionsPassed = SelfCorrectionResolver.runSelfTest()
            let timesPassed = TimeNormalizer.runSelfTest()
            let layoutPassed = DictationLayout.runSelfTest()
            let matchAppPassed = DestinationShaper.runSelfTest() && layoutPassed
            let shortcutKeysPassed = ShortcutKeys.runSelfTest()
            let healthPassed = MainThreadHealth.runSelfTest()
            let pastePassed = TextInserter.runSelfTest()
            let secureInputPassed = SecureInputProbe.runSelfTest()
            let styleGuardPassed = StyleRewriteGuard.runSelfTest()
            let notchPassed = NotchGeometry.runSelfTest()
            let navBarPassed = NavBarHUDController.runSelfTest()
            let licenseTokenPassed = LicenseVerifier.runSelfTest()
            let licenseGatePassed = LicenseGate.runSelfTest()
            let licenseStorePassed = await LicenseStore.runSelfTest()
            let updateSelectionPassed = UpdateSelection.runSelfTest()
            let licenseTilePassed = LicensePanelState.runSelfTest()
            let licensePreviewPassed = await LicensePreview.runSelfTest()
            let whisperPromptPassed = WhisperPrompt.runSelfTest()
            let liveChunksPassed = ChunkPlanner.runSelfTest()
            let microphonePassed = MicrophoneChoice.runSelfTest()
            let unsureWordsPassed = UnsureWordFix.runSelfTest()
            let cursorPassed = InsertionShaper.runSelfTest()
            let editLearnerPassed = EditLearner.runSelfTest()
            let sentLearnerPassed = SentMessageLearner.runSelfTest()
            let editRecordsPassed = EditRecordStore.runSelfTest()
            let dictionaryImportPassed = DictionaryImport.runSelfTest()
            let pasteLastPassed = PasteLastShortcut.runSelfTest()
            let commonWordsPassed = CommonWords.runSelfTest()
            let screenNamesPassed = ScreenContext.runSelfTest()
            let transformGuardPassed = TransformGuard.runSelfTest()
            let destinationPassed = DestinationDetector.runSelfTest()
            let templateLayoutPassed = TemplateLayout.runSelfTest()
            let rewritePromptPassed = RewriteEngine.runSelfTest()
            let snippetsPassed = SnippetStore.runSelfTest()
            let cleanupLanguagesPassed = CleanupLanguage.runSelfTest()
            let spokenCommandsPassed = SpokenCommand.runSelfTest()
            let spokenCodePassed = CodeDictation.runSelfTest()
            let projectNamesPassed = ProjectNames.runSelfTest()
            let codeFieldsPassed = CodeField.runSelfTest()
            let translatePassed = TranslateInto.runSelfTest()
            exit(formatterPassed && learnedPassed && templatesPassed && askPassed
                 && profilesPassed && audioPassed && hallucinationPassed
                 && developerVocabPassed && transformsPassed && plausibilityPassed
                 && harperPassed && guardPassed && trimmerPassed && correctionsPassed && timesPassed && matchAppPassed && shortcutKeysPassed && healthPassed && pastePassed
                 && secureInputPassed && styleGuardPassed && notchPassed && navBarPassed && licenseTokenPassed && licenseGatePassed && licenseStorePassed && updateSelectionPassed && licenseTilePassed && licensePreviewPassed && whisperPromptPassed && liveChunksPassed && microphonePassed && unsureWordsPassed && cursorPassed && editLearnerPassed && sentLearnerPassed && editRecordsPassed && dictionaryImportPassed && pasteLastPassed && commonWordsPassed && screenNamesPassed && transformGuardPassed && destinationPassed && templateLayoutPassed && rewritePromptPassed && snippetsPassed && cleanupLanguagesPassed && spokenCommandsPassed && spokenCodePassed && projectNamesPassed && codeFieldsPassed && translatePassed ? 0 : 1)

        case .pipelineBench(let path):
            // Recognizer decode + cleanup call, with and without starting the cleanup prompt's fixed prefix at the
            // moment recognition begins. Same audio, same engine instance (warm), alternating; totals are what matter.
            let engine = RewriteEngine()
            let whisperCpp = WhisperCppEngine()
            guard engine.isAvailable, let instructions = RewritePlan.instructions(
                template: nil, style: .none, cleanupLevel: .light,
                voice: Settings.useVoiceProfile ? VoiceProfileStore.load() : nil) else { print("model unavailable"); exit(1) }
            let url = URL(fileURLWithPath: path)
            let terms = LearnedStore.biasTerms(includeDeveloperVocabulary: false)
            func transcribe() async -> String {
                ((try? await whisperCpp.transcribe(fileAt: url, model: whisperModel, localeID: localeIdentifier, biasTerms: terms))?.text) ?? ""
            }
            _ = await transcribe()                       // load the model; not measured
            func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
            for run in 1...benchRuns {
                var t = Date()
                let rawA = await transcribe(); let asrA = ms(t); t = Date()
                let outA = await engine.cleanup(rawA, instructions: instructions, vocabularyTerms: terms); let llmA = ms(t)
                let session = engine.makeEditSession(instructions: instructions)
                t = Date()
                let rawB = await transcribe(); let asrB = ms(t); t = Date()
                let outB = await engine.cleanup(rawB, instructions: instructions, vocabularyTerms: terms, session: session); let llmB = ms(t)
                print("run \(run): as-now asr=\(asrA) llm=\(llmA) total=\(asrA + llmA) | early-prefix asr=\(asrB) llm=\(llmB) total=\(asrB + llmB) | identical=\(outA.text == outB.text)")
            }
            exit(0)

        case .editBench(let text):
            // Latency of the cleanup call with and without processing its fixed prompt prefix early (while the
            // recognizer would still be running). Outputs must be identical; only the time may differ.
            let engine = RewriteEngine()
            guard engine.isAvailable,
                  let instructions = RewritePlan.instructions(
                    template: nil, style: .none, cleanupLevel: .light,
                    voice: Settings.useVoiceProfile ? VoiceProfileStore.load() : nil) else { print("model unavailable"); exit(1) }
            var options = GenerationOptions(sampling: .greedy)
            options.maximumResponseTokens = Int(Double(text.split(separator: " ").count) * 2.5) + 30
            func timed(_ body: () async throws -> String) async -> (Int, String) {
                let t = Date(); let out = (try? await body()) ?? "<error>"
                return (Int(Date().timeIntervalSince(t) * 1000), out)
            }
            for run in 1...benchRuns {
                let a = await timed { try await engine.edit(text, instructions: instructions, options: options) }
                let session = engine.makeEditSession(instructions: instructions)
                try? await Task.sleep(nanoseconds: UInt64(benchWait * 1_000_000_000))   // stands in for speaking + the recognizer decode
                let b = await timed { try await engine.edit(text, instructions: instructions, options: options, session: session) }
                print("run \(run): as-now=\(a.0)ms  prefix-warmed=\(b.0)ms  outputs identical=\(a.1 == b.1)")
            }
            exit(0)

        case .benchText(let text):
            // Steady-state cost of each text stage, run repeatedly in ONE process — what a live dictation pays once
            // the app is warm, without the CLI's cold-start costs. Durations only.
            let developerVocabulary = AppProfileStore.developerVocabularyEnabled(forBundleID: bundleID)
            let engine = RewriteEngine()
            func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
            for run in 1...benchRuns {
                var t = Date()
                var formatted = TextFormatter(dictionary: TextFormatter.loadDictionary()).format(text)
                let tf = ms(t); t = Date()
                formatted = LearnedStore.apply(in: formatted, includeDeveloperVocabulary: developerVocabulary)
                let learned = ms(t); t = Date()
                formatted = SelfCorrectionResolver.resolve(TimeNormalizer.normalize(formatted)).text
                let resolver = ms(t); t = Date()
                formatted = SnippetStore.expand(in: formatted, recordUse: false)
                let snippets = ms(t); t = Date()
                let terms = LearnedStore.biasTerms(includeDeveloperVocabulary: developerVocabulary)
                let bias = ms(t); t = Date()
                _ = HarperChecker.fix(formatted, vocabulary: terms)
                let harper = ms(t)
                var model = -1
                if let instructions = RewritePlan.instructions(
                    template: nil, style: .none, cleanupLevel: .light,
                    voice: Settings.useVoiceProfile ? VoiceProfileStore.load() : nil), engine.isAvailable {
                    t = Date()
                    _ = await engine.cleanup(formatted, instructions: instructions, vocabularyTerms: terms)
                    model = ms(t)
                }
                print("run \(run): textformat=\(tf) learned=\(learned) resolver=\(resolver) snippets=\(snippets) biasTerms=\(bias) harper=\(harper) cleanup=\(model)")
            }
            exit(0)

        case .vad(let path):
            // What the voice-activity model makes of a recording, and what the
            // trailing-silence trim would do about it — for debugging why a
            // tail was or wasn't cut.
            let url = URL(fileURLWithPath: path)
            guard let manager = await VadEngine().loadedManager(),
                  let results = try? await manager.process(url) else {
                print("VAD unavailable")
                exit(1)
            }
            let chunk = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)
            print("chunks: \(results.count) x \(String(format: "%.3f", chunk))s")
            print("probabilities: " + results.map { String(format: "%.2f", $0.probability) }.joined(separator: " "))
            let analysis = await VadEngine().analyze(fileAt: url)
            let end = analysis?.lastSpeechEnd
            print("hasSpeech: \(analysis?.hasSpeech.description ?? "?")  lastSpeechEnd: \(end.map { String(format: "%.2f", $0) } ?? "nil")")
            if let end, let copy = TrailingSilenceTrimmer.trimmedCopy(of: url, speechEnd: end) {
                let file = try? AVAudioFile(forReading: copy)
                print("trim: would cut to \(file.map { String(format: "%.2f", Double($0.length) / $0.processingFormat.sampleRate) } ?? "?")s")
                try? FileManager.default.removeItem(at: copy)
            } else {
                print("trim: no cut")
            }
            exit(0)

        case .licenseVerify(let raw):
            // Checks a license file the way the app does — the interop test between the website's signer and this
            // verifier. Defaults: the app's own public key and this Mac's identity.
            let result = LicenseVerifier.verify(
                raw, publicKeyBase64: licensePublicKey ?? LicenseVerifier.productionPublicKey,
                machineHash: licenseMachineHash ?? MachineIdentity.hash())
            switch result {
            case .success(let file):
                let p = file.payload
                let iso = ISO8601DateFormatter()
                print("valid plan=\(p.plan) key=\(p.licenseKey) maxActivations=\(p.maxActivations) "
                      + "maintenanceUntil=\(p.maintenanceUntil.map(iso.string(from:)) ?? "none") "
                      + "recheckAfter=\(iso.string(from: p.recheckAfter)) graceDays=\(p.graceDays)")
                exit(0)
            case .failure(let problem):
                print("refused \(problem)")
                exit(1)
            }

        case .supportCheck(let server, let text):
            // Sends one real report through the app's own sender to a real server, and says what came back. The
            // message is the argument; the facts are this Mac's, exactly as the sheet would send them.
            guard let base = URL(string: server) else { usageAndExit() }
            let payload = await MainActor.run {
                SupportReport.Payload(message: text, email: "", diagnostics: SupportReport.diagnostics())
            }
            print("sending: \(payload.diagnostics)")
            let outcome = await SupportReport.send(payload, to: base.appendingPathComponent("api/support"))
            print("outcome: \(outcome)")
            exit(outcome == .sent ? 0 : 1)

        case .renderSupport(let path):
            // The report sheet drawn to <path>-sheet.png in a window that is never shown.
            NSApplication.shared.setActivationPolicy(.accessory)
            MainActor.assumeIsolated {
                FontLoader.registerManrope()
                let hosting = NSHostingView(rootView: AnyView(SupportReportSheet(onDone: {}, height: 560)))
                hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 560)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                window.displayIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-sheet.png"))
                    print("wrote \(path)-sheet.png")
                }
                exit(0)
            }

        case .licenseLiveCheck(let server, let key):
            // The real activate → check-in → deactivate against a licensing server, no window, no Keychain.
            guard let url = URL(string: server) else { usageAndExit() }
            let ok = await LicenseLiveCheck.run(server: url, key: key)
            exit(ok ? 0 : 1)

        case .licenseUICheck(let directory):
            // Settings' License tile in every state, and the HUD's paused notice, drawn to PNGs through an invisible,
            // click-through panel — nothing shows on screen, nothing takes focus, no real license or server involved.
            FontLoader.registerManrope()
            NSApplication.shared.setActivationPolicy(.accessory)
            let ok = await LicenseUICheck.run(outputDirectory: directory)
            exit(ok ? 0 : 1)

        case .navBarCheck(let directory):
            // The nav bar in each of its states, drawn to PNGs through an invisible, click-through panel — nothing shows
            // on screen and nothing takes focus.
            FontLoader.registerManrope()
            NSApplication.shared.setActivationPolicy(.accessory)
            let ok = await NavBarCheck.run(outputDirectory: directory)
            exit(ok ? 0 : 1)

        case .notetakerCheck(let micPath, let systemPath):
            // A captured meeting's two recordings (your mic, the other side's system audio) through the real
            // post-capture pipeline — diarize, transcribe each turn with the same engine Notetaker uses, assemble
            // — headless: no capture, no mic, no playback, no window. Prints the segments exactly as a saved note
            // would hold them, so what Notetaker produces can be read instead of guessed.
            let parakeet = ParakeetEngine()
            let meeting = MeetingTranscriber()
            await meeting.prepareDiarizer()
            FileHandle.standardError.write(Data("diarizer ready: \(meeting.isDiarizerReady)\n".utf8))
            let started = Date()
            let result = await meeting.transcribe(
                micURL: URL(fileURLWithPath: micPath), systemAudioURL: URL(fileURLWithPath: systemPath),
                knownSpeakers: [], attendeeHint: nil,
                transcribeFile: { url in
                    try await parakeet.transcribe(
                        fileAt: url, model: "v3", localeID: "en-US", biasTerms: [], boostVocabulary: false).text
                })
            for segment in result.segments {
                print(String(format: "%5.1f–%5.1f  [%d %@]  %@", segment.startTime, segment.endTime,
                             segment.speakerIndex, segment.speakerName ?? "-", segment.text))
            }
            let note = MeetingNote(title: "check", date: Date(), duration: 0, segments: result.segments)
            print("segments: \(result.segments.count), transcript chars: \(note.transcriptText.count), "
                  + "summariser reads the first \(min(6000, note.transcriptText.count))")
            print(String(format: "pipeline time: %.1fs", Date().timeIntervalSince(started)))
        case .hudCheck(let directory):
            // The notch pill on the real notch, fully transparent and click-through, for about a second: what the
            // window server does with it, and a picture of what it draws. Nothing shows on screen.
            FontLoader.registerManrope()
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let ok = await NotchHUDCheck.run(outputDirectory: directory)
            exit(ok ? 0 : 1)

        case .secureInput:
            // One-shot read of macOS secure event input: is it on, and which process holds it.
            let monitor = SecureInputMonitor.shared
            monitor.refresh()
            let status = monitor.status
            print("secure input: \(status.isOn ? "ON" : "off")")
            if status.isOn {
                print("holder: \(status.holderName ?? "unknown") (pid \(status.holderPID.map(String.init) ?? "?"))"
                      + (status.holderIsFrontmost ? ", frontmost" : ", not frontmost"))
            }
            exit(0)

        case .guardCheck:
            // JSON lines in ({"original", "edited", optional "vocab": [words]}),
            // one verdict per line out, using the real dictionary — the
            // hook for cross-checking this Swift port against the Python
            // prototype the guard was validated with, pair by pair.
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let original = object["original"] as? String,
                      let edited = object["edited"] as? String else { continue }
                let vocabulary = Set((object["vocab"] as? [String]) ?? [])
                let verdict = LLMEditGuard.apply(
                    original: original, edited: edited, vocabulary: vocabulary)
                let result: [String: Any] = [
                    "text": verdict.text, "reverted": verdict.revertedEdits,
                    "discarded": verdict.discarded]
                if let out = try? JSONSerialization.data(
                    withJSONObject: result, options: [.withoutEscapingSlashes]),
                   let string = String(data: out, encoding: .utf8) {
                    print(string)
                }
            }
            exit(0)

        case .format(let text):
            // Same pipeline as live dictation: format, apply learned
            // corrections, then expand snippets. --bundle-id resolves
            // developer-vocabulary the same way a real dictation into that
            // app would (default: off, matching a `nil` bundle ID/no
            // resolvable frontmost app).
            let developerVocabulary = AppProfileStore.developerVocabularyEnabled(
                forBundleID: bundleID)
            // --locale another language: the formatter with that language's filler sounds, and none of the English-only
            // stages — as the app does it.
            if String(localeIdentifier.prefix { $0 != "-" }).lowercased() != "en" {
                print(SnippetStore.expand(in: TextFormatter(
                    dictionary: [:], speaksEnglish: false,
                    extraFillers: CleanupLanguage.rules(forLocale: localeIdentifier)?.fillers ?? []).format(text),
                    recordUse: false))
                exit(0)
            }
            print(SnippetStore.expand(
                in: SelfCorrectionResolver.resolve(TimeNormalizer.normalize(LearnedStore.apply(
                    in: TextFormatter().format(text),
                    includeDeveloperVocabulary: developerVocabulary))).text, recordUse: false))
            exit(0)

        case .harperFix(let text):
            let developerVocabulary = AppProfileStore.developerVocabularyEnabled(
                forBundleID: bundleID)
            var fixed = HarperChecker.fix(
                text,
                vocabulary: LearnedStore.biasTerms(
                    includeDeveloperVocabulary: developerVocabulary))
            // The layout step, then the live pipeline's last stage ("Auto (match app)"), so this reproduces what the
            // app inserts.
            let layoutDestination = DestinationDetector.destination(bundleID: bundleID, pageURL: nil)
            if DictationLayout.applies(to: layoutDestination) {
                fixed = DictationLayout.shape(fixed, bullet: SpokenCommand.bullet(forBundleID: bundleID))
                if layoutDestination != .messaging { fixed = await DictationLayout.paragraphed(fixed) }
            }
            if let destination = AppProfileStore.autoDestination(forBundleID: bundleID) {
                fixed = DestinationShaper.shape(fixed, for: destination)
            }
            print(fixed)
            exit(0)

        case .transform(let text):
            let engine = RewriteEngine()
            if let note = engine.availabilityNote {
                FileHandle.standardError.write(Data("Unavailable: \(note)\n".utf8))
                exit(1)
            }
            // MURMUR_TRANSFORM_INSTRUCTIONS="…" (debug): run a custom transform with these instructions, as one the
            // user made on the Transforms page.
            let customInstructions = ProcessInfo.processInfo.environment["MURMUR_TRANSFORM_INSTRUCTIONS"]
            let transform = customInstructions.map {
                Transform(id: "custom-cli", name: "Custom", keyLabel: "—", keyCode: .max, description: $0,
                          instructions: $0, kind: .custom, isCustom: true)
            } ?? transformID.flatMap { id in
                Transform.all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
            } ?? Transform.all[0]
            do {
                // The app's own path (`TransformManager.attempt`): the model, then the safety check. A refused
                // rewrite leaves the text as it was, as in the app; the refused output goes to stderr for debugging.
                // --bundle-id says where the text is going, as the app would know from the window in front.
                let destination = DestinationDetector.destination(bundleID: bundleID, pageURL: nil)
                let (output, rejection) = try await TransformManager.attempt(
                    transform, on: text, engine: engine, destination: destination)
                if let rejection {
                    FileHandle.standardError.write(Data("REFUSED (\(rejection.rawValue)):\n\(output)\n".utf8))
                    print(text)
                } else {
                    print(output)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
                exit(1)
            }

        case .translate(let text):
            // The translation step exactly as a dictation runs it: the translator Murmur would pick for this pair (or
            // --via one), then the check. A file of lines (one per dictation) when the text is a path.
            let lines = FileManager.default.fileExists(atPath: text)
                ? ((try? String(contentsOfFile: text, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                : [text]
            let models = TranslationModels.shared
            await models.refreshApple(from: translateFrom, to: translateTo)
            let engine = translateVia ?? models.engine(from: translateFrom, to: translateTo)
            print("\(translateFrom) → \(translateTo) via \(engine?.rawValue ?? "nothing (no translator for this pair)")")
            if engine == .gemma { await Translator.shared.prewarm(.gemma) }
            if engine == .euroLLM { await Translator.shared.prewarm(.euroLLM) }
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let started = Date()
                let outcome = await Translator.shared.translate(line, from: translateFrom, to: translateTo, engine: engine)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                switch outcome {
                case .translated(let output, _): print("[\(ms) ms] \(output)")
                case .kept(let problem): print("[\(ms) ms] KEPT (\(problem.sentence)): \(line)")
                }
            }
            exit(0)

        case .translateDownload(let model):
            // The same download Settings starts, with its progress.
            print("downloading \(model.name) (\(model.sizeLabel)) to \(model.directory.path)")
            final class Printed: @unchecked Sendable { var bytes: Int64 = 0 }
            let printed = Printed()
            do {
                try await model.download { received in
                    if received - printed.bytes > 250_000_000 || received == model.totalBytes {
                        printed.bytes = received
                        print(String(format: "  %.2f of %.2f GB", Double(received) / 1e9, Double(model.totalBytes) / 1e9))
                    }
                }
                print("ready: \(model.isDownloaded)")
                exit(0)
            } catch {
                print("failed: \(error.localizedDescription)")
                exit(1)
            }

        case .code(let said):
            // Text as a dictation into a coding field would write it, without the recognizer or the clean-up model:
            // --field shell|editor → the exact words with spoken code and project names; --field prompt → formatted,
            // with project names (the clean-up then runs on that, as `--edit` shows).
            guard let context = codeContext() else { print("--code needs --field shell|editor|prompt"); exit(1) }
            if context.kind == .prompt {
                let formatted = SelfCorrectionResolver.resolve(TimeNormalizer.normalize(LearnedStore.apply(
                    in: TextFormatter().format(said), includeDeveloperVocabulary: true))).text
                print(CodeField.promptText(formatted, context: context).text)
            } else {
                print(CodeField.exactText(LearnedStore.apply(in: said.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             includeDeveloperVocabulary: true), context: context))
            }
            exit(0)

        case .canaryBatch(let listPath):
            // Translation research (2026-10-02): NVIDIA Canary-1B-v2 (FluidAudio's CoreML version) writing speech in one
            // language as text in another, for each line "audio<TAB>source<TAB>target" of the list. The task is chosen
            // by the prompt's source and target language tokens, read from the model's own vocabulary.
            do {
                // MURMUR_CANARY_PRECISION=int8 (CPU) or fp16 skips the Neural Engine int4 build, which took over 25
                // minutes on first use (2026-10-02).
                let precision = ProcessInfo.processInfo.environment["MURMUR_CANARY_PRECISION"]
                    .flatMap(CanaryPrecision.init(rawValue:)) ?? .int4
                let directory = try await CanaryModels.download(precision: precision)
                let models = try CanaryModels.load(from: directory, precision: precision)
                let vocabData = try Data(contentsOf: directory.appendingPathComponent(ModelNames.Canary.vocabularyFile))
                var idOf: [String: Int32] = [:]
                if let vocab = try JSONSerialization.jsonObject(with: vocabData) as? [String: Any] {
                    for (key, value) in vocab {
                        if let id = Int32(key), let piece = value as? String { idOf[piece] = id }
                        else if let id = value as? Int { idOf[key] = Int32(id) }
                    }
                }
                for line in try String(contentsOfFile: listPath, encoding: .utf8).split(separator: "\n") {
                    let fields = line.split(separator: "\t").map(String.init)
                    guard fields.count == 3 else { continue }
                    guard let source = idOf["<|\(fields[1])|>"], let target = idOf["<|\(fields[2])|>"] else {
                        print("{\"path\":\"\(fields[0])\",\"out\":\"ERROR: no language token\"}")
                        continue
                    }
                    var prompt = CanaryConfig.promptEnTranscribePnc
                    prompt[4] = source
                    prompt[5] = target
                    let manager = CanaryManager(models: models, prompt: prompt)
                    let started = Date()
                    let text = (try? await manager.transcribe(audioURL: URL(fileURLWithPath: fields[0]))) ?? "ERROR"
                    let row: [String: Any] = ["path": fields[0], "src": fields[1], "tgt": fields[2], "out": text,
                                              "ms": Int(Date().timeIntervalSince(started) * 1000)]
                    print(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
                }
            } catch {
                print("FAILED: \(error)")
            }
            exit(0)

        case .fieldProbe:
            // What the app in front is, as dictation would read it at key-down: its coding field and project. Prints
            // no text from the window. Read-only: no focus change, no keys, no clipboard. Run through the signed app.
            let front = probeBundleID.flatMap { id in
                NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
            } ?? NSWorkspace.shared.frontmostApplication
            print("app: \(front?.bundleIdentifier ?? "-")")
            let started = Date()
            if let context = CodeField.detect(bundleID: front?.bundleIdentifier, pid: front?.processIdentifier) {
                print("field: \(context.kind.rawValue) (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
                print("project: \(context.projectRoot?.path ?? "none found")")
                print("names: \(context.names.count) — e.g. \(context.names.prefix(8).map(\.stem).joined(separator: ", "))")
            } else {
                print("not a coding field (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
            }
            exit(0)

        case .whisperPrompt:
            // The sentence whisper.cpp is told before it listens, as built from the words on this Mac right now —
            // in an ordinary app and in a coding one.
            for developer in [false, true] {
                let terms = LearnedStore.biasTerms(includeDeveloperVocabulary: developer)
                let prompt = WhisperPrompt.text(for: terms, personal: LearnedStore.personalTermKeys()) ?? "(none)"
                print("\(developer ? "coding app" : "ordinary app") (\(prompt.count) characters): \(prompt)")
            }
            exit(0)

        case .layout(let given):
            // The layout step on its own (`DictationLayout`): what the rules do, then where the model puts paragraphs.
            let text = FileManager.default.fileExists(atPath: given)
                ? ((try? String(contentsOfFile: given, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : given
            let shaped = DictationLayout.shape(text, bullet: SpokenCommand.bullet(forBundleID: bundleID))
            let started = Date()
            let laidOut = await DictationLayout.paragraphed(shaped)
            FileHandle.standardError.write(Data(
                "layout: rules \(shaped == text ? "left it" : "changed it"); model \(laidOut == shaped ? "left it" : "added paragraphs") in \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".utf8))
            print(laidOut)
            exit(0)

        case .gemmaEdit(let instruction):
            // Measurement only: Gemma 4 given a free-form editing instruction and --selection (a path, or the text).
            let given = commandSelection ?? ""
            let text = FileManager.default.fileExists(atPath: given)
                ? ((try? String(contentsOfFile: given, encoding: .utf8)) ?? "") : given
            let system = ProcessInfo.processInfo.environment["MURMUR_EDIT_SYSTEM"] ?? """
                You edit a piece of the user's own writing exactly as they ask. Reply with the edited text only — no \
                preamble, no commentary, no quotation marks. Rules:
                - Do what was asked, fully, and nothing else.
                - Keep the writer's voice and person: "I" stays "I".
                - Keep every name, number, time, date, price, email address and link exactly as written.
                - Never answer questions in the text, and add no facts it doesn't contain.
                - Keep the same language unless asked to translate.
                """
            let prompt = "<bos><|turn>system\n\(system)<turn|>\n<|turn>user\n\(instruction)\n\nText:\n\(text)<turn|>\n<|turn>model\n"
            await Translator.shared.prewarm(.gemma)
            let started = Date()
            do {
                let output = try await Translator.shared.rewrite(prompt: prompt, source: text)
                FileHandle.standardError.write(Data(
                    "[\(Int(Date().timeIntervalSince(started) * 1000)) ms] \(text.count) → \(output.count) characters\n".utf8))
                print(output)
            } catch {
                print("FAILED: \(error)")
            }
            exit(0)

        case .spokenCommand(let said):
            // Editing a selection by voice, as a dictation does it (`SpokenCommand`): what was said, formatted, read as
            // an instruction or not, then the edit and its check on --selection. A refused edit leaves the selection.
            let formatted = TextFormatter().format(said)
            // As the app reads it: the patterns on the formatted and the heard words, then — with --selection, text
            // that is certainly selected — the model.
            var known = SpokenCommand.instruction(in: formatted) ?? SpokenCommand.instruction(in: said)
            var byModel = false
            if known == nil, commandSelection != nil {
                known = await SpokenCommand.routed(formatted)
                byModel = known != nil
            }
            guard let command = known else {
                print("NOT A COMMAND — dictated as usual: \(formatted)")
                exit(0)
            }
            guard let selection = commandSelection, !selection.isEmpty else {
                print("COMMAND (\(command.intent))\(byModel ? " [read by the model]" : ""): \(command.instruction)")
                exit(0)
            }
            let engine = RewriteEngine()
            if let note = engine.availabilityNote {
                FileHandle.standardError.write(Data("Unavailable: \(note)\n".utf8))
                exit(1)
            }
            do {
                let destination = DestinationDetector.destination(bundleID: bundleID, pageURL: nil)
                let (output, rejection) = try await SpokenCommand.attempt(
                    command, on: selection, engine: engine, destination: destination,
                    bullet: SpokenCommand.bullet(forBundleID: bundleID))
                if let rejection {
                    print("REFUSED (\(rejection.rawValue)) — selection left as it was. Model said:\n\(output)")
                } else {
                    print(output)
                }
            } catch {
                print("FAILED: \(error)")
            }
            exit(0)

        case .edit(let text):
            // Runs the exact same pipeline stopAndTranscribe() does for a
            // dictation into --bundle-id (default: no app, so the global
            // default style/no per-app override) — real persisted Voice
            // Profile included — rather than a synthetic instruction
            // string, so this reproduces field reports faithfully instead
            // of a simplified stand-in. --template opts into a specific
            // built-in/custom template instead of the no-template default,
            // to verify a template's own instructions (and worked example,
            // once one exists) rather than just the baseline cleanup pass.
            //
            // Style resolves through AppProfileStore exactly like the real
            // pipeline (a bundle ID's own override, else Raw for a
            // recognized terminal, else the global default) rather than
            // hardcoding StyleSettings.defaultStyle — the gap between
            // those two used to mean this command couldn't reproduce a
            // Raw-style app at all, only ever exercising the non-Raw path.
            let style = AppProfileStore.style(forBundleID: bundleID)
            // Snippets are held aside the way a dictation holds them (see `SnippetStore`): the model only sees the
            // user's own words and a marker, and the saved text goes back in at the end. A result that lost a marker
            // isn't used, as in the app.
            let held = SnippetStore.hold(in: text, recordUse: false)
            let input = held.text
            func emit(_ result: String) {
                if !held.isEmpty, !held.keepsAll(result) {
                    FileHandle.standardError.write(Data("SNIPPET MARKER LOST — kept as spoken: \(result)\n".utf8))
                }
                print(held.restore(held.keepsAll(result) ? result : input).text)
            }
            guard !style.skipsAllProcessing, !held.isWholeDictation else {
                emit(input)
                exit(0)
            }
            let engine = RewriteEngine()
            if let note = engine.availabilityNote {
                FileHandle.standardError.write(Data("Unavailable: \(note)\n".utf8))
                exit(1)
            }
            let voice = Settings.useVoiceProfile ? VoiceProfileStore.load() : nil
            var template = templateName.flatMap { name in
                NoteTemplateStore.all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }
            // MURMUR_TEMPLATE_DESCRIPTION="…" (debug): a template of the user's own made from this description, its
            // parts worked out the way the New template sheet does it.
            if let description = ProcessInfo.processInfo.environment["MURMUR_TEMPLATE_DESCRIPTION"] {
                let parts = await TemplateEngine.planSections(for: description)
                FileHandle.standardError.write(Data("PARTS: \(parts.map(\.heading))\n".utf8))
                template = NoteTemplate(name: "Custom", icon: "doc.text", instructions: description,
                                        sections: parts.isEmpty ? nil : parts)
            }
            // --locale de-DE (or another `CleanupLanguage`): the plain clean-up in that language, as the app runs it.
            // Said at the start ("Meeting notes. We went over…"): the phrase picks the template for this one
            // dictation and comes off the front, as in the app.
            var templateBody = input
            if template == nil, Settings.voiceTemplatesEnabled, let match = NoteTemplateStore.matchVoiceTrigger(in: input) {
                template = match.template
                templateBody = match.remainder
                FileHandle.standardError.write(Data("template by voice: \(match.template.name)\n".utf8))
            }
            let cleanupLanguage = CleanupLanguage.rules(forLocale: localeIdentifier)
            if cleanupLanguage != nil { template = nil }
            guard let instructions = RewritePlan.instructions(
                template: template, style: style,
                cleanupLevel: StyleSettings.defaultCleanupLevel, voice: voice, language: cleanupLanguage)
            else {
                emit(input)
                exit(0)
            }
            // A template runs the app's own path (`TemplateEngine`); a refusal pastes the words as spoken, as the app.
            if let template {
                do {
                    // --locale lv-LV runs it as for a Latvian dictation.
                    let language = TemplateLanguage.from(localeIdentifier: localeIdentifier) ?? .english
                    emit(try await TemplateEngine.apply(
                        template, to: templateBody,
                        extraInstructions: language == .english ? RewritePlan.templateExtras(
                            style: style, cleanupLevel: StyleSettings.defaultCleanupLevel, voice: voice) : nil,
                        language: language, marks: TemplateMarks.for(bundleID: bundleID)))
                } catch {
                    FileHandle.standardError.write(Data("TEMPLATE NOT APPLIED: \(error.localizedDescription)\n".utf8))
                    emit(input)
                }
                exit(0)
            }
            // A tone on its own has its own instructions (`restyle`); print the ones that will be used.
            let shown = template == nil && style.instructions != nil
                ? RewriteEngine.toneInstructions(for: style, cleanupLevel: StyleSettings.defaultCleanupLevel, voice: voice)
                : instructions
            FileHandle.standardError.write(
                Data("--- instructions ---\n\(shown)\n--- end instructions ---\n".utf8))
            // The plain cleanup runs the exact shared pass a live dictation
            // does — skip-if-nothing-to-clean, capped deterministic decode,
            // word-preservation guard — so this reproduces what the app
            // actually outputs. --no-guard prints the model's own answer to
            // the same prompt instead, for seeing what the guard is guarding.
            if !noGuard, RewritePlan.isPlainCleanup(
                template: template, style: style,
                cleanupLevel: StyleSettings.defaultCleanupLevel) {
                let developerVocabulary = AppProfileStore.developerVocabularyEnabled(
                    forBundleID: bundleID)
                if usePrewarm {
                    // The app's flow: the fixed prompt is processed while recognition runs (stood in for by a wait).
                    engine.prewarmCleanup(instructions: instructions)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                let outcome = await engine.cleanup(
                    input, instructions: instructions,
                    vocabularyTerms: LearnedStore.biasTerms(
                        includeDeveloperVocabulary: developerVocabulary) + held.markers,
                    language: cleanupLanguage)
                var report = "cleanup: ranModel=\(outcome.ranModel) modelFailed=\(outcome.modelFailed) revertedEdits=\(outcome.revertedEdits) discarded=\(outcome.discarded) elapsedMs=\(Int(outcome.elapsed * 1000))\n"
                for note in outcome.notes { report += "  reverted: \(note)\n" }
                FileHandle.standardError.write(Data(report.utf8))
                emit(outcome.text)
                exit(0)
            }
            do {
                // A tone on its own runs the app's own step (`toned`): the lead-in rule, the model, the check, and the
                // text as it was when the rewrite is refused. --no-guard prints the model's own answer.
                if template == nil, style.instructions != nil {
                    let result = await engine.toned(input, as: style, cleanupLevel: StyleSettings.defaultCleanupLevel, voice: voice)
                    if let attempt = result.attempt {
                        FileHandle.standardError.write(Data(String(
                            format: "tone: kept %.2f of the dictation's words, %.2f of the rewrite's are the dictation's\n",
                            TransformGuard.coverage(of: input, in: attempt), TransformGuard.coverage(of: attempt, in: input)).utf8))
                    } else {
                        FileHandle.standardError.write(Data("tone: the model gave no rewrite\n".utf8))
                    }
                    if let refusal = result.refusal {
                        FileHandle.standardError.write(Data(
                            "style rewrite refused (\(refusal.rawValue)): \(result.attempt ?? "")\n".utf8))
                    }
                    emit(noGuard ? (result.attempt ?? result.text) : result.text)
                    exit(0)
                }
                let result = try await engine.edit(input, instructions: instructions)
                // A Style or Concise rewrite is held to what a live dictation holds it to (see
                // `StyleRewriteGuard`); a refused one leaves the text as it was, exactly like the app.
                if result.isEmpty {
                    emit(input)
                } else if !noGuard,
                   let rejection = StyleRewriteGuard.rejection(original: input, rewritten: result, isTemplate: template != nil) {
                    FileHandle.standardError.write(Data(
                        "style rewrite refused (\(rejection.rawValue)): \(result)\n".utf8))
                    emit(input)
                } else {
                    emit(result)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
                exit(1)
            }

        case .ask(let question):
            let engine = RewriteEngine()
            if let note = engine.availabilityNote {
                FileHandle.standardError.write(Data("Unavailable: \(note)\n".utf8))
                exit(1)
            }
            let history = HistoryStore()
            do {
                let answer = try await AskMurmur.ask(
                    question, history: history.entries, meetings: MeetingNoteStore().notes, engine: engine)
                print(answer.text)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
                exit(1)
            }

        case .history:
            printHistory(HistoryStore().entries)
            exit(0)

        case .historySearch(let query):
            printHistory(HistoryStore.matching(query, in: HistoryStore().entries))
            exit(0)

        case .historyExport(let path):
            do {
                let data = try JSONEncoder().encode(HistoryStore().entries)
                try data.write(to: URL(fileURLWithPath: path))
                print("Exported \(HistoryStore().entries.count) entries to \(path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Export failed: \(error)\n".utf8))
                exit(1)
            }

        case .transcribe(let listOrPath):
            // Debug: names as if they were on screen for every file (one per line) — the same path key-down fills.
            if let path = ProcessInfo.processInfo.environment["MURMUR_SCREEN_NAMES_FILE"],
               let list = try? String(contentsOfFile: path, encoding: .utf8) {
                ScreenContext.set(list.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
            }
            // --transcribe-list: the same pipeline over many files (one path per line) in ONE process, with the
            // engines kept loaded between files — for scoring a test set, and for warm, live-app timings instead
            // of the cold command line's model loading.
            let paths = transcribeList
                ? ((try? String(contentsOfFile: listOrPath, encoding: .utf8)) ?? "")
                    .split(separator: "\n").map(String.init)
                : [listOrPath]
            var warmWhisper: WhisperEngine?
            var warmWhisperCpp: WhisperCppEngine?
            var warmParakeet: ParakeetEngine?
            var warmSherpa: SherpaOnnxEngine?
            for path in paths {
                if transcribeList { print("FILE: \(path)") }
                do {
                    // --bundle-id resolves developer-vocabulary the same way a
                    // real dictation into that app would (default: off,
                    // matching a `nil` bundle ID/no resolvable frontmost app) —
                    // pass e.g. `--bundle-id com.apple.dt.Xcode` to reproduce
                    // what actually happens dictating into a recognized
                    // developer-context app instead of the CLI's own default.
                    let developerVocabulary = AppProfileStore.developerVocabularyEnabled(
                        forBundleID: bundleID)
                    let raw: String
                    // nil for Apple and sherpa-onnx, which don't expose one —
                    // see `TranscriptionPlausibility.isPlausible`'s `confidence`
                    // parameter.
                    var confidence: Float?
                    // The same trailing-silence trim a real dictation gets for
                    // Whisper-family engines (`AppDelegate.recognize`), so this
                    // reproduces what the app does instead of what the bare
                    // recognizer does. --no-trim shows the latter.
                    var audioURL = URL(fileURLWithPath: path)
                    var trimmedCopy: URL?
                    var stageClock = Date()
                    var stageTimes: [String] = []
                    func lap(_ stage: String) {
                        stageTimes.append("\(stage)=\(Int(Date().timeIntervalSince(stageClock) * 1000))")
                        stageClock = Date()
                    }
                    if !noTrim, engineName == "whisper" || engineName == "whispercpp",
                       let speechEnd = await VadEngine().analyze(fileAt: audioURL)?.lastSpeechEnd,
                       let trimmed = TrailingSilenceTrimmer.trimmedCopy(of: audioURL, speechEnd: speechEnd) {
                        FileHandle.standardError.write(Data(
                            "Trimmed trailing silence after \(String(format: "%.1f", speechEnd))s\n".utf8))
                        audioURL = trimmed
                        trimmedCopy = trimmed
                    }
                    lap("vad+trim")
                    if engineName == "whisper" {
                        let whisper = warmWhisper ?? WhisperEngine()
                        warmWhisper = whisper
                        whisper.onStatus = { status in
                            if let status {
                                FileHandle.standardError.write(Data("\(status)\n".utf8))
                            }
                        }
                        (raw, confidence) = try await whisper.transcribe(
                            fileAt: audioURL,
                            model: whisperModel,
                            localeID: localeIdentifier,
                            biasTerms: LearnedStore.biasTerms(
                                includeDeveloperVocabulary: developerVocabulary))
                    } else if engineName == "whispercpp" {
                        let whisperCpp = warmWhisperCpp ?? WhisperCppEngine()
                        warmWhisperCpp = whisperCpp
                        whisperCpp.onStatus = { status in
                            if let status {
                                FileHandle.standardError.write(Data("\(status)\n".utf8))
                            }
                        }
                        let terms = LearnedStore.biasTerms(includeDeveloperVocabulary: developerVocabulary)
                        // --chunked: the live "transcribe while you talk" path — the recording is fed to the same
                        // `LiveChunkSession` a live dictation uses, as if spoken; what is timed is only what's left
                        // after the key is released.
                        if chunked, let vad = try? await VadManager() {
                            let session = LiveChunkSession(
                                engine: whisperCpp, vad: { vad }, model: whisperModel, localeID: localeIdentifier,
                                biasTerms: terms)
                            // Untrimmed, like the live microphone; the tail below uses the trimmed file, like the app.
                            try await session.simulate(recording: URL(fileURLWithPath: path))
                            await session.waitForStretches()
                            let released = Date()
                            if let result = await session.finish(recording: audioURL) {
                                (raw, confidence) = (result.text, result.confidence)
                                print("CHUNKS: \(result.stretches) release_ms=\(Int(Date().timeIntervalSince(released) * 1000))")
                            } else {
                                (raw, confidence) = try await whisperCpp.transcribe(
                                    fileAt: audioURL, model: whisperModel, localeID: localeIdentifier, biasTerms: terms)
                                print("CHUNKS: 1 release_ms=\(Int(Date().timeIntervalSince(released) * 1000))")
                            }
                        } else {
                            // --field shell: commands as whisper's example, as the app gives a shell.
                            (raw, confidence) = try await whisperCpp.transcribe(
                                fileAt: audioURL, model: whisperModel, localeID: localeIdentifier, biasTerms: terms,
                                prompt: codeFieldKind == .shell ? WhisperPrompt.shell : nil)
                            if codeFieldKind == .shell, WhisperPrompt.echoesShell(raw) { print("WARNING: prompt echo — the app discards this") }
                        }
                    } else if engineName == "parakeet" {
                        let parakeet = warmParakeet ?? ParakeetEngine()
                        warmParakeet = parakeet
                        parakeet.onStatus = { status in
                            if let status {
                                FileHandle.standardError.write(Data("\(status)\n".utf8))
                            }
                        }
                        (raw, confidence) = try await parakeet.transcribe(
                            fileAt: URL(fileURLWithPath: path),
                            model: whisperModel,
                            localeID: localeIdentifier,
                            biasTerms: LearnedStore.biasTerms(
                                includeDeveloperVocabulary: developerVocabulary),
                            boostVocabulary: developerVocabulary
                                // Debug only: boost the user's own words outside developer apps too, to measure it.
                                || ProcessInfo.processInfo.environment["MURMUR_PARAKEET_BOOST_ALL"] != nil)
                    } else if engineName == "sherpa" {
                        let sherpa = warmSherpa ?? SherpaOnnxEngine()
                        warmSherpa = sherpa
                        sherpa.onStatus = { status in
                            if let status {
                                FileHandle.standardError.write(Data("\(status)\n".utf8))
                            }
                        }
                        // Constructed fresh here (not `AppDelegate.vadEngine`,
                        // which this CLI path never runs through) so
                        // `--sherpa-model funasr-nano` exercises the exact same
                        // speech-chunking path a real dictation does, rather
                        // than silently skipping it and only ever testing the
                        // plain single-shot decode.
                        let vad = try? await VadManager()
                        raw = try await sherpa.transcribe(
                            fileAt: URL(fileURLWithPath: path),
                            model: sherpaModel,
                            localeID: localeIdentifier,
                            biasTerms: LearnedStore.biasTerms(
                                includeDeveloperVocabulary: developerVocabulary),
                            vadManager: vad)
                    } else {
                        let transcriber = Transcriber(
                            locale: Locale(identifier: localeIdentifier))
                        raw = try await transcriber.transcribe(
                            fileAt: URL(fileURLWithPath: path),
                            biasTerms: LearnedStore.biasTerms(
                                includeDeveloperVocabulary: developerVocabulary))
                    }
                    if let trimmedCopy { try? FileManager.default.removeItem(at: trimmedCopy) }
                    lap("asr")
                    // Full live-dictation pipeline: format → learned corrections
                    // → snippet expansion → Harper — everything the real style
                    // resolved for --bundle-id runs except the Apple
                    // Intelligence rewrite pass, left out here since it's
                    // non-deterministic and needs on-device model availability
                    // this debug path shouldn't depend on. Personal corrections
                    // and Harper are gated to English, matching AppDelegate's
                    // `isEnglishDictation` — both assume English input and
                    // corrupt other languages' real words otherwise.
                    //
                    // Branches on `AppProfileStore.style(forBundleID:)` the
                    // same way AppDelegate does — this used to run one fixed
                    // sequence regardless of --bundle-id, so it could not
                    // exercise Raw mode's "skip formatting/Harper entirely"
                    // path at all. Found by testing the terminal-defaults-to-
                    // Raw change immediately after building it: every
                    // --bundle-id gave the same output, silently, because
                    // this pipeline never branched on the value it resolved.
                    let isEnglishDictation =
                        String(localeIdentifier.prefix(while: { $0 != "-" }))
                        .lowercased() == "en"
                    // --field / --project: as a dictation into that coding field (`CodeField`), the way the app decides it.
                    let codeField = codeContext()
                    var style = AppProfileStore.style(forBundleID: bundleID)
                    if let codeField { style = codeField.kind == .prompt ? .none : .raw }
                    var formatted: String
                    if style.skipsAllProcessing {
                        formatted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if isEnglishDictation {
                            formatted = LearnedStore.apply(
                                in: formatted, includeDeveloperVocabulary: developerVocabulary)
                            if let codeField, codeField.kind != .prompt {
                                formatted = CodeField.exactText(formatted, context: codeField)
                            }
                        }
                        formatted = SnippetStore.expand(in: formatted, recordUse: false)
                    } else {
                        formatted = TextFormatter(
                            dictionary: isEnglishDictation ? TextFormatter.loadDictionary() : [:],
                            speaksEnglish: isEnglishDictation,
                            extraFillers: CleanupLanguage.rules(forLocale: localeIdentifier)?.fillers ?? []
                        ).format(raw)
                        lap("textformat")
                        if isEnglishDictation {
                            formatted = LearnedStore.apply(
                                in: formatted, includeDeveloperVocabulary: developerVocabulary)
                            lap("learned")
                            formatted = SelfCorrectionResolver.resolve(TimeNormalizer.normalize(formatted)).text
                            lap("resolver")
                        }
                        if let codeField, codeField.kind == .prompt {
                            formatted = CodeField.promptText(formatted, context: codeField).text
                        }
                        // Held aside through Harper and the per-app shaping, then put back — as in a dictation.
                        let held = SnippetStore.hold(in: formatted, recordUse: false)
                        formatted = held.text
                        lap("snippets")
                        if isEnglishDictation, !held.isWholeDictation {
                            let fixed = HarperChecker.fix(
                                formatted,
                                vocabulary: LearnedStore.biasTerms(
                                    includeDeveloperVocabulary: developerVocabulary) + held.markers)
                            if held.keepsAll(fixed) { formatted = fixed }
                            // The layout step, as in the app (`DictationLayout`).
                            let layoutDestination = DestinationDetector.destination(bundleID: bundleID, pageURL: nil)
                            if DictationLayout.applies(to: layoutDestination) {
                                var laidOut = DictationLayout.shape(formatted, bullet: SpokenCommand.bullet(forBundleID: bundleID))
                                if layoutDestination != .messaging { laidOut = await DictationLayout.paragraphed(laidOut) }
                                if held.keepsAll(laidOut) { formatted = laidOut }
                            }
                            if let destination = AppProfileStore.autoDestination(forBundleID: bundleID) {
                                formatted = DestinationShaper.shape(formatted, for: destination)
                            }
                        }
                        formatted = held.restore(formatted).text
                    }
                    lap("harper")
                    FileHandle.standardError.write(Data("TIMING ms \(stageTimes.joined(separator: " "))\n".utf8))
                    if transcribeList { print("TIMING: \(stageTimes.joined(separator: " "))") }
                    print("RAW: \(raw)")
                    if let confidence {
                        let duration = TranscriptionPlausibility.audioDurationSeconds(
                            of: URL(fileURLWithPath: path)) ?? 0
                        let plausible = TranscriptionPlausibility.isPlausible(
                            raw, audioDurationSeconds: duration, confidence: confidence)
                        print("CONFIDENCE: \(confidence) (plausible: \(plausible))")
                    }
                    print("style: \(style.rawValue)")
                    print("FORMATTED: \(formatted)")
                    if !transcribeList { exit(0) }
                } catch {
                    FileHandle.standardError.write(
                        Data("Transcription failed: \(error)\n".utf8))
                    if !transcribeList { exit(1) }
                    print("FAILED: \(error)")
                }
            }
            exit(0)

        case .micCheck:
            // The dictation recorder, headless: records about 1.2 s from the microphone Murmur would choose, stops
            // the way a key release does (waiting for the audio in flight), and prints what it saw. No window, no
            // keys, no clipboard.
            let recorder = AudioRecorder()
            let startCalled = Date()
            do { try recorder.start() } catch { print("start failed: \(error)"); exit(1) }
            print("start() took: \(Int(Date().timeIntervalSince(startCalled) * 1000)) ms")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let released = Date()
            let url: URL? = await withCheckedContinuation { continuation in
                recorder.stopAfterTail { continuation.resume(returning: $0) }
            }
            let rate = recorder.capturedFormat?.sampleRate ?? 0
            print("input: \(AudioRecorder.transportName(recorder.inputTransport))")
            print("frames: \(recorder.capturedFrames) at \(Int(rate)) Hz = \(rate > 0 ? String(format: "%.2f", Double(recorder.capturedFrames) / rate) : "-") s")
            print("exact zeros only: \(recorder.deliveredOnlyZeros)")
            print("first buffer: \(recorder.lastStartup.firstBuffer.map { "\($0) ms" } ?? "-") after start")
            print("tail wait after release: \(Int(Date().timeIntervalSince(released) * 1000)) ms")
            if let url { try? FileManager.default.removeItem(at: url) }
            exit(url == nil ? 1 : 0)

        case .axProbe:
            // Whether edit learning can read the text box of the apps dictated into most: for each app's focused
            // element, which ways of reading it work and how long it is. Prints no text. Read-only: no focus change,
            // no keys, no clipboard. Run through the signed app so it has Accessibility.
            print("accessibility trusted: \(AXIsProcessTrusted())")
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.3)
                if let url = app.bundleURL, FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
                    AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                }
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                    print("\(app.bundleIdentifier ?? "?"): no focused element"); continue
                }
                let field = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(field, 0.3)
                func attribute(_ name: String) -> CFTypeRef? {
                    var value: CFTypeRef?
                    return AXUIElementCopyAttributeValue(field, name as CFString, &value) == .success ? value : nil
                }
                let role = attribute(kAXRoleAttribute) as? String ?? "?"
                let count = (attribute(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
                var forRange = "-"
                if let count {
                    var range = CFRange(location: 0, length: count)
                    var text: CFTypeRef?
                    if let rangeValue = AXValueCreate(.cfRange, &range),
                       AXUIElementCopyParameterizedAttributeValue(
                        field, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &text) == .success {
                        forRange = "\(((text as? String) ?? "") .utf16.count)"
                    } else { forRange = "failed" }
                }
                let value = (attribute(kAXValueAttribute) as? String).map { "\($0.utf16.count)" } ?? "-"
                let hasSelection = attribute(kAXSelectedTextRangeAttribute) != nil
                print("\(app.bundleIdentifier ?? "?"): role=\(role) characters=\(count.map(String.init) ?? "-") "
                    + "stringForRange=\(forRange) value=\(value) selectedRange=\(hasSelection)")
            }
            exit(0)

        case .destProbe:
            // What each app's focused window says about where text would go: window title (Claude/Codex only), the
            // web address (site only, except Claude/Codex), selected tabs, focused element. Read-only; prints labels,
            // never field contents.
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let bundle = app.bundleIdentifier ?? "?"
                let own = ["com.anthropic.claudefordesktop", "com.openai.codex"].contains(bundle)
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(axApp, 0.3)
                if let url = app.bundleURL, FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
                    AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    Thread.sleep(forTimeInterval: 0.5)
                }
                func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                    var v: CFTypeRef?
                    return AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success ? v : nil
                }
                guard let window = value(axApp, kAXFocusedWindowAttribute) else { print("\(bundle): no window"); continue }
                let win = window as! AXUIElement
                let title = value(win, kAXTitleAttribute) as? String ?? ""
                var urls: [String] = [], selected: [String] = [], visited = 0
                var stack: [(AXUIElement, Int)] = [(win, 0)]
                while let (el, depth) = stack.popLast(), visited < 3000 {
                    visited += 1
                    let role = value(el, kAXRoleAttribute) as? String ?? ""
                    if role == "AXWebArea", let url = value(el, "AXURL") as? URL {
                        urls.append(own ? url.absoluteString : (url.host ?? "?"))
                    }
                    if ["AXRadioButton", "AXTab", "AXButton", "AXLink", "AXMenuItem"].contains(role),
                       (value(el, kAXSelectedAttribute) as? Bool == true || (role == "AXRadioButton" && (value(el, kAXValueAttribute) as? NSNumber)?.intValue == 1)) {
                        let label = (value(el, kAXTitleAttribute) as? String) ?? (value(el, kAXDescriptionAttribute) as? String) ?? ""
                        selected.append("\(role):\(label.prefix(40))")
                    }
                    var children = value(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
                    if children.isEmpty { children = value(el, "AXChildrenInNavigationOrder") as? [AXUIElement] ?? [] }
                    if depth < 60 { stack.append(contentsOf: children.reversed().map { ($0, depth + 1) }) }
                }
                let focused = value(axApp, kAXFocusedUIElementAttribute).map { f -> String in
                    let el = f as! AXUIElement
                    return "\(value(el, kAXRoleAttribute) as? String ?? "?")/\((value(el, kAXDescriptionAttribute) as? String ?? "").prefix(30))"
                } ?? "-"
                print("\(bundle): title=\(own ? title.debugDescription : "<\(title.count) chars>") urls=\(urls) selected=\(selected) focused=\(focused) visited=\(visited)")
            }
            exit(0)

        case .screenProbe:
            // What key-down would read from each app's focused window: how long it takes, how much, and how many
            // names it keeps (the names themselves only for the app named by MURMUR_SCREEN_PROBE_NAMES=<bundle id>).
            // Read-only.
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let start = Date()
                let read = ScreenContext.visibleTexts(pid: app.processIdentifier)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let names = ScreenContext.names(in: read.texts)
                print("\(app.bundleIdentifier ?? "?"): \(ms) ms, \(read.elements) elements\(read.finished ? "" : " (budget hit)"), "
                    + "\(read.texts.count) texts, \(names.count) names")
                if ProcessInfo.processInfo.environment["MURMUR_SCREEN_PROBE_NAMES"] == app.bundleIdentifier, !names.isEmpty {
                    print("  " + names.prefix(60).joined(separator: " | "))
                }
            }
            exit(0)

        case .renderSheets(let path):
            // The dictionary import sheet (with a pasted list) and the report sheet (opened from a dictation), drawn
            // into <path>-import.png and <path>-report.png in a never-shown window.
            NSApplication.shared.setActivationPolicy(.accessory)
            do {
                FontLoader.registerManrope()
                func draw<V: View>(_ view: V, size: CGSize, to out: String) async {
                    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                    host.frame = NSRect(origin: .zero, size: size)
                    host.appearance = NSAppearance(named: .aqua)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: .aqua)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    let until = Date().addingTimeInterval(0.6)
                    while Date() < until { try? await Task.sleep(for: .milliseconds(50)) }
                    window.displayIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                        print("wrote \(out)")
                    }
                }
                let h = SheetMetrics.height(fitting: 600)
                await draw(DictionaryImportSheet(existing: [:], onDone: { _ in },
                                                 previewText: "Planrify, Manrope, Ember\nsuper base → Supabase\nWispr Flow\nDeep Pine"),
                           size: CGSize(width: SheetMetrics.width, height: h), to: path + "-import.png")
                await draw(SupportReportSheet(onDone: {}, height: 560,
                                              dictation: SupportReport.DictationContext(
                                                pasted: "Yeah, the last fix is not working. So now I have dictated and fixed in Claude Code and Codex.",
                                                heard: nil)),
                           size: CGSize(width: SheetMetrics.width, height: 560), to: path + "-report.png")
                exit(0)
            }

        case .renderToast(let path):
            // The "Saved … Undo" card drawn into an image: <path>-saved.png, <path>-taken-back.png, <path>-several.png.
            NSApplication.shared.setActivationPolicy(.accessory)
            do {
                FontLoader.registerManrope()
                func draw(_ model: CorrectionToastModel, to out: String) {
                    let size = CorrectionToastController.size
                    let host = NSHostingView(rootView: CorrectionToastView(model: model, onUndo: {})
                        .frame(width: size.width, height: size.height + 40, alignment: .bottom)
                        .background(Palette.homeGradient))
                    host.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height + 40))
                    host.appearance = NSAppearance(named: .darkAqua)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                        print("wrote \(out)")
                    }
                }
                let model = CorrectionToastModel()
                model.title = "Saved “Manrope”"
                model.detail = "Instead of “Manrog”, from now on."
                model.visible = true
                model.progress = 0.62
                draw(model, to: path + "-saved.png")
                model.title = "Saved “Planrify” and 2 more"
                model.detail = "From now on, instead of what was heard."
                draw(model, to: path + "-several.png")
                model.undone = true
                draw(model, to: path + "-taken-back.png")
                exit(0)
            }

        case .learnCheck(let original, let edited):
            // What learning makes of one edit, step by step — nothing is saved.
            let raw = LearnedStore.extractCorrections(original: original, corrected: edited)
            print("differences found: \(raw.map { "\($0.heard) → \($0.intended)" })")
            for pair in raw {
                let worth = WhisperPrompt.isWorthMentioning(pair.intended, isKnownWord: HarperChecker.isKnownEnglishWord)
                let known = HarperChecker.isKnownEnglishWord(pair.intended.lowercased().filter(\.isLetter))
                let rewording = LearnedStore.isRewording(heard: pair.heard, intended: pair.intended)
                print("  \(pair.heard) → \(pair.intended): name or unusual word \(worth), whole thing a known word \(known), "
                      + "everyday-for-everyday \(rewording)")
            }
            print("kept by edit learning: \(EditLearner.pairs(original: original, edited: edited).map { "\($0.heard) → \($0.intended)" })")
            print("new words it would learn: \(LearnedStore.newUnusualWords(original: original, corrected: edited, known: LearnedStore.biasTerms(includeDeveloperVocabulary: false)))")
            exit(0)

        case .duckCheck:
            // What lowering other sound would do on this Mac now, then a real 2-second duck and restore.
            print(AudioDuck.describe())
            AudioDuck.shared.begin()
            try? await Task.sleep(nanoseconds: 300_000_000)
            print("during: " + AudioDuck.describe())
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            AudioDuck.shared.end()
            try? await Task.sleep(nanoseconds: 600_000_000)
            print("after: " + AudioDuck.describe())
            exit(0)

        case .micCompare(let seconds, let dir):
            // The Mac's own microphone and a Bluetooth headset recording the same speech at once, for comparing how
            // fast each starts and how well each is transcribed. Writes builtin.caf and bluetooth.caf into `dir`.
            let builtIn = AudioRecorder()
            builtIn.forcedInput = .builtIn
            let headset = AudioRecorder()
            headset.forcedInput = .bluetooth
            var firstAudio: [String: Int] = [:]
            let began = Date()
            headset.onFirstAudio = { firstAudio["bluetooth"] = Int(Date().timeIntervalSince(began) * 1000) }
            builtIn.onFirstAudio = { firstAudio["builtin"] = Int(Date().timeIntervalSince(began) * 1000) }
            // MURMUR_COMPARE_ONLY=bluetooth|builtin: one microphone per process (two processes side by side), since the
            // Mac's microphone delivers nothing in a process that holds AirPods in call mode.
            let only = ProcessInfo.processInfo.environment["MURMUR_COMPARE_ONLY"]
            if only != "builtin" {
                do { try headset.start() } catch { print("bluetooth start failed: \(error)") }
                print("bluetooth start() returned after \(Int(Date().timeIntervalSince(began) * 1000)) ms, input: \(AudioRecorder.transportName(headset.inputTransport))")
            }
            if only != "bluetooth" {
                do { try builtIn.start() } catch { print("built-in start failed: \(error)") }
            }
            print("RECORDING \(Int(seconds)) s — speak now")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let urls = (bluetooth: headset.stop(), builtin: builtIn.stop())
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (name, url, recorder) in [("bluetooth", urls.bluetooth, headset), ("builtin", urls.builtin, builtIn)] {
                let rate = recorder.capturedFormat?.sampleRate ?? 0
                print("\(name): \(AudioRecorder.transportName(recorder.inputTransport)), \(Int(rate)) Hz, "
                      + "\(rate > 0 ? String(format: "%.1f", Double(recorder.capturedFrames) / rate) : "-") s, "
                      + "first buffer \(recorder.lastStartup.firstBuffer.map { "\($0) ms" } ?? "-"), "
                      + "first real audio \(firstAudio[name].map { "\($0) ms" } ?? "-"), "
                      + "first sound \(recorder.lastStartup.firstSound.map { "\($0) ms" } ?? "-"), "
                      + "restarts \(recorder.restartsThisRecording)")
                if let url {
                    let out = URL(fileURLWithPath: dir).appendingPathComponent("\(name).caf")
                    try? FileManager.default.removeItem(at: out)
                    try? FileManager.default.moveItem(at: url, to: out)
                }
            }
            exit(0)

        case .editRecords:
            // The local record of edits, in words: what needed a fix, how often, and where it first went wrong.
            print(EditRecordStore.summary(of: EditRecordStore.load()))
            exit(0)

        case .renderShell(let path):
            // The main window (Home) drawn into an image in a never-shown window (no focus change, no keys, no pointer).
            // MURMUR_RENDER_RAIL_PEEK=1 pictures the collapsed rail as it is while hovered open.
            NSApplication.shared.setActivationPolicy(.accessory)
            do {
                FontLoader.registerManrope()
                let size = CGSize(width: 1180, height: 840)
                let app = AppDelegate()
                app.micAuthorized = true
                app.axTrusted = true
                let hosting = NSHostingView(rootView: AppShellRoot(app: app).frame(width: size.width, height: size.height))
                hosting.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                // The app is pinned to light; a window that is never shown would otherwise take the system's appearance.
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                let until = Date().addingTimeInterval(1.0)
                while Date() < until { try? await Task.sleep(for: .milliseconds(100)) }
                window.displayIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)")
                }
                exit(0)
            }

        case .renderSettings(let path):
            // Settings ▸ Dictation drawn into an image in a never-shown window (no focus change, no keys); the last tab
            // the user had open is put back afterwards.
            NSApplication.shared.setActivationPolicy(.accessory)
            do {    // already on the main actor (`main` is @MainActor), and the example's translation awaits
                FontLoader.registerManrope()
                let previousTab = UserDefaults.standard.string(forKey: "settingsTab")
                UserDefaults.standard.set(SettingsTab.dictation.rawValue, forKey: "settingsTab")
                let size = CGSize(width: 900, height: 1240)
                // A throwaway delegate starts with both permissions unknown, which sends Settings to General — the
                // picture is of the page as a set-up Mac sees it.
                let app = AppDelegate()
                app.micAuthorized = true
                app.axTrusted = true
                // Any state to picture: MURMUR_RENDER_LOCALE=lv-LV MURMUR_RENDER_TRANSLATE=en (or "off").
                let environment = ProcessInfo.processInfo.environment
                if let locale = environment["MURMUR_RENDER_LOCALE"] { app.localeID = locale }
                if let target = environment["MURMUR_RENDER_TRANSLATE"] {
                    app.translateInto = target == "off" ? nil : target
                }
                if let to = app.translateInto {
                    await TranslationModels.shared.refreshApple(from: TranslateInto.code(forLocale: app.localeID), to: to)
                }
                let hosting = NSHostingView(rootView: SettingsPage(app: app).frame(width: size.width, height: size.height)
                    .background(Palette.homeGradient))
                hosting.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                // Long enough for the worked example's translation, when there's one to make.
                let wait = Double(environment["MURMUR_RENDER_WAIT"] ?? "") ?? (app.translateInto == nil ? 1.0 : 8.0)
                let until = Date().addingTimeInterval(wait)
                while Date() < until { try? await Task.sleep(for: .milliseconds(100)) }
                window.displayIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)")
                }
                if let previousTab { UserDefaults.standard.set(previousTab, forKey: "settingsTab") }
                else { UserDefaults.standard.removeObject(forKey: "settingsTab") }
                exit(0)
            }

        case .renderSnippets(let path):
            // The Snippets page and the New snippet sheet drawn into images in a never-shown window (no focus change,
            // no keys): <path>-page.png (the page for MURMUR_SNIPPETS_FILE, or the user's own), <path>-sheet.png (a
            // starter filled in), <path>-risky.png (an everyday word as the phrase), <path>-signoff.png (two lines).
            NSApplication.shared.setActivationPolicy(.accessory)
            MainActor.assumeIsolated {
                FontLoader.registerManrope()
                let pictures: [(String, AnyView, CGSize)] = [
                    ("page", AnyView(SnippetsPage(page: .constant(.snippets)).frame(width: 760, height: 620)),
                     CGSize(width: 760, height: 620)),
                    ("sheet", AnyView(SnippetEditorSheet(existing: nil, starter: ("my calendar link",
                                                                                   "https://cal.com/janis/30min"),
                                                         onDone: {})), CGSize(width: 540, height: 660)),
                    ("risky", AnyView(SnippetEditorSheet(existing: nil, starter: ("calendar", ""), onDone: {})),
                     CGSize(width: 540, height: 660)),
                    ("signoff", AnyView(SnippetEditorSheet(existing: nil, starter: ("my sign-off",
                                                                                     "Best regards,\nJanis"),
                                                           onDone: {})), CGSize(width: 540, height: 660)),
                ]
                for (suffix, view, size) in pictures {
                    let hosting = NSHostingView(rootView: view)
                    hosting.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = hosting
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    window.displayIfNeeded()
                    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(suffix).png"))
                    print("wrote \(path)-\(suffix).png")
                }
                exit(0)
            }

        case .renderTemplateSheet(let path):
            // The New template sheet drawn into images, in a window that is never shown (no focus change, no keys):
            // <path>-new.png empty, <path>-edit.png editing a template with More options open.
            NSApplication.shared.setActivationPolicy(.accessory)
            MainActor.assumeIsolated {
                FontLoader.registerManrope()
                let app = AppDelegate()
                let sample = NoteTemplate(
                    name: "Standup update", icon: "doc.text",
                    instructions: "A short update in three parts: what I did yesterday, what I'm doing today, and "
                        + "anything blocking me.",
                    voiceTrigger: "standup update",
                    exampleInput: "did the login fix, now on onboarding, waiting on design",
                    exampleOutput: "Yesterday\nLogin fix\n\nToday\nOnboarding\n\nBlockers\nWaiting on design")
                for (suffix, existing) in [("new", nil as NoteTemplate?), ("edit", sample)] {
                    let sheet = TemplateEditorSheet(app: app, existing: existing, voiceEnabled: suffix == "new",
                                                    onTurnOnVoice: {}, onDone: {}, height: suffix == "edit" ? 1080 : 712)
                    let hosting = NSHostingView(rootView: sheet)
                    // The edit one taller, to show everything under More options.
                    hosting.frame = NSRect(x: 0, y: 0, width: 540, height: suffix == "edit" ? 1080 : 712)
                    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = hosting
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    window.displayIfNeeded()
                    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    let file = "\(path)-\(suffix).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                    print("wrote \(file)")
                }
                exit(0)
            }

        case .ownFieldCheck:
            // Dictating into Murmur's own fields: a SwiftUI TextField and TextEditor like the pages', in a window that
            // is never shown (no focus change, no keys, no clipboard), get text through `OwnTextField` — and the value
            // they're bound to must change, not just the screen.
            NSApplication.shared.setActivationPolicy(.accessory)
            MainActor.assumeIsolated {
                final class Model: ObservableObject {
                    @Published var name = "Hello"
                    @Published var notes = "First line. and then"
                }
                let model = Model()
                struct Form: View {
                    @ObservedObject var model: Model
                    var body: some View {
                        VStack { TextField("Name", text: $model.name); TextEditor(text: $model.notes) }.frame(width: 300, height: 200)
                    }
                }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                let hosting = NSHostingView(rootView: Form(model: model))
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
                var ok = true
                if let field = all(hosting).compactMap({ $0 as? NSTextField }).first(where: \.isEditable),
                   window.makeFirstResponder(field), let editor = OwnTextField.focused(murmurWasInFront: true, windows: [window]) {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    OwnTextField.insert("world", into: editor, shape: true, lowercaseContinuation: true)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    print("text field: \(model.name.debugDescription)")
                    ok = ok && model.name == "Hello world"
                } else { print("text field: couldn't focus it"); ok = false }
                if let textView = all(hosting).compactMap({ $0 as? NSTextView }).first(where: { !$0.isFieldEditor }),
                   window.makeFirstResponder(textView), let editor = OwnTextField.focused(murmurWasInFront: true, windows: [window]) {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    OwnTextField.insert("The rest of it.", into: editor, shape: true, lowercaseContinuation: true)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    print("text editor: \(model.notes.debugDescription)")
                    ok = ok && model.notes == "First line. and then the rest of it."
                } else { print("text editor: couldn't focus it"); ok = false }
                print("menu before: \(NSApp.mainMenu == nil ? "none" : "set"); Edit menu items: "
                    + (OwnTextField.editMenu().items.first?.submenu?.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ") ?? ""))
                print(ok ? "OWN FIELDS OK" : "OWN FIELDS FAILED")
                exit(ok ? 0 : 1)
            }

        case .app:
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }

    private enum Mode {
        case app
        case transcribe(String)
        case micCheck
        case axProbe
        case screenProbe
        case destProbe
        case ownFieldCheck
        case renderTemplateSheet(String)
        case renderSnippets(String)
        case renderSettings(String)
        case renderShell(String)
        case editRecords
        case duckCheck
        case learnCheck(String, String)
        case micCompare(Double, String)
        case renderToast(String)
        case renderSheets(String)
        case format(String)
        case transform(String)
        case spokenCommand(String)
        case gemmaEdit(String)
        case layout(String)
        case whisperPrompt
        case code(String)
        case translate(String)
        case translateDownload(TranslationModel)
        case canaryBatch(String)
        case fieldProbe
        case edit(String)
        case harperFix(String)
        case ask(String)
        case history
        case historySearch(String)
        case historyExport(String)
        case selftest
        case guardCheck
        case secureInput
        case notetakerCheck(String, String)
        case hudCheck(String)
        case navBarCheck(String)
        case licenseVerify(String)
        case licenseUICheck(String)
        case licenseLiveCheck(String, String)
        case supportCheck(String, String)
        case renderSupport(String)
        case vad(String)
        case benchText(String)
        case editBench(String)
        case pipelineBench(String)
    }

    /// One line per entry, tab-separated: timestamp, word count, text. Text
    /// can contain embedded newlines (templated output has its own line
    /// breaks) — collapsed to spaces so the one-line-per-entry shape a
    /// terminal pipeline expects actually holds.
    private static func printHistory(_ entries: [HistoryEntry]) {
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            let line = entry.text.replacingOccurrences(of: "\n", with: " ")
            print("\(formatter.string(from: entry.date))\t\(entry.wordCount)w\t\(line)")
        }
    }

    private static func usageAndExit() -> Never {
        print("""
        Murmur — local dictation (hold fn to talk, release to paste)

        Usage:
          Murmur                      run as menu bar app
          Murmur --transcribe <file>  transcribe an audio file
                                      [--locale en-US] [--engine apple|whisper|whispercpp|parakeet|sherpa]
                                      [--whisper-model base|small|large-v3-v20240930_turbo]
                                      [--no-trim] skip the trailing-silence
                                      trim Whisper-family engines get live
                                      [--sherpa-model sense-voice-small|canary-180m-flash|funasr-nano|qwen3-asr|moonshine-base-en|zipformer-en]
                                      [--bundle-id com.apple.dt.Xcode] to test as
                                      if dictating into that app (developer
                                      vocabulary on/off resolves the same way);
                                      omitted, resolves like no app is focused
          Murmur --format "<text>"    run the text formatter on a string
                                      [--bundle-id ...] same as --transcribe
          Murmur --transform "<text>" run a ⌥1/⌥2 Transform (Polish by default)
                                      [--transform-id promptEngineer] to pick
                                      a different one from Transform.all
          Murmur --edit "<text>"      run the real rewrite pass on a string —
                                      actual persisted Voice Profile included,
                                      same as a live dictation would use
                                      [--bundle-id ...] resolves style the
                                      same way a real dictation into that
                                      app would (default: global default
                                      style); a Raw-style app prints the
                                      text unchanged, same as live
                                      [--template "Meeting Notes"] to route
                                      through a specific template instead of
                                      the no-template default
                                      [--no-guard] print the model's own
                                      output, without the skip-if-clean check
                                      and the word-preservation guard
          Murmur --guard-check        read {"original","edited"} JSON lines on
                                      stdin, print the guard's verdict for each
          Murmur --vad <file>         what the voice-activity model makes of a
                                      recording, and whether the trailing-
                                      silence trim would cut it
          Murmur --bench-text "<text>" [--runs N]  steady-state milliseconds of
                                      each text stage and the cleanup model
          Murmur --edit-bench "<text>" [--runs N] [--wait S]  cleanup latency
                                      with/without early prompt processing
          Murmur --pipeline-bench <file> [--runs N]  recognizer + cleanup
                                      together, with/without early processing
          (--edit also takes --prewarm: the app's early-session flow)
          Murmur --ask "<question>"   ask a question about your dictation history
          Murmur --history            print dictation history (last 90 days,
                                      5,000 entries max — that's all Murmur
                                      keeps on disk)
          Murmur --history-search "<term>"   search history, same window
          Murmur --history-export <path>     write history as JSON to a file
          Murmur --selftest           run formatter self-tests
        """)
        exit(0)
    }
}
