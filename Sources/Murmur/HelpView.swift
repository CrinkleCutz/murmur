import AppKit
import SwiftUI

// MARK: - Help
//
// Laid out like Settings: tabs (Basics · Shortcuts · Features · Troubleshooting · Privacy), small section labels over
// white cards, and every answer visible at once — the old page hid everything behind six closed tiles and then a
// second click per question. A search field in the header finds an answer in any tab. Every line is checked against
// what the app actually does, and anything that can change — your dictation key, Scratchpad's and Notetaker's
// shortcuts, your own transforms, whether hands-free stops by itself, which updater this build uses — is read live,
// so Help never describes a Murmur you don't have.

struct HelpPage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    /// The last tab you looked at.
    @AppStorage("helpTab") private var storedTab = HelpTab.basics.rawValue
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Where "Report a problem" goes — one place, so it's easy to point elsewhere.
    static let reportProblemURL = URL(string: "https://www.murmurmac.com/support")!

    private var currentTab: HelpTab { HelpTab(rawValue: storedTab) ?? .basics }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ScratchpadView.swift's own note on why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    UnderlineTabBar(tabs: HelpTab.allCases, selected: trimmedQuery.isEmpty ? currentTab : nil,
                                    title: \.title, select: { tab in
                                        query = ""
                                        storedTab = tab.rawValue
                                    })
                        .padding(.top, 20)
                    VStack(alignment: .leading, spacing: 0) {
                        if trimmedQuery.isEmpty {
                            ForEach(Array(sections(for: currentTab).enumerated()), id: \.offset) { index, section in
                                sectionView(section)
                                    .padding(.top, index == 0 ? 0 : 24)
                            }
                        } else {
                            searchResults
                        }
                    }
                    .padding(.top, 24)
                }
            }
        }
    }

    // MARK: Header and search

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Help")
                    .font(.manrope(22, .medium))
                    .tracking(-0.33)
                    .foregroundStyle(Palette.warmInk)
                Text("How to dictate, every shortcut, what each feature does, and what to check when something "
                     + "isn't working.")
                    .font(.manrope(12.5))
                    .foregroundStyle(Palette.warmInkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            searchField
                .padding(.top, 2)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            MurmurIconView(icon: .search)
                .frame(width: 12, height: 12)
                .foregroundStyle(Palette.warmInkFaint)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search help")
                        .foregroundStyle(Palette.warmInkFaint)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.warmInk)
                    .focused($searchFocused)
                    .onExitCommand { query = "" }
            }
            .font(.manrope(12.5))
            if !query.isEmpty {
                Button { query = "" } label: {
                    MurmurIconView(icon: .plus)
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(45))
                        .foregroundStyle(Palette.warmInkFaint)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .murmurTooltip("Clear search")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 200, height: 30)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(searchFocused ? Palette.sunset : Palette.warmRowBorder,
                              lineWidth: searchFocused ? 1.5 : 1))
        .background {
            // ⌘F jumps to search, as it does in every Mac app with one.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private var searchResults: some View {
        let words = trimmedQuery.split(separator: " ").map(String.init)
        let matches = HelpTab.allCases.flatMap { tab in
            sections(for: tab).flatMap(\.items).map { (tab, $0) }
        }
        .filter { _, item in
            let haystack = [item.title, item.body, item.destination?.title ?? ""].joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel(title: matches.isEmpty
                ? "NO ANSWERS FOR \u{201c}\(trimmedQuery.uppercased())\u{201d}"
                : "\(matches.count) \(matches.count == 1 ? "ANSWER" : "ANSWERS") FOR \u{201c}\(trimmedQuery.uppercased())\u{201d}")
            SettingsCard {
                if matches.isEmpty {
                    HelpRow(item: HelpItem(
                                title: "Try another word",
                                body: "Or tell us what you were looking for — we'll add the answer.",
                                destination: .url("Report a problem", Self.reportProblemURL)),
                            isLast: true, open: open)
                } else {
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                        HelpRow(item: match.1, tabTitle: match.0.title, isLast: index == matches.count - 1, open: open)
                    }
                }
            }
        }
    }

    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel(title: section.title, trailing: section.trailing)
            SettingsCard {
                ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                    HelpRow(item: item, isLast: index == section.items.count - 1, open: open)
                }
            }
        }
    }

    private func open(_ destination: HelpDestination) {
        switch destination {
        case .page(_, let target):
            page = target
        case .settings(_, let tab):
            // Settings reads its remembered tab on appear, so this lands on the right one.
            UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
            page = .settings
        case .url(_, let url):
            NSWorkspace.shared.open(url)
        case .folder(_, let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Content

    private func sections(for tab: HelpTab) -> [HelpSection] {
        switch tab {
        case .basics: basics
        case .shortcuts: shortcuts
        case .features: features
        case .troubleshooting: troubleshooting
        case .privacy: privacy
        }
    }

    private var dictationKeycap: String {
        switch app.hotkey {
        case .fn: "fn"
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        case .rightShift: "Right ⇧"
        }
    }

    private var hold: HelpShortcut { HelpShortcut(verb: "Hold", keys: [dictationKeycap]) }
    private var doubleTap: HelpShortcut { HelpShortcut(verb: "Double-tap", keys: [dictationKeycap]) }

    private var handsFreeFinish: String {
        Settings.handsFreeAutoStop
            ? "Stop talking and it finishes by itself, or tap the key once more."
            : "Tap the key once more to finish."
    }

    private var basics: [HelpSection] {
        [
            HelpSection(title: "DICTATING", items: [
                HelpItem(title: "Hold to talk",
                         body: "Hold \(app.hotkey.displayName), speak, and let go — your words land at your cursor, "
                             + "cleaned up. A quick tap is ignored, so a stray touch never records.",
                         shortcut: hold),
                HelpItem(title: "Hands-free",
                         body: "Double-tap the key and talk as long as you like. \(handsFreeFinish)",
                         shortcut: doubleTap),
                HelpItem(title: "Where your words go",
                         body: "Into the app you're typing in. If Murmur can't paste there, they're on your "
                             + "clipboard — press ⌘V."),
                HelpItem(title: "Speak one language, paste another",
                         body: "Pick a language in Settings ▸ Dictation ▸ Translate into, or from the language menu on "
                             + "the bar. Murmur translates on this Mac — macOS’s own translator, or Gemma 4 and EuroLLM "
                             + "if you download them. If a name, number, date or link comes out different, your own "
                             + "words are pasted instead and the notch says why. Never in a terminal or code editor."),
                HelpItem(title: "Coding agents, editors and the terminal",
                         body: "Murmur reads what kind of field you're in. A prompt box — Claude Code or Codex, even "
                             + "running in Terminal, or an editor's chat — gets a clean paragraph. Code and a shell get "
                             + "your exact words, with code said out loud written as code: \u{201c}git rebase dash i head "
                             + "tilde three\u{201d} → git rebase -i HEAD~3, \u{201c}camel case upload client\u{201d} → "
                             + "uploadClient. File names come out the way your project spells them (\u{201c}the upload "
                             + "client\u{201d} → UploadClient) — names only, never their contents. Say "
                             + "\u{201c}literally\u{201d} to keep a word as a word."),
                HelpItem(title: "Edit selected text by voice",
                         body: "Select text, hold the dictation key and say what to change: \u{201c}make this "
                             + "shorter\u{201d}, \u{201c}fix the grammar\u{201d}, \u{201c}turn this into bullet "
                             + "points\u{201d}, \u{201c}translate it into Spanish\u{201d}, \u{201c}make it more "
                             + "formal\u{201d}. The selection is rewritten in place — ⌘Z puts it back. Anything else "
                             + "you say is dictated as usual. In English dictation."),
            ]),
            HelpSection(title: "SAY IT WHILE YOU TALK", items: [
                HelpItem(title: "\u{201c}new line\u{201d} · \u{201c}new paragraph\u{201d}",
                         body: "Adds a line break, or a blank line between paragraphs."),
                HelpItem(title: "\u{201c}scratch that\u{201d}",
                         body: "Drops what came just before it: \u{201c}Buy milk, scratch that, eggs\u{201d} becomes "
                             + "\u{201c}Buy eggs.\u{201d} \u{201c}Forget that\u{201d} and \u{201c}never mind "
                             + "that\u{201d} work too."),
                HelpItem(title: "Change your mind",
                         body: "Say \u{201c}5pm, actually 6pm\u{201d} or \u{201c}Tuesday, no wait, "
                             + "Wednesday\u{201d} — only the correction is kept. In English dictation."),
                HelpItem(title: "Punctuation and filler",
                         body: "Punctuation comes from your pauses, and \u{201c}um\u{201d} and \u{201c}uh\u{201d} "
                             + "are dropped — in German, French, Spanish, Italian, Dutch, Portuguese and Swedish too "
                             + "(\u{201c}äh\u{201d}, \u{201c}euh\u{201d}…), along with words said twice. Terminals get "
                             + "exactly what you said — no cleanup, and no commands."),
            ]),
        ]
    }

    /// A Help row that only exists while Notetaker does — one `+` splice in the list, so a hidden Notetaker leaves
    /// no empty slot, dead link or mention behind.
    private static func onlyWithNotetaker(_ item: HelpItem) -> [HelpItem] {
        Notetaker.isAvailable ? [item] : []
    }

    private var shortcuts: [HelpSection] {
        let scratchpad = KeyComboLabel.symbols(for: Settings.scratchpadHotkeyModifiers)
            + [KeyComboLabel.keyName(for: Settings.scratchpadHotkeyKeyCode)]
        let notetaker = KeyComboLabel.symbols(for: Settings.notetakerHotkeyModifiers)
            + [KeyComboLabel.keyName(for: Settings.notetakerHotkeyKeyCode)]
        let transforms = Transform.allIncludingCustom.compactMap { transform -> HelpItem? in
            guard let shortcut = TransformsPage.shortcut(of: transform) else { return nil }
            return HelpItem(title: transform.name,
                            body: transform.isCustom ? "Your own transform." : transform.description,
                            shortcut: HelpShortcut(keys: shortcut.map(String.init)))
        }
        return [
            HelpSection(title: "IN ANY APP", trailing: "Change them in Settings, Scratchpad and App Profiles", items: [
                HelpItem(title: "Dictate", body: "Hold, speak, release.", shortcut: hold,
                         destination: .settings("Settings", .dictation)),
                HelpItem(title: "Hands-free", body: handsFreeFinish, shortcut: doubleTap),
                HelpItem(title: "Scratchpad", body: "Opens a floating note to dictate or type into.",
                         shortcut: HelpShortcut(keys: scratchpad), destination: .page("Scratchpad", .scratchpad)),
            ] + Self.onlyWithNotetaker(
                HelpItem(title: "Notetaker", body: "Starts or stops recording the call you're in.",
                         shortcut: HelpShortcut(keys: notetaker), destination: .settings("Settings", .notetaker))
            ) + [
                HelpItem(title: "Dictate with an App Profile",
                         body: "Uses that profile's style whatever app you're in. Give a profile a number in "
                             + "App Profiles.",
                         shortcut: HelpShortcut(keys: ["⌃", "⇧", "1–9"]),
                         destination: .page("App Profiles", .appProfiles)),
            ]),
            HelpSection(title: "WITH TEXT SELECTED", items: transforms + [
                HelpItem(title: "Undo the last transform", body: "Puts your original text back.",
                         shortcut: HelpShortcut(keys: ["⌥", "⇧", "Z"])),
            ]),
        ]
    }

    private var features: [HelpSection] {
        [
            HelpSection(title: "SOUND LIKE YOU", items: [
                HelpItem(title: "Style",
                         body: "Pick a tone — As spoken, Auto, Formal, Casual, Very casual or Raw — and how much "
                             + "Murmur tidies up.",
                         destination: .page("Style", .style)),
                HelpItem(title: "App Profiles", body: "A different tone, template or paste setting for each app.",
                         destination: .page("App Profiles", .appProfiles)),
                HelpItem(title: "Voice Profile",
                         body: "Learns how you write from your dictations, so cleanup keeps your voice.",
                         destination: .page("Voice Profile", .training)),
            ]),
            HelpSection(title: "GET YOUR WORDS RIGHT", items: [
                HelpItem(title: "Dictionary",
                         body: "Exact replacements: say \u{201c}super base\u{201d}, get \u{201c}Supabase\u{201d}.",
                         destination: .page("Dictionary", .dictionary)),
                HelpItem(title: "Correct & learn",
                         body: "Fix a dictation on Home with its pencil button, and Murmur learns the word for "
                             + "next time.",
                         destination: .page("Home", .home)),
                HelpItem(title: "Snippets", body: "Say a short trigger and Murmur pastes the saved text.",
                         destination: .page("Snippets", .snippets)),
                HelpItem(title: "Developer words",
                         body: "In code editors, terminals and AI apps, Murmur knows names like Supabase and "
                             + "Claude Code. Automatic."),
            ]),
            HelpSection(title: "TOOLS", items: [
                HelpItem(title: "Templates",
                         body: "Say a template's phrase first, and what follows comes out as meeting notes, a "
                             + "to-do list and more.",
                         destination: .page("Templates", .templates)),
                HelpItem(title: "Transforms",
                         body: "Select text in any app and press ⌥1 to polish it — or make your own.",
                         destination: .page("Transforms", .transforms)),
            ] + Self.onlyWithNotetaker(
                HelpItem(title: "Notetaker",
                         body: "Records a call, then writes the transcript and a summary — on this Mac.",
                         destination: .page("Notetaker", .notetaker))
            ) + [
                HelpItem(title: "Scratchpad", body: "Quick notes you can dictate into from any app.",
                         destination: .page("Scratchpad", .scratchpad)),
                HelpItem(title: "Ask Murmur", body: "Ask questions about what you've dictated lately.",
                         destination: .page("Ask Murmur", .ask)),
                HelpItem(title: "Insights", body: "How much you dictate, and the time it saves you.",
                         destination: .page("Insights", .insights)),
            ]),
        ]
    }

    private var troubleshooting: [HelpSection] {
        var dictation = [
            HelpItem(title: "Holding the dictation key does nothing",
                     body: "Murmur needs Accessibility to hear the key in other apps. Allow it, then relaunch Murmur.",
                     destination: .settings("Settings", .general)),
            HelpItem(title: "The emoji picker or Apple's dictation opens instead",
                     body: "macOS uses the Globe key too. In System Settings → Keyboard, set \u{201c}Press 🌐 key "
                         + "to\u{201d} Do Nothing and turn off Apple's Dictation shortcut — or pick another "
                         + "dictation key.",
                     destination: .settings("Settings", .dictation)),
            HelpItem(title: "My words went to the clipboard, not the app",
                     body: "Paste automatically may be off — in Settings, or for that app in App Profiles — or you "
                         + "were in a password field. Press ⌘V to paste now."),
            HelpItem(title: "It keeps getting a word or name wrong",
                     body: "Add it to your Dictionary, or fix it on Home so Murmur learns it. Both work when you "
                         + "dictate in English.",
                     destination: .page("Dictionary", .dictionary)),
            HelpItem(title: "It's slow after I changed the engine",
                     body: "The new model is still downloading — up to 1.7 GB. Apple's engine covers your "
                         + "dictations until Settings → Dictation says it's loaded.",
                     destination: .settings("Settings", .dictation)),
            HelpItem(title: "My language isn't in the list",
                     body: "Each engine understands a different set of languages. Try another engine.",
                     destination: .settings("Settings", .dictation)),
        ]
        if LicenseStore.shared.channel == .release {
            dictation.append(HelpItem(
                title: "Dictation is paused",
                body: "Your free trial ended, or your license couldn't be confirmed lately. The License tab says "
                    + "which, and how to carry on.",
                destination: .settings("Settings", .license)))
        }
        return [
            HelpSection(title: "DICTATION", items: dictation),
            HelpSection(title: "SHORTCUTS AND TOOLS", items: [
                HelpItem(title: "Shortcuts stopped responding",
                         body: "A password field, or Terminal's Secure Keyboard Entry, is holding the keyboard. "
                             + "Close it or quit that app — Murmur's menu bar menu names it."),
                HelpItem(title: "⌥1 or ⌥2 does nothing",
                         body: "Transforms need Apple Intelligence turned on in System Settings, and some text "
                             + "selected first."),
                HelpItem(title: "A template didn't apply",
                         body: "Check that Apply by voice is on, and say the template's phrase at the very start.",
                         destination: .page("Templates", .templates)),
            ] + Self.onlyWithNotetaker(
                HelpItem(title: "Notetaker only hears me",
                         body: "Allow Screen Recording — Notetaker uses it to hear the other side of the call. It "
                             + "never records your screen.",
                         destination: .settings("Settings", .general))
            )),
            HelpSection(title: "STILL STUCK?", items: [
                HelpItem(title: "Tell us what happened",
                         body: "Say what you did and what you expected, and we'll look into it.",
                         destination: .url("Report a problem", Self.reportProblemURL)),
            ]),
        ]
    }

    private var privacy: [HelpSection] {
        let isRelease = LicenseStore.shared.channel == .release
        var online = [
            HelpItem(title: "To download a speech model",
                     body: "Only the one you pick, from Hugging Face or GitHub."),
            HelpItem(title: "To check for updates",
                     body: isRelease ? "Asks murmurmac.com whether there's a newer Murmur."
                                     : "Asks GitHub whether there's a newer Murmur."),
        ]
        if isRelease {
            online.append(HelpItem(
                title: "To confirm your license",
                body: "About once a week: your license key and an ID for this Mac (and its name, when you "
                    + "activate). Never your dictations."))
        }
        return [
            HelpSection(title: "STAYS ON THIS MAC", items: [
                HelpItem(title: "Your voice and your words",
                         body: (Notetaker.isAvailable
                                ? "Recognition, cleanup, Transforms, Templates, Ask Murmur and Notetaker all run on "
                                : "Recognition, cleanup, Transforms, Templates and Ask Murmur all run on ")
                             + "this Mac. No recording or text is ever sent anywhere."),
                HelpItem(title: "Your history",
                         body: "Kept on this Mac for 90 days, up to 5,000 dictations. Clear it any time on Home."),
            ] + Self.onlyWithNotetaker(
                HelpItem(title: "Meetings",
                         body: "Notetaker reads only the open browser tab's address to spot a call, and your "
                             + "calendar only to name it.")
            ) + [
                HelpItem(title: "Where it's all kept",
                         body: "Your history, notes, meetings and words live in one folder on this Mac.",
                         destination: .folder("Show in Finder", AppPaths.supportDirectory)),
            ]),
            HelpSection(title: "GOES ONLINE ONLY", items: online),
        ]
    }
}

// MARK: - Model

enum HelpTab: String, CaseIterable {
    case basics, shortcuts, features, troubleshooting, privacy

    var title: String {
        switch self {
        case .basics: "Basics"
        case .shortcuts: "Shortcuts"
        case .features: "Features"
        case .troubleshooting: "Troubleshooting"
        case .privacy: "Privacy"
        }
    }
}

struct HelpSection {
    let title: String
    var trailing: String? = nil
    let items: [HelpItem]
}

struct HelpShortcut {
    /// "Hold", "Double-tap" — how the keys are pressed, when it isn't just pressing them.
    var verb: String? = nil
    let keys: [String]
}

/// Where a row leads — the name shown on the row, and the place.
enum HelpDestination {
    case page(String, Page)
    case settings(String, SettingsTab)
    case url(String, URL)
    case folder(String, URL)

    var title: String {
        switch self {
        case .page(let title, _), .settings(let title, _), .url(let title, _), .folder(let title, _): title
        }
    }

    /// Opens outside Murmur (a web page, Finder).
    var isExternal: Bool {
        switch self {
        case .url, .folder: true
        case .page, .settings: false
        }
    }
}

struct HelpItem {
    let title: String
    let body: String
    var shortcut: HelpShortcut? = nil
    var destination: HelpDestination? = nil
}

// MARK: - Row

/// One answer, as a shared `CardRow`: on the right either the shortcut's keys or where it leads.
private struct HelpRow: View {
    let item: HelpItem
    var tabTitle: String? = nil
    let isLast: Bool
    let open: (HelpDestination) -> Void

    var body: some View {
        CardRow(title: item.title, detail: item.body, eyebrow: tabTitle, isLast: isLast,
                action: item.destination.map { destination in { open(destination) } }) {
            if let shortcut = item.shortcut {
                HStack(spacing: 3) {
                    if let verb = shortcut.verb {
                        Text(verb)
                            .font(.manrope(11.5, .medium))
                            .foregroundStyle(Palette.warmInkFaint)
                            .padding(.trailing, 4)
                    }
                    ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                        WarmKeycap(label: key)
                    }
                }
                .fixedSize()
            }
            if let destination = item.destination {
                RowDestinationLabel(title: destination.title, external: destination.isExternal)
            }
        }
    }
}
