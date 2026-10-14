import AppKit
import SwiftUI

/// "Report a problem": what the user wrote, plus a few facts about this Mac, sent to the website's `/api/support`, which
/// emails the inbox with the sender as Reply-To. No browser, no mail app, no account.
///
/// What leaves the Mac is exactly `Payload`, and the sheet lists it. Nothing the user dictated or wrote elsewhere is
/// ever part of it; the message is only sent when they press Send.
enum SupportReport {
    struct Payload: Encodable, Equatable {
        struct Diagnostics: Encodable, Equatable {
            var appVersion: String
            var macOS: String
            var model: String
            var license: String
            var language: String
        }
        var message: String
        var email: String
        var source = "app"
        var diagnostics: Diagnostics
    }

    enum Outcome: Equatable {
        case sent
        /// The server said no, or there is no connection.
        case failed
        /// Nothing worth sending yet.
        case empty
    }

    static let inbox = "hello@murmurmac.com"

    /// One dictation the user is reporting a problem with. Its words go along only when the user switches that on in
    /// the sheet, and the sheet shows exactly which words.
    struct DictationContext: Equatable {
        var pasted: String
        /// What the recognizer wrote before Murmur's clean-up, when the local record of edits has this dictation.
        var heard: String?

        /// The words as they are sent, appended to what the user wrote.
        var appended: String {
            var out = "\n\n— The dictation —\nPasted: \(pasted)"
            if let heard, heard != pasted { out += "\nHeard: \(heard)" }
            return out
        }

        @MainActor static func make(pasted: String) -> DictationContext {
            let heard = EditRecordStore.isEnabled
                ? EditRecordStore.load().last(where: { $0.pasted == pasted })?.raw : nil
            return DictationContext(pasted: pasted, heard: heard)
        }
    }

    /// The facts sent along with the message. Cheap, and safe to show in full.
    @MainActor static func diagnostics() -> Payload.Diagnostics {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let licence: String
        if BuildChannel.current == .source { licence = "Source build" }
        else { licence = LicenseStore.shared.license != nil ? "Licensed" : "Trial or unlicensed" }
        return Payload.Diagnostics(
            appVersion: LicenseStore.appVersion,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            model: String(cString: model),
            license: licence,
            language: Locale.preferredLanguages.first ?? "")
    }

    /// The email to pre-fill: the licence's, else the last one used here.
    @MainActor static func suggestedEmail() -> String {
        if let email = LicenseStore.shared.license?.payload.email, !email.isEmpty { return email }
        return UserDefaults.standard.string(forKey: "supportEmail") ?? ""
    }

    static var endpoint: URL { URL(string: LicenseLinks.site + "/api/support")! }

    /// Sends one report. `transport` is swapped out in checks.
    static func send(_ payload: Payload, to url: URL = endpoint,
                     transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) })
        async -> Outcome {
        guard payload.message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 else { return .empty }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(payload) else { return .failed }
        request.httpBody = body
        guard let (_, response) = try? await transport(request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .failed }
        return .sent
    }
}

/// The sheet: one box, an email, a note on what goes along, Send.
struct SupportReportSheet: View {
    let onDone: () -> Void
    var height: CGFloat = SheetMetrics.height(fitting: 560)
    /// Set when it is opened from a dictation in History.
    var dictation: SupportReport.DictationContext?
    @State private var includeDictation = false

    @State private var message = ""
    @State private var email = ""
    @State private var state: SendState = .idle
    @FocusState private var messageFocused: Bool

    private enum SendState { case idle, sending, sent, failed }

    private var canSend: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 && state != .sending && state != .sent
    }

    var body: some View {
        VStack(spacing: 0) {
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(
                        title: "Report a problem",
                        lede: "Say what you did and what you expected. It goes straight to the person who makes Murmur.")

                    VStack(alignment: .leading, spacing: 0) {
                        SheetQuestion(title: "What happened?")
                        SheetTextEditor(text: $message, placeholder: "What you did, what you expected, and what happened.",
                                        minHeight: 130)
                    }
                    .padding(.top, SheetMetrics.sectionGap)

                    VStack(alignment: .leading, spacing: 0) {
                        SheetQuestion(title: "Your email", aside: "so we can reply")
                        SheetPhraseField(text: $email, placeholder: "you@example.com", hint: "optional")
                    }
                    .padding(.top, SheetMetrics.sectionGap)

                    if let dictation {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline) {
                                SheetQuestion(title: "This dictation", aside: "only if you switch it on")
                                Spacer(minLength: 8)
                                ReportToggle(isOn: $includeDictation)
                            }
                            Text(dictation.pasted)
                                .font(.manrope(12.5))
                                .lineSpacing(2)
                                .foregroundStyle(includeDictation ? Palette.warmInk : Palette.warmInkFaint)
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.warmRowBorder, in: RoundedRectangle(cornerRadius: SheetMetrics.fieldRadius, style: .continuous))
                        }
                        .padding(.top, SheetMetrics.sectionGap)
                    }

                    SheetNote(text: includeDictation
                              ? "Sent along: your versions, Mac model and licence status, and the dictation shown above. "
                                  + "Nothing else you dictated or wrote."
                              : "Sent along: your Murmur and macOS versions, your Mac model and whether you’re licensed. "
                                  + "Never anything you dictated or wrote.")
                        .padding(.top, SheetMetrics.sectionGap)
                }
                .padding(SheetMetrics.margin)
            }
            SheetFooter(saveTitle: state == .sending ? "Sending…" : "Send", canSave: canSend, onCancel: onDone, onSave: send) {
                status
            }
        }
        .frame(width: SheetMetrics.width, height: height)
        .background(Palette.panel)
        .onAppear {
            email = SupportReport.suggestedEmail()
            messageFocused = true
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .sent:
            Text("Sent. Thank you.").font(.manrope(12.5, .medium)).foregroundStyle(Palette.warmInk)
        case .failed:
            Text("Couldn’t send. Write to \(SupportReport.inbox) instead.")
                .font(.manrope(12)).foregroundStyle(Palette.sunsetDeep)
        default:
            EmptyView()
        }
    }

    private func send() {
        state = .sending
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeDictation, let dictation { text += dictation.appended }
        let payload = SupportReport.Payload(message: text, email: cleanEmail, diagnostics: SupportReport.diagnostics())
        Task { @MainActor in
            let outcome = await SupportReport.send(payload)
            if outcome == .sent {
                if !cleanEmail.isEmpty { UserDefaults.standard.set(cleanEmail, forKey: "supportEmail") }
                state = .sent
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                onDone()
            } else {
                state = .failed
            }
        }
    }
}


/// The same switch as Settings' (that one is private to its file).
private struct ReportToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.murmurEase(0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Palette.sunset : Palette.warmDivider).frame(width: 32, height: 19)
                Circle().fill(.white).frame(width: 15, height: 15).padding(.horizontal, 2)
            }
            .frame(width: 32, height: 19)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
