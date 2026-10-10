import AppKit
import SwiftUI

// MARK: - Settings' building blocks
//
// The pieces every Settings tab is made of, in one place, so a tab added later (the License tab was the first) is
// built from the same parts as the rest instead of from look-alikes that drift: a tab bar, small section labels,
// white cards and the rows inside them — the same anatomy as every other page.

/// Settings' tabs, in order. License only shows in an official release build, or in a build from source while its
/// license preview is on.
enum SettingsTab: String, CaseIterable {
    case general, dictation, notetaker, license

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .notetaker: "Notetaker"
        case .license: "License"
        }
    }
}

/// The small uppercase label above a card ("PERMISSIONS"), with an optional quiet note on the right.
struct SettingsSectionLabel: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(title)
                .font(.manrope(10, .semibold))
                .kerning(0.9)
                .foregroundStyle(Palette.warmInkSoft)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.warmInkFaint)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 10)
    }
}

/// A white card of rows — the same fill and radius as every other page's cards, no border, no shadow.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// The page title and the line under it.
struct SettingsPageHeader: View {
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.manrope(22, .medium))
                .tracking(-0.33)
                .foregroundStyle(Palette.warmInk)
            Text(subtitle)
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A live state shown under a row's name — "Loaded", or "Downloading" with a spinner.
enum SettingsRowStatus: Equatable {
    case done(String)
    case working(String)
}

/// One setting: its name, a plain line on what it does, and its control on the right; a hairline below unless it's
/// the card's last row. Optionally a live status under the name, a line in the accent colour when something needs
/// attention (the License tab's "couldn't reach the licensing server lately"), and a footer for extra actions.
struct SettingsFieldRow<Control: View, Footer: View>: View {
    let label: String
    /// A small outlined word after the name — "NEW" on a setting you haven't tried yet.
    let badge: String?
    let detail: String?
    let status: SettingsRowStatus?
    let warning: String?
    let isLast: Bool
    let control: () -> Control
    let footer: () -> Footer

    init(label: String, badge: String? = nil, detail: String? = nil, status: SettingsRowStatus? = nil,
         warning: String? = nil, isLast: Bool = false, @ViewBuilder control: @escaping () -> Control,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.label = label
        self.badge = badge
        self.detail = detail
        self.status = status
        self.warning = warning
        self.isLast = isLast
        self.control = control
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.manrope(13, .semibold))
                            .foregroundStyle(Palette.warmInk)
                        if let badge {
                            Text(badge)
                                .font(.manrope(9.5, .bold))
                                .kerning(0.6)
                                .foregroundStyle(Palette.sunsetDeep)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Palette.sunset, lineWidth: 1))
                        }
                    }
                    if let status {
                        HStack(spacing: 5) {
                            switch status {
                            case .done:
                                MurmurIconView(icon: .check).frame(width: 11, height: 11)
                            case .working:
                                ProgressView().controlSize(.mini)
                            }
                            switch status {
                            case .done(let text), .working(let text):
                                Text(text).font(.manrope(12))
                            }
                        }
                        .foregroundStyle(Palette.warmInkSoft)
                    }
                    if let detail {
                        Text(detail)
                            .font(.manrope(12))
                            .foregroundStyle(Palette.warmInkSoft)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let warning {
                        Text(warning)
                            .font(.manrope(12, .medium))
                            .foregroundStyle(Palette.sunsetDeep)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    footer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control()
            }
            .padding(.vertical, 15)
            if !isLast {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
        }
    }
}

extension SettingsFieldRow where Footer == EmptyView {
    init(label: String, badge: String? = nil, detail: String? = nil, status: SettingsRowStatus? = nil,
         warning: String? = nil, isLast: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.init(label: label, badge: badge, detail: detail, status: status, warning: warning, isLast: isLast,
                  control: control, footer: { EmptyView() })
    }
}

/// A settled, good state — "Granted", "Up to date", "Active on this Mac": a quiet grey check and a few words. The
/// normal state gets no accent at all, so the orange left on the page is only ever something for you to do.
struct SettingsStatusLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            MurmurIconView(icon: .check).frame(width: 13, height: 13)
            Text(title).font(.manrope(12, .medium))
        }
        .foregroundStyle(Palette.warmInkSoft)
        .fixedSize()
    }
}

/// The one thing on the page that should draw the eye — "Update available", "Buy Murmur": a filled sunset pill inset
/// in a white capsule with a `warmRowBorder` stroke. Wrap it in a `Button` with `.plain` style to make it act.
struct SettingsAttentionPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.manrope(12, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Palette.sunset))
            .padding(2)
            .background(Palette.panel, in: Capsule())
            .overlay(Capsule().stroke(Palette.warmRowBorder, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
    }
}

/// `GhostButtonStyle` reskinned in warm tokens — the page's secondary action ("Open Settings", "Connect", "Activate").
struct WarmGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(11.5, .semibold))
            .foregroundStyle(Palette.sunsetDeep)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Palette.sunsetSoft, in: RoundedRectangle(cornerRadius: Radius.sm))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// A text box in the same field style as the page's dropdowns (`AccentFieldSelect`): white, a hairline that turns
/// sunset while it's being typed in.
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 200
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        // The placeholder is drawn here, faint, rather than left to the text field: AppKit draws its own placeholder in
        // the field's text colour, which read as a key already typed in.
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(Palette.warmInkFainter)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.warmInk)
                .focused($focused)
                .onSubmit(onSubmit)
        }
        .font(.manrope(12, .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: width)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .stroke(focused ? Palette.sunset : Palette.warmRowBorder, lineWidth: focused ? 1.5 : 1))
    }
}

// MARK: - General: the app itself

/// The top of General: which Murmur this is — by name only, no mascot — and whether there's a newer one.
///
/// A build from source says so — it's free and needs no license, which is also why it has no License tab — and keeps
/// its GitHub updater (`AppDelegate.checkForUpdates`), whose sheet opens by itself when it finds a release. An official
/// release build updates through Sparkle, and this row is where that shows: the License tab only says which updates
/// the license includes.
struct SoftwareStatusRow: View {
    enum Status: Equatable {
        /// A newer version this Mac can install.
        case updateAvailable
        /// A newer version exists, but the license doesn't include it (the License tab offers to renew).
        case newerNotIncluded
        case upToDate
        /// Not checked yet this session (release builds; Sparkle checks on its own schedule).
        case unknown
    }

    let version: String
    let isSourceBuild: Bool
    let status: Status
    /// Update available: open the updater. nil for a source build, whose update sheet opens by itself.
    var install: (() -> Void)?
    var showLicense: () -> Void = {}
    var checkNow: () -> Void = {}
    var isLast = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Murmur")
                        .font(.manrope(15, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    Text(isSourceBuild ? "Version \(version) · built from source — free, no license needed"
                                       : "Version \(version)")
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                statusControl
            }
            .padding(.vertical, 18)
            if !isLast {
                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
            }
        }
    }

    @ViewBuilder private var statusControl: some View {
        switch status {
        case .updateAvailable:
            if let install {
                Button(action: install) { SettingsAttentionPill(title: "Update available") }
                    .buttonStyle(.plain)
            } else {
                SettingsAttentionPill(title: "Update available")
            }
        case .newerNotIncluded:
            Button("See what your license includes", action: showLicense)
                .buttonStyle(WarmGhostButtonStyle())
        case .upToDate:
            SettingsStatusLabel(title: "Up to date")
        case .unknown:
            Button("Check for updates", action: checkNow)
                .buttonStyle(WarmGhostButtonStyle())
        }
    }
}
