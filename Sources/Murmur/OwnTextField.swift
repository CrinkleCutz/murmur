import AppKit

/// Dictating into Murmur's own windows — Voice Profile, Dictionary, Style, App Profiles, Snippets, Templates,
/// Scratchpad, Ask… — puts the text straight into the focused field at the cursor, as if it had been typed: no
/// clipboard, no synthetic ⌘V. Murmur lives in the status bar with no menu bar, so the ⌘V it sent to itself had no
/// Edit ▸ Paste to trigger and the dictation never landed (it only reached History). Inserting directly is also
/// undoable with ⌘Z, and leaves the user's clipboard alone.
@MainActor
enum OwnTextField {
    /// The field the dictation is for, in one of Murmur's windows. The keyboard is in Murmur when one of its windows
    /// is key — including the Scratchpad panel, which takes the keyboard while another app stays in front. When Murmur
    /// itself was in front as the key came up (`murmurWasInFront`) but its window lost key status meanwhile, its
    /// frontmost window's field. Never a field in a Murmur window the user wasn't typing in: dictating into another app
    /// must not land in a Murmur page left open behind it.
    static func focused(murmurWasInFront: Bool, windows: [NSWindow]? = nil) -> NSTextView? {
        func field(_ window: NSWindow?) -> NSTextView? {
            guard let textView = window?.firstResponder as? NSTextView, textView.isEditable else { return nil }
            return textView
        }
        if let windows { return windows.lazy.compactMap(field).first }
        if let key = field(NSApp.keyWindow) { return key }
        guard murmurWasInFront else { return nil }
        return ([NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows)
            .lazy.filter(\.isVisible).compactMap(field).first
    }

    /// Inserts `text` at the cursor, replacing a selection, with the same fitting as a paste into another app (a space
    /// after the word before the cursor, lower case when continuing a sentence — `InsertionShaper`) when `shape`.
    static func insert(_ text: String, into textView: NSTextView, shape: Bool, lowercaseContinuation: Bool) {
        let selection = textView.selectedRange()
        let before = (textView.string as NSString).substring(to: min(selection.location, (textView.string as NSString).length))
        let fitted = shape
            ? InsertionShaper.shape(text, before: String(before.suffix(3)), lowercaseContinuation: lowercaseContinuation)
            : text
        textView.window?.makeFirstResponder(textView)
        textView.insertText(fitted, replacementRange: selection)
    }

    /// Murmur has no menu bar, and a Mac text field's ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z work through the Edit menu's items — so
    /// without one, none of them worked in any of Murmur's fields. A main menu with only the standard Edit items is
    /// never shown for an app without a menu bar, but its shortcuts work.
    static func editMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask =
            [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }
}
