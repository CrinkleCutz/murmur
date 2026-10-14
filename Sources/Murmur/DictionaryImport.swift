import AppKit
import SwiftUI

/// "Bring your words over": a pasted list (one word per line, or separated by commas) becomes Dictionary entries, after
/// a review. Another voice app's words are copied out of that app by the user and pasted here — Murmur doesn't read
/// other apps' files. A line "heard → written" (also `->`, `=>`, a tab) is a replacement; a bare word is a name to
/// know. Ordinary everyday words are left off unless the user switches them on, since the Dictionary is for names and
/// jargon (`WhisperPrompt.isUnusual`), and a list copied from elsewhere is mostly the things it already gets right.
enum DictionaryImport {
    struct Candidate: Identifiable, Equatable {
        let id = UUID()
        var spoken: String
        var written: String
        /// A bare word, rather than "heard → written".
        var isBareWord: Bool
        /// An everyday word: off by default.
        var isEveryday: Bool
        var isNew: Bool
    }

    static let limit = 300
    private static let arrows = ["→", "->", "=>", "\t"]

    /// Candidates in the order given, duplicates and what the Dictionary already holds marked.
    static func parse(_ text: String, existing: [String: String] = [:],
                      isKnownWord: (String) -> Bool = HarperChecker.isKnownEnglishWord) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set(existing.keys.map { $0.lowercased() })
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var pairs: [(String, String?)] = []
            if let arrow = arrows.first(where: { line.contains($0) }) {
                let parts = line.components(separatedBy: arrow).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty { pairs.append((parts[0], parts[1])) }
            } else {
                let pieces = line.contains(",") || line.contains(";")
                    ? line.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init) : [line]
                for piece in pieces {
                    let word = piece.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”'•-*")))
                    if !word.isEmpty { pairs.append((word, nil)) }
                }
            }
            for (spoken, written) in pairs {
                guard spoken.count <= 60, (written?.count ?? 0) <= 120 else { continue }
                let key = spoken.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let everyday = written == nil && !WhisperPrompt.isUnusual(spoken, isKnownWord: isKnownWord)
                out.append(Candidate(spoken: spoken, written: written ?? spoken, isBareWord: written == nil,
                                     isEveryday: everyday, isNew: true))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Voice apps installed on this Mac whose words the user might want to bring over — by bundle identifier, which
    /// reads nothing of theirs.
    static func installedSources(
        isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    ) -> [String] {
        let known: [(name: String, bundleID: String)] = [
            ("Wispr Flow", "com.electron.wispr-flow"), ("Superwhisper", "com.superduper.superwhisper"),
            ("Aqua Voice", "com.electron.aqua-voice"), ("Willow", "com.seewillow.willowmac"),
            ("Typeless", "now.typeless.desktop"),
        ]
        return known.filter { isInstalled($0.bundleID) }.map(\.name)
    }

    /// Adds the accepted candidates to the Dictionary file, returning how many were new.
    @discardableResult
    static func save(_ accepted: [Candidate]) -> Int {
        var dictionary = TextFormatter.loadDictionary()
        var added = 0
        for candidate in accepted where dictionary[candidate.spoken] == nil {
            dictionary[candidate.spoken] = candidate.written
            added += 1
        }
        if let data = try? JSONEncoder().encode(dictionary) {
            try? data.write(to: TextFormatter.dictionaryURL, options: .atomic)
        }
        return added
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): dictionary import: \(label)")
        }
        let known: (String) -> Bool = { ["ember", "pine", "deep", "app", "the", "and"].contains($0) }
        let list = parse("""
            Planrify, Manrope, Ember
            super base → Supabase
            whisper flow -> Wispr Flow
            # a comment
            Deep Pine
            planrify
            """, isKnownWord: known)
        check(list.map(\.spoken) == ["Planrify", "Manrope", "Ember", "super base", "whisper flow", "Deep Pine"],
              "commas and lines both split, arrows pair, comments and repeats are dropped (got \(list.map(\.spoken)))")
        check(list[3].written == "Supabase" && !list[3].isBareWord && list[4].written == "Wispr Flow",
              "a replacement keeps what is written")
        check(!list[0].isEveryday && !list[1].isEveryday && list[2].isEveryday && list[5].isEveryday,
              "names are on by default, everyday words are not")
        let again = parse("Planrify\nOther", existing: ["planrify": "Planrify"], isKnownWord: known)
        check(again.map(\.spoken) == ["Other"], "what the Dictionary already has is skipped")
        check(parse(String(repeating: "x\n", count: 10), isKnownWord: known).count == 1, "the same word twice is one")
        check(installedSources(isInstalled: { $0 == "com.electron.wispr-flow" }) == ["Wispr Flow"]
              && installedSources(isInstalled: { _ in false }).isEmpty, "installed voice apps are found by bundle identifier")
        return passed
    }
}

