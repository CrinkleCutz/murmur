import AppKit
import SwiftUI

// MARK: - Voice Profile / Voice Training
//
// Redesigned per the "Main" canvas (VoiceProfile.dc.html): same
// `GlassPanelPage` shell as the other redesigned pages, warm palette
// instead of the shared dynamic `Palette`. `TrainingModel` (the actual
// recording/transcription/learning logic) is untouched — this is a
// View-layer rewrite only.
//
// The toggle row, chips, and tip banner are bespoke to this page rather
// than the shared `FieldRow`/`MurmurToggle`/`ChipRow`/`PageTip` components
// — those are still tuned for the old dynamic/lime palette and shared with
// pages that haven't been redesigned yet (Settings uses `MurmurToggle` and
// `FieldRow` extensively), so forking them here keeps this page exact
// without changing how they look anywhere else.

@MainActor
final class TrainingModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var heard: String?
    @Published var result: String?
    @Published var resultIsError = false

    private let recorder = AudioRecorder()

    func toggle(app: AppDelegate, target: String) {
        if isRecording {
            stop(app: app, target: target)
        } else {
            start()
        }
    }

    private func start() {
        heard = nil
        result = nil
        resultIsError = false
        do {
            try recorder.start()
            isRecording = true
            SoundEffect.play("Pop")
        } catch {
            result = "Could not start recording: \(error.localizedDescription)"
            resultIsError = true
        }
    }

    private func stop(app: AppDelegate, target: String) {
        isRecording = false
        guard let url = recorder.stop() else { return }
        SoundEffect.play("Tink")
        isProcessing = true
        Task {
            defer {
                isProcessing = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let raw = try await app.transcribeForTraining(
                    fileAt: url, teaching: target.trimmingCharacters(in: .whitespaces))
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
                heard = cleaned.isEmpty ? nil : cleaned
                let intended = target.trimmingCharacters(in: .whitespaces)
                guard let heardText = heard else {
                    result = "Nothing was heard — try again, a bit louder."
                    resultIsError = true
                    return
                }
                if heardText.lowercased() == intended.lowercased() {
                    LearnedStore.addTerm(intended)
                    result = "Recognized correctly! Added “\(intended)” to your "
                        + "vocabulary so it stays reliable."
                    resultIsError = false
                } else if LearnedStore.add(heard: heardText, intended: intended) {
                    result = "Learned: “\(heardText)” → “\(intended)”. Murmur will "
                        + "make this correction automatically from now on."
                    resultIsError = false
                } else {
                    // "For action" → "Correction": swapping everyday words would rewrite normal speech.
                    result = "Murmur heard “\(heardText)”. “\(intended)” is in your vocabulary now, but "
                        + "“\(heardText)” is everyday words, so it isn’t swapped automatically."
                    resultIsError = false
                }
            } catch {
                result = "Transcription failed: \(error.localizedDescription)"
                resultIsError = true
            }
        }
    }
}

