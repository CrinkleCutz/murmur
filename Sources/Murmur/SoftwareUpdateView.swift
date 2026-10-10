import AppKit
import SwiftUI

// MARK: - Software Update
//
// Redesigned per the "Main" canvas (SoftwareUpdate.dc.html), presented as
// a `.sheet` over the whole app shell rather than a page of its own —
// `AppShellRoot` shows it whenever `AppDelegate.availableUpdate` is set,
// which only happens once `UpdateChecker` finds a real, newer GitHub
// release (see AppUpdate.swift). Everything on this sheet is real data
// from that release; nothing here is hardcoded example content.
//
// "Update Now" calls `AppDelegate.installUpdate(_:)`, which downloads and
// installs the release's `.zip` asset in place and relaunches — see
// AppInstaller.swift. It falls back to opening the browser only if that
// isn't possible (no zip asset, or the install fails partway), so this
// sheet doesn't need its own fallback logic beyond showing progress.

struct SoftwareUpdateSheet: View {
    let update: AppUpdate
    @ObservedObject var app: AppDelegate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Palette.sunset)
                    UpdateBadgeWaveform()
                }
                .frame(width: 56, height: 56)
                .shadow(color: Palette.sunset.opacity(0.28), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text("UPDATE AVAILABLE")
                        .font(.manrope(10.5, .bold))
                        .tracking(0.8)
                        .foregroundStyle(Palette.warmInkFaint)
                    Text("Murmur \(update.version) is available")
                        .font(.manrope(20, .bold))
                        .tracking(-0.2)
                        .foregroundStyle(Palette.warmInk)
                    if let subtitle {
                        Text(subtitle)
                            .font(.manrope(12))
                            .foregroundStyle(Palette.warmInkSoft)
                    }
                }
            }

            Rectangle().fill(Palette.warmRowBorder).frame(height: 1).padding(.top, 22).padding(.bottom, 18)

            if !update.notes.isEmpty {
                Text("What's New in Version \(update.version)")
                    .font(.manrope(13, .bold))
                    .foregroundStyle(Palette.warmInk)

                ThinScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(update.notes.enumerated()), id: \.offset) { index, note in
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(Palette.sunsetDeep)
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 7)
                                Text(note)
                                    .font(.manrope(13))
                                    .foregroundStyle(Palette.warmInk)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 10)
                            if index != update.notes.count - 1 {
                                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                            }
                        }
                    }
                }
                // Fixed, not `maxHeight` — this sheet has no explicit
                // height of its own (it sizes to content, unlike a full
                // page in `GlassPanelPage`), so `ThinScrollView`'s inner
                // `GeometryReader` never received a definite height to
                // resolve `maxHeight` against and collapsed to nothing.
                // A real release's notes are long enough in practice that
                // this reads the same as a cap; a short list just leaves
                // some empty space at the bottom of the box.
                .frame(height: 300)

                Rectangle().fill(Palette.warmRowBorder).frame(height: 1).padding(.top, 18).padding(.bottom, 20)
            }

            HStack {
                Button("Remind Me Later") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.manrope(13, .medium))
                    .foregroundStyle(Palette.warmInkSoft)
                    .disabled(app.updateInstallProgress != nil)

                Spacer()

                Button("Skip This Version") {
                    Settings.skippedUpdateVersion = update.version
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.manrope(13, .medium))
                .foregroundStyle(Palette.warmInkFaint)
                .disabled(app.updateInstallProgress != nil)

                Button {
                    Task { await app.installUpdate(update) }
                } label: {
                    HStack(spacing: 7) {
                        if let progress = app.updateInstallProgress {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text(progress)
                        } else {
                            Text("Update Now")
                        }
                    }
                    .lineLimit(1)
                    .font(.manrope(13, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(Palette.sunset, in: Capsule())
                    .shadow(color: Palette.sunset.opacity(0.28), radius: 12, y: 4)
                }
                .buttonStyle(PressScaleButtonStyle())
                .disabled(app.updateInstallProgress != nil)
                .padding(.leading, 10)
            }
        }
        .padding(32)
        .frame(width: 520)
        .background(Palette.panel)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let sizeBytes = update.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        if let publishedAt = update.publishedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            parts.append("Released \(formatter.string(from: publishedAt))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The same five-bar waveform glyph as the sidebar's logo badge
/// (`MurmurLogoBadge` in AppShell.swift, same bar heights scaled up for
/// this larger 56pt badge instead of that one's 34pt) — redrawn here
/// rather than shared, since it's a bespoke hand-drawn shape (not a
/// `MurmurIcon` case) and `private` scopes the original to that file.
private struct UpdateBadgeWaveform: View {
    private static let barHeights: [CGFloat] = [9, 17, 26, 17, 9]
    private static let scale: CGFloat = 26.0 / 24.0

    var body: some View {
        HStack(alignment: .center, spacing: 2 * Self.scale) {
            ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
                Rectangle()
                    .fill(.white)
                    .frame(width: 3 * Self.scale, height: height)
            }
        }
    }
}
