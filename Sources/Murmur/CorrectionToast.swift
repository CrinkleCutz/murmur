import AppKit
import SwiftUI

/// "Saved “Manrope” — Undo": what Murmur has just learned from an edit the user made where the dictation landed, shown
/// for a few seconds with a way to take it back (Wispr Flow and VoiceOS do the same: the correction is saved at once,
/// and Undo removes it). A small black card, like the dictation pill, in a panel that never takes focus — so the app
/// being written in keeps the cursor — and without a shadow, like the pill.
@MainActor
final class CorrectionToastController {
    private var panel: NSPanel?
    private let model = CorrectionToastModel()
    private var hideTask: Task<Void, Never>?
    private var receipts: [LearnReceipt] = []
    private var notices: [LearnedNotice] = []

    /// Called with everything that was saved when the user taps Undo.
    var onUndo: ([LearnReceipt]) -> Void = { _ in }

    static let size = NSSize(width: 380, height: 66)
    /// How long it stays: long enough to read what was saved and decide, short enough to be gone before the next thought.
    static let duration: Double = 8

    func show(_ notices: [LearnedNotice]) {
        guard let first = notices.first else { return }
        self.notices = notices
        receipts = notices.map(\.receipt)
        model.title = notices.count == 1
            ? "Saved “\(first.intended)”"
            : "Saved “\(first.intended)” and \(notices.count - 1) more"
        model.detail = notices.count == 1
            ? (first.heard.isEmpty ? "A new word Murmur will listen for." : "Instead of “\(first.heard)”, from now on.")
            : "From now on, instead of what was heard."
        model.undone = false
        model.progress = 1
        let panel = existingOrNewPanel()
        var origin = HUDDock.origin(for: Self.size)
        origin.y += 54   // above the dictation pill's own spot
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true, animate: false)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.82)) {
            model.visible = true
        }
        withAnimation(.linear(duration: Self.duration)) { model.progress = 0 }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Takes the card down for a dictation that is starting, and hands back what it was still showing — so it can come
    /// back when that dictation has landed, rather than be missed.
    func interrupt() -> [LearnedNotice] {
        let unseen = (model.visible && !model.undone) ? notices : []
        hide()
        return unseen
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        panel.ignoresMouseEvents = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.2)) { model.visible = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func undo() {
        guard !model.undone else { return }
        model.undone = true
        let taken = receipts
        receipts = []
        onUndo(taken)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }
        let hosting = FirstClickHostingView(rootView: CorrectionToastView(model: model, onUndo: { [weak self] in self?.undo() }))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.sizingOptions = []
        hosting.appearance = NSAppearance(named: .darkAqua)
        let newPanel = NSPanel(
            contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        newPanel.contentView = hosting
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.level = .statusBar
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = newPanel
        return newPanel
    }
}

@MainActor
final class CorrectionToastModel: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
    @Published var undone = false
    @Published var visible = false
    /// 1 → 0 over `CorrectionToastController.duration`: the thin line along the bottom.
    @Published var progress: Double = 1
}

struct CorrectionToastView: View {
    @ObservedObject var model: CorrectionToastModel
    var onUndo: () -> Void

    @State private var hoveringUndo = false

    private let radius: CGFloat = 18

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.undone ? "arrow.uturn.backward" : "text.badge.checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.undone ? "Taken back" : model.title)
                    .font(.manrope(14, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(model.undone ? "Murmur won’t use it." : model.detail)
                    .font(.manrope(12, .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !model.undone {
                Button(action: onUndo) {
                    Text("Undo")
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(Capsule().fill(.white.opacity(hoveringUndo ? 0.26 : 0.16)))
                }
                .buttonStyle(.plain)
                .onHover { hoveringUndo = $0 }
                .animation(.easeOut(duration: 0.12), value: hoveringUndo)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(width: 360, height: 54)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.hudBlack))
        .overlay(alignment: .bottomLeading) {
            // The time left, as a line along the bottom edge, inside the card's corners.
            GeometryReader { box in
                Rectangle().fill(.white.opacity(0.28))
                    .frame(width: max(0, box.size.width * model.progress), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(model.undone ? 0 : 1)
        }
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1 : 0.96, anchor: .bottom)
        .offset(y: model.visible ? 0 : 6)
        .frame(width: CorrectionToastController.size.width, height: CorrectionToastController.size.height,
               alignment: .bottom)
    }
}