/// The sheet: paste, see what was found, keep what you want.
struct DictionaryImportSheet: View {
    let existing: [String: String]
    let onDone: (Int) -> Void

    @State private var text: String
    @State private var excluded: Set<UUID> = []
    @State private var included: Set<UUID> = []
    private let sources = DictionaryImport.installedSources()

    /// `previewText`: a list already pasted (for the command line's pictures of the sheet).
    init(existing: [String: String], onDone: @escaping (Int) -> Void, previewText: String = "") {
        self.existing = existing
        self.onDone = onDone
        _text = State(initialValue: previewText)
    }

    private var candidates: [DictionaryImport.Candidate] { DictionaryImport.parse(text, existing: existing) }
    private var chosen: [DictionaryImport.Candidate] {
        candidates.filter { $0.isEveryday ? included.contains($0.id) : !excluded.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(
                        title: "Bring your words over",
                        lede: sources.isEmpty
                            ? "Paste a list of names and terms — one per line, or separated by commas."
                            : sources.count == 1
                                ? "You have \(sources[0]) installed. Copy its dictionary there, then paste it here."
                                : "You have \(joined(sources)) installed. Copy a dictionary from one, then paste it here.")
                    VStack(alignment: .leading, spacing: 0) {
                        SheetQuestion(title: "Your list", aside: "“heard → written” also works")
                        SheetTextEditor(text: $text, placeholder: "Planrify\nManrope\nsuper base → Supabase", minHeight: 120)
                    }
                    .padding(.top, SheetMetrics.sectionGap)

                    if !candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            SheetQuestion(title: "Found", trailingAside: "\(chosen.count) of \(candidates.count) selected")
                            VStack(spacing: 0) {
                                ForEach(candidates) { candidate in row(candidate) }
                            }
                        }
                        .padding(.top, SheetMetrics.sectionGap)
                        SheetNote(text: "Everyday words are off by default: the Dictionary is for names and terms Murmur "
                                  + "would otherwise get wrong.")
                    }
                }
                .padding(SheetMetrics.margin)
            }
            SheetFooter(saveTitle: chosen.isEmpty ? "Add" : "Add \(chosen.count)", canSave: !chosen.isEmpty,
                        onCancel: { onDone(0) }, onSave: { onDone(DictionaryImport.save(chosen)) }) {
                if !candidates.isEmpty { SheetStatus(text: "Nothing leaves this Mac") }
            }
        }
        .frame(width: SheetMetrics.width, height: SheetMetrics.height(fitting: 600))
        .background(Palette.panel)
    }

    private func row(_ candidate: DictionaryImport.Candidate) -> some View {
        let on = candidate.isEveryday ? included.contains(candidate.id) : !excluded.contains(candidate.id)
        return Button {
            if candidate.isEveryday {
                if on { included.remove(candidate.id) } else { included.insert(candidate.id) }
            } else {
                if on { excluded.insert(candidate.id) } else { excluded.remove(candidate.id) }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(on ? Palette.sunset : Color.clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(on ? Palette.sunset : Palette.warmInkFainter, lineWidth: 1)
                    if on { MurmurIconView(icon: .check).frame(width: 9, height: 9).foregroundStyle(.white) }
                }
                .frame(width: 16, height: 16)
                Text(candidate.isBareWord ? candidate.spoken : "\(candidate.spoken)  →  \(candidate.written)")
                    .font(.manrope(13, .medium))
                    .foregroundStyle(on ? Palette.warmInk : Palette.warmInkSoft)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if candidate.isEveryday {
                    Text("everyday word").font(.manrope(11.5)).foregroundStyle(Palette.warmInkFaint)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func joined(_ names: [String]) -> String {
        names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