struct TrainingPage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @StateObject private var model = TrainingModel()
    @State private var target = ""
    @State private var learned = LearnedStore.load()
    @State private var useVoiceProfile = Settings.useVoiceProfile

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ScratchpadView.swift's own note on why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VoicePersonaCard(app: app) {
                        app.refreshVoiceProfileIfDue(force: true)
                    }
                    .padding(.top, 24)
                    useVoiceRow
                        .padding(.top, 24)
                    teachCard
                        .padding(.top, 24)
                    correctionsCard
                        .padding(.top, 24)

                    if !learned.terms.isEmpty {
                        Text("Vocabulary hints: " + learned.terms.joined(separator: ", "))
                            .font(.manrope(11.5))
                            .foregroundStyle(Palette.warmInkFaint)
                            .padding(.top, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    relatedLink
                        .padding(.top, 14)
                }
            }
        }
        .onAppear { learned = LearnedStore.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voice Profile")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            Text("How Murmur learns the way you speak — the words it mishears, and how you write.")
                .font(.manrope(12.5))
                .lineSpacing(3)
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Persona
    //
    // `VoicePersonaCard` (shared with Insights' "Your voice" tab), with a
    // refresh button here.

    // MARK: Use my voice toggle
    //
    // The profile used to be display-only. Now it feeds every rewrite and
    // every Ask answer, so it needs an off switch. A white card like every
    // other block on the page — it used to float unboxed between two cards.

    private var useVoiceRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use my voice in rewrites")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Text("Style and template rewrites keep your vocabulary and "
                     + "phrasing, and Ask answers read your notes in your terms.")
                    .font(.manrope(12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            warmToggle
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// `MurmurToggle` with a fixed accent — that shared component's
    /// "on" fill is `Palette.toggleOn` (the old dynamic/lime accent), and
    /// it's used throughout Settings, so it isn't touched here; this is a
    /// one-off matching Main.dc.html's own sunset-orange track exactly.
    private var warmToggle: some View {
        Button {
            withAnimation(.murmurEase(0.18)) {
                useVoiceProfile.toggle()
                Settings.useVoiceProfile = useVoiceProfile
            }
        } label: {
            ZStack(alignment: useVoiceProfile ? .trailing : .leading) {
                Capsule()
                    .fill(useVoiceProfile ? Palette.sunset : Palette.warmDivider)
                    .frame(width: 32, height: 19)
                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .padding(.horizontal, 2)
            }
            .frame(width: 32, height: 19)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Teach a word

    private var teachCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same card header as Insights' cards (title + corner note),
            // not a third label style.
            HStack(alignment: .lastTextBaseline) {
                Text("Teach a word")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text("by voice")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }

            HStack(spacing: 8) {
                TextField("A word or name it keeps mishearing — e.g. “Søren” or “Baseten”", text: $target)
                    .textFieldStyle(.plain)
                    .font(.manrope(13))
                    .foregroundStyle(Palette.warmInk)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmDivider, lineWidth: 1))

                Button {
                    model.toggle(app: app, target: target)
                } label: {
                    HStack(spacing: 7) {
                        if model.isRecording {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white)
                                .frame(width: 10, height: 10)
                            Text("Stop").font(.manrope(13, .semibold))
                        } else {
                            MurmurIconView(icon: .mic).frame(width: 14, height: 14)
                            Text("Record").font(.manrope(13, .semibold))
                        }
                    }
                    .foregroundStyle(model.isRecording
                                     ? .white : (visuallyMuted ? Palette.warmInkFainter : .white))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(visuallyMuted
                                  ? AnyShapeStyle(Palette.warmRowBorder)
                                  : AnyShapeStyle(model.isRecording ? Palette.danger : Palette.sunset)))
                }
                .buttonStyle(PressScaleButtonStyle())
                .disabled(recordDisabled)

                if model.isProcessing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 14)

            if model.isRecording {
                HStack(spacing: 6) {
                    MurmurIconView(icon: .wave).frame(width: 13, height: 13)
                    Text("Say “\(target)” now, then press Stop.")
                        .font(.manrope(12.5, .medium))
                }
                .foregroundStyle(Palette.danger)
                .padding(.top, 10)
            } else if let result = model.result {
                Text(result)
                    .font(.manrope(12.5, .medium))
                    .foregroundStyle(model.resultIsError ? Palette.danger : Palette.sunsetDeep)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .onAppear { learned = LearnedStore.load() }
            }

            // A plain caption on the field's own edge — it used to be a
            // white box nested inside this white card, indented off it.
            Text("Type the word, press Record, and say it 2–3 times — each different "
                 + "mishearing becomes its own correction.")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        // Without this the card shrinks to its own content's width instead
        // of the full glass panel.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var recordDisabled: Bool {
        target.trimmingCharacters(in: .whitespaces).isEmpty
            || model.isProcessing
            || !app.micAuthorized
    }

    /// The button shows its real state: grey while it can't record (no
    /// word typed yet, busy, or no microphone access), sunset when it can,
    /// red while recording. It used to stay orange with an empty field —
    /// looking ready when it wasn't (same rule as Ask's send button).
    private var visuallyMuted: Bool {
        !model.isRecording && recordDisabled
    }

    private var correctionsCount: String {
        let n = learned.corrections.count
        return "\(n) \(n == 1 ? "correction" : "corrections")"
    }

    // MARK: Learned corrections

    /// Title and count in the card's own header (like Insights' cards),
    /// then the same two-column rows as the Dictionary — what Murmur heard
    /// on the left, what it writes now on the right, delete on hover.
    private var correctionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Learned corrections")
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                Spacer()
                Text("\(correctionsCount) · also from fixes in History")
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
            }
            if learned.corrections.isEmpty {
                Text("Nothing learned yet — words you teach above, and fixes you make to a transcript "
                     + "in History, show up here.")
                    .font(.manrope(12.5))
                    .italic()
                    .foregroundStyle(Palette.warmInkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16) {
                        Text("MURMUR HEARD").frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 12, height: 1)
                        Text("NOW WRITES").frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 24, height: 1)
                    }
                    .font(.manrope(10, .semibold))
                    .kerning(0.9)
                    .foregroundStyle(Palette.warmInkSoft)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    let items = Array(learned.corrections.reversed())
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, correction in
                        CorrectionRow(correction: correction, isFirst: index == 0) {
                            var data = LearnedStore.load()
                            data.corrections.removeAll { $0.id == correction.id }
                            LearnedStore.save(data)
                            learned = data
                        }
                    }
                }
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var relatedLink: some View {
        HStack(spacing: 4) {
            Text("Setting a word manually instead?")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
            Button { page = .dictionary } label: {
                Text("Dictionary")
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Palette.sunsetDeep)
            }
            .buttonStyle(.plain)
            Text("lets you define exact replacements.")
                .font(.manrope(12))
                .foregroundStyle(Palette.warmInkSoft)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Same row as the Dictionary's `DictListRow`: equal columns (no quote
/// marks), an arrow icon, the correction in bold with "×N" for repeats,
/// delete on hover on the app-wide translucent wash.
private struct CorrectionRow: View {
    let correction: LearnedCorrection
    var isFirst = false
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Text(correction.heard)
                .font(.manrope(13))
                .foregroundStyle(Palette.warmInkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            MurmurIconView(icon: .arrowRight)
                .frame(width: 12, height: 12)
                .foregroundStyle(Palette.warmInkFainter)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(correction.intended)
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(Palette.warmInk)
                if correction.timesSeen > 1 {
                    Text("×\(correction.timesSeen)")
                        .font(.manrope(11))
                        .foregroundStyle(Palette.warmInkFainter)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(icon: .trash, size: 24, iconSize: 12, hoverFill: Palette.hoverWash,
                       help: "Remove", action: onDelete)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(hovering ? Palette.hoverWash : Color.clear))
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                    .padding(.horizontal, 10)
                    .opacity(hovering ? 0 : 1)
            }
        }
        // See HomeView.swift's history row for why this is needed: a .clear
        // background makes SwiftUI treat the row's empty space as outside
        // the hoverable region until this forces the whole padded frame to
        // count, regardless of what's actually drawn there.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
