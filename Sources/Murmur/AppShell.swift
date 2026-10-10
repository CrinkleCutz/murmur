import SwiftUI

// MARK: - Page grouping
//
// The mockup organizes the flat page list into a capture/teach/shape/foot
// rail with a collapsible, accordion, pin-or-peek nav — replacing the real
// app's always-fully-expanded flat sidebar. Every existing `Page` case
// stays; this only adds where each one sits.

enum PageGroup: CaseIterable {
    case capture, teach, shape

    var title: String {
        switch self {
        case .capture: return ""
        case .teach: return "Personalize"
        case .shape: return "Shape"
        }
    }

    var icon: MurmurIcon {
        switch self {
        case .capture: return .home
        case .teach: return .fingerprint
        case .shape: return .wrench
        }
    }

    var items: [Page] {
        switch self {
        case .capture: return [.home, .insights, .ask, .notetaker, .scratchpad].filter(\.isAvailable)
        case .teach: return [.dictionary, .training, .style, .appProfiles]
        case .shape: return [.snippets, .templates, .transforms]
        }
    }
}

extension Page {
    /// False for a page the user can't reach in this build (Notetaker, while `Notetaker.isAvailable` is off) —
    /// it drops out of the sidebar and every navigation path below refuses it, so no link, notification or
    /// Help entry can land on it either.
    var isAvailable: Bool { self != .notetaker || Notetaker.isAvailable }

    var group: PageGroup {
        for g in PageGroup.allCases where g.items.contains(self) { return g }
        return .capture
    }

    /// True for pages that fill the pane and scroll internally, rather
    /// than being a document inside the shell's own ScrollView.
    var managesOwnScrolling: Bool {
        self == .ask || self == .home || self == .insights || self == .scratchpad
            || self == .notetaker
            || self == .dictionary || self == .training || self == .style
            || self == .appProfiles || self == .snippets || self == .templates
            || self == .transforms || self == .settings || self == .help || self == .legal
    }

    var murmurIcon: MurmurIcon {
        switch self {
        case .home: return .home
        case .insights: return .insights
        case .ask: return .ask
        case .notetaker: return .notetaker
        case .dictionary: return .dict
        case .training: return .profile
        case .snippets: return .snip
        case .style: return .style
        case .transforms: return .trans
        case .templates: return .tpl
        case .scratchpad: return .scratch
        case .appProfiles: return .apps
        case .settings: return .settings
        case .help: return .help
        case .legal: return .lock
        }
    }
}

// MARK: - Rail

/// The mockup's collapsible nav: icon-only at rest (72pt), full icon+label
/// while pinned or peeking (236pt). Peeking floats over content without
/// reflowing it — pinning actually reserves the width. Personalize and
/// Shape open independently (the mockup forced an accordion only because a
/// short browser window couldn't fit both; a real window can, and the rail
/// scrolls if it ever can't). Each also gets its own icon in the
/// fully-collapsed rail that pins the rail open and expands that group in
/// one action, so both groups' pages stay reachable with the rail closed,
/// not just discoverable once already pinned.
struct RailView: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @Binding var pinned: Bool
    @Binding var peeking: Bool
    @Binding var expandedGroups: Set<PageGroup>
    /// Called when a group is collapsed while one of its own pages is
    /// showing — the pane then falls back to that group's overview so the
    /// user isn't stranded on a page whose nav row just disappeared.
    var onGroupCollapsedWithActivePage: (PageGroup) -> Void = { _ in }

    static let collapsedWidth: CGFloat = 72
    // Main.dc.html's nav column is a fixed `width: 192px` — this predates
    // the "Main" redesign (was 236, from the old design system) and was
    // missed when everything else in the rail was re-measured against the
    // mockup, leaving the expanded rail visibly wider than intended.
    static let expandedWidth: CGFloat = 192

    private var expanded: Bool { pinned || peeking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(PageGroup.capture.items, id: \.self) { item in
                        railRow(item)
                    }
                    groupSection(.teach)
                    groupSection(.shape)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 1) {
                railRow(.settings)
                railRow(.help)
                railRow(.legal)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Unboxed per the "Main" redesign: transparent, not its own fill —
        // `appBody` paints one `homeGradient` behind the rail *and* the
        // pane together, so the rail reads as sitting directly on the same
        // continuous backdrop rather than a separately-colored strip.
    }

    // MARK: Top

    private var top: some View {
        HStack(spacing: 9) {
            HStack(spacing: 10) {
                // The mascot (the running app's own `.icns`) is retired in
                // this redesign in favor of Main.dc.html's own mark — a
                // plain sunset-orange badge with an abstract 5-bar waveform,
                // no character/face. `Resources/Murmur.icns` itself (the
                // Dock/Finder icon) is a separate asset this doesn't touch.
                MurmurLogoBadge()
                if expanded {
                    Text("Murmur")
                        .font(.manrope(20, .semibold))
                        .foregroundStyle(Palette.warmInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 22)
    }

    // MARK: Rows

    /// The old flat sidebar had a permanent "N permissions needed → Fix
    /// now" card — a big element that doesn't fit a 72pt collapsed rail.
    /// A dot on Settings preserves the same proactive, always-visible
    /// (not just once you happen to expand the rail) nudge instead.
    private var needsPermissions: Bool { !app.micAuthorized || !app.axTrusted }

    private func railRow(_ item: Page) -> some View {
        RailRow(
            item: item, selected: page == item, expanded: expanded,
            needsPermissions: item == .settings && needsPermissions,
            missingCount: [app.micAuthorized, app.axTrusted].filter { !$0 }.count
        ) { page = item }
    }

    private func groupSection(_ group: PageGroup) -> some View {
        let isOpen = expandedGroups.contains(group)
        return VStack(alignment: .leading, spacing: 0) {
            if expanded {
                GroupLabelButton(
                    title: group.title, isOpen: isOpen
                ) {
                    let collapsing = isOpen
                    withAnimation(.murmurEase()) {
                        if collapsing {
                            expandedGroups.remove(group)
                        } else {
                            expandedGroups.insert(group)
                        }
                    }
                    if collapsing, group.items.contains(page) {
                        onGroupCollapsedWithActivePage(group)
                    }
                }

                // Same left edge as the ungrouped rows and the group label —
                // the label above already shows the grouping; a 4pt nudge
                // only read as a misalignment.
                if isOpen {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group.items, id: \.self) { item in railRow(item) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                // Collapsed: one icon per group. Clicking pins the rail
                // open and expands straight into that group, so every
                // page nested inside Personalize/Shape is still one click
                // away even with the rail fully closed.
                Button {
                    withAnimation(.murmurEase()) {
                        pinned = true
                        expandedGroups.insert(group)
                    }
                } label: {
                    HStack(spacing: 12) {
                        MurmurIconView(icon: group.icon).frame(width: 17, height: 17)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.warmInk)
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(group.title)
            }
        }
        .padding(.top, expanded ? 8 : 0)
    }
}

/// Main.dc.html's logo mark: a sunset-orange, 10pt-radius, 34×34 badge
/// holding a plain 5-bar waveform glyph — five simple rects, not worth
/// routing through the `MurmurIcon`/SVG-path system built for the app's
/// outline icon set. Bar heights (6/12/18/12/6) and the orange fill are
/// copied directly from the mockup's own `<svg>`, scaled down from its
/// 24-unit viewBox to the 15pt it's actually rendered at there — the icon
/// sits smaller than the badge with visible padding around it, not
/// stretched edge-to-edge.
private struct MurmurLogoBadge: View {
    private static let barHeights: [CGFloat] = [6, 12, 18, 12, 6]
    private static let scale: CGFloat = 15.0 / 24.0

    var body: some View {
        HStack(alignment: .center, spacing: 2 * Self.scale) {
            ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
                Rectangle()
                    .fill(.white)
                    .frame(width: 3 * Self.scale, height: height * Self.scale)
            }
        }
        .frame(width: 34, height: 34)
        .background(Palette.sunset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 9, y: 8)
    }
}


// MARK: - App shell
//
// `.proto-frame` + `.titlebar` + `.app-body`: the whole window is one
// rounded panel; the titlebar spans its full width, and the rail sits
// below it alongside the content — not overlapping it.

struct AppShellRoot: View {
    @ObservedObject var app: AppDelegate
    @State private var page: Page = .home
    @State private var pinned = Settings.railPinned
    @State private var peeking = false
    @State private var expandedGroups: Set<PageGroup> = {
        var groups: Set<PageGroup> = []
        if Settings.personaliseExpanded { groups.insert(.teach) }
        if Settings.toolsExpanded { groups.insert(.shape) }
        return groups
    }()
    @State private var peekCloseWork: DispatchWorkItem?
    /// Drives `.pane-swap`: a 150ms fade + 3pt rise whenever the page changes.
    @State private var paneSwapping = false
    /// When set, the pane shows a group overview rather than a page.
    @State private var overviewGroup: PageGroup?
    @State private var showingNotifications = false

    private let permissionTimer = Timer.publish(
        every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        // No simulated frame here. The mockup's `.proto-frame` — rounded
        // corners, border, drop shadow, and the gray backdrop around it —
        // exists only because a web page has to *draw* a fake app window.
        // In the real app the macOS window IS that frame, so drawing our
        // own inside it produces a visible window-within-a-window.
        VStack(spacing: 0) {
            titlebar
            Rectangle().fill(Palette.border).frame(height: 1)
            appBody
        }
        .background(Palette.panel)
        .ignoresSafeArea()
        .onReceive(permissionTimer) { _ in app.refreshPermissions() }
        .onChange(of: pinned) { _, newValue in Settings.railPinned = newValue }
        .onChange(of: expandedGroups) { _, newValue in
            Settings.personaliseExpanded = newValue.contains(.teach)
            Settings.toolsExpanded = newValue.contains(.shape)
        }
        // Outside triggers — the App Profile discovery notification, and
        // now the nav bar HUD's quick-action popovers — jump the shown page
        // directly, unlike `pendingTemplateText`, which a page that's
        // already visible picks up itself. Also expand whichever group
        // actually contains the target page (via `Page.group`, not a
        // hardcoded one — this now routes pages from more than one group),
        // since a collapsed rail would land on the page with no visible way
        // back to it.
        .onChange(of: app.pendingNavigateToPage) { _, newValue in
            guard let newValue else { return }
            guard newValue.isAvailable else {
                app.pendingNavigateToPage = nil
                return
            }
            page = newValue
            expandedGroups.insert(newValue.group)
            app.pendingNavigateToPage = nil
        }
        // `.sheet(item:)` clears `app.availableUpdate` back to nil on its
        // own however the sheet closes (a button's own `dismiss()`,
        // Escape, clicking outside) — none of the three actions need to
        // touch it themselves.
        .sheet(item: $app.availableUpdate) { update in
            SoftwareUpdateSheet(update: update, app: app)
        }
    }

    /// `.titlebar` — 44px tall, shell-colored, hairline bottom border,
    /// spanning the full window width above both rail and content.
    private var titlebar: some View {
        HStack(spacing: 7) {
            // Space for the real macOS traffic lights.
            Color.clear.frame(width: 62, height: 1)
            // Used to also show a StatusPill here — removed as a duplicate
            // of Home's capture zone, which now shows the same
            // Ready/Listening/Working status at far more prominent scale.
            // The floating StatusHUD still covers dictation into other
            // apps regardless of which page is showing.
            //
            // Drives the same `pinned` state the rail itself reads — this
            // is now the one control for it (the rail's own in-line caret
            // button was removed as redundant once this shipped). No
            // tooltip: a sidebar-toggle glyph next to the traffic lights
            // is a standard enough macOS convention (Mail, Notes, Xcode)
            // not to need one.
            IconButton(icon: .sidebar) {
                withAnimation(.murmurEase()) { pinned.toggle() }
            }
            Spacer(minLength: 12)
            if let error = app.lastError, app.uiState == .idle {
                Text(error)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
            } else if let notice = app.secureInputNotice, app.uiState == .idle {
                Text(notice)
                    .font(.manrope(11.5))
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
            }
            // Used to navigate straight to Help — the tooltip even still
            // said "Help" — instead of showing anything notification-
            // shaped. Now backed by `NotificationLog`, the same record
            // the App Profile suggestion and update-available checks
            // already write to regardless of whether the user granted
            // system notification permission.
            IconButton(icon: .bell, help: "Notifications") { showingNotifications = true }
                .popover(isPresented: $showingNotifications, arrowEdge: .bottom) {
                    NotificationsPopover { entry in
                        showingNotifications = false
                        switch entry.kind {
                        case .appProfileSuggestion:
                            app.pendingNavigateToPage = .appProfiles
                        case .updateAvailable:
                            break // Re-shows itself via the existing sheet binding if still set.
                        case .learnedFromEdit:
                            app.pendingNavigateToPage = .training
                        }
                    }
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        // Fixed, a shade darker than `homeGradient`'s own leading stop —
        // not `Palette.shell`'s neutral gray, which read as a disconnected
        // bar sitting on top of the sage-tinted body instead of a related
        // surface; matching the gradient's stop exactly, in turn, read as
        // *too* related — no visible seam between the titlebar and the
        // body at all.
        .background(Palette.homeTitlebar)
    }

    /// The bell's own content — a short, real history rather than a
    /// generic empty bell. No mockup artboard covers this specifically
    /// (the design canvas has no "Notifications" page), so this borrows
    /// this redesign's own established row/divider/empty-state
    /// conventions rather than inventing a new visual language for one
    /// small popover.
    private struct NotificationsPopover: View {
        let onSelect: (LoggedNotification) -> Void
        @State private var entries: [LoggedNotification] = NotificationLog.load()
        @State private var hoveredID: UUID?
        /// The rows' own real, unconstrained height, measured directly
        /// off `rows` below (see `PopoverContentHeightKey`) rather than
        /// guessed from a per-row estimate — a flat "~1 line of message"
        /// guess read as cramped the moment a message actually wrapped
        /// to 2-3 lines.
        @State private var measuredHeight: CGFloat = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("NOTIFICATIONS")
                    .font(.manrope(10.5, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.warmInkFaint)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                if entries.isEmpty {
                    Text("Nothing yet — Murmur will let you know about things "
                         + "like an app profile suggestion or a new version.")
                        .font(.manrope(12))
                        .foregroundStyle(Palette.warmInkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                        .frame(width: 260, alignment: .leading)
                } else {
                    ThinScrollView {
                        // A `ScrollView`'s content always lays out at its
                        // own natural height regardless of the viewport
                        // constrained below — otherwise there'd be
                        // nothing to scroll — so measuring the visible
                        // copy directly (no hidden duplicate needed)
                        // still reports the content's true, unclamped
                        // height, not the capped one.
                        rows
                            .background(GeometryReader { proxy in
                                Color.clear.preference(
                                    key: PopoverContentHeightKey.self,
                                    value: proxy.size.height)
                            })
                    }
                    // Fixed, not `maxHeight` — a popover sizes to its
                    // content just like a content-sized sheet does, so
                    // `ThinScrollView`'s inner `GeometryReader` never gets
                    // a definite height to resolve a flexible max against
                    // and collapses to nothing (see
                    // SoftwareUpdateView.swift's own note on the same
                    // bug). `measuredHeight` is the real content height,
                    // so a short list isn't stretched and a long one
                    // still caps and scrolls.
                    .frame(width: 300)
                    .frame(height: min(measuredHeight, 320))
                    .onPreferenceChange(PopoverContentHeightKey.self) { measuredHeight = $0 }
                }
            }
            .background(Palette.panel)
        }

        private var rows: some View {
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    Button { onSelect(entry) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(.manrope(12.5, .semibold))
                                .foregroundStyle(Palette.warmInk)
                            Text(entry.message)
                                .font(.manrope(11.5))
                                .foregroundStyle(Palette.warmInkSoft)
                                .lineSpacing(2)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(hoveredID == entry.id ? Palette.warmRowBorder : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in hoveredID = inside ? entry.id : nil }
                    if entry.id != entries.last?.id {
                        Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    private struct PopoverContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private var appBody: some View {
        HStack(spacing: 0) {
            // The slot reserves layout width; the rail itself overlays it
            // so a hover-peek floats above the content without reflowing.
            Color.clear
                .frame(width: pinned ? RailView.expandedWidth : RailView.collapsedWidth)
            pane
        }
        // One gradient instance spanning the rail *and* the pane, not two
        // separately-scaled copies (rail used to paint its own). A
        // `LinearGradient`'s start/end points are resolved as fractions of
        // whatever view draws it — painted once here and left transparent
        // in the rail, the sage-to-cream backdrop is continuous behind
        // both; painted twice, the same gradient stretches over two
        // different-width boxes and comes out at two different angles,
        // showing up as a visible seam right at the rail's edge.
        .background(Palette.homeGradient)
        .overlay(alignment: .topLeading) {
            RailView(
                app: app, page: pageBinding, pinned: $pinned, peeking: $peeking,
                expandedGroups: $expandedGroups,
                onGroupCollapsedWithActivePage: { group in
                    withAnimation(.murmurEase(0.15)) { overviewGroup = group }
                })
                .frame(width: (pinned || peeking) ? RailView.expandedWidth : RailView.collapsedWidth)
                .shadow(color: .black.opacity(peeking && !pinned ? 0.26 : 0),
                        radius: peeking && !pinned ? 16 : 0, x: 7)
                .animation(.murmurEase(0.22), value: pinned || peeking)
                .onHover { inside in
                    guard !pinned else { return }
                    peekCloseWork?.cancel()
                    if inside {
                        peeking = true
                    } else {
                        let work = DispatchWorkItem { peeking = false }
                        peekCloseWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
                    }
                }
        }
    }

    /// `.pane` — 32px top / 36px sides / 40px bottom, with the swap
    /// transition applied on every page change. Pages on the "Main"
    /// redesign's `GlassPanelPage` shell are the exception: their own
    /// canvas paints edge-to-edge (the sage-to-cream backdrop behind the
    /// glass panel), so they supply their own matching padding internally
    /// instead of taking the generic inset here. Extend this list as more
    /// pages adopt `GlassPanelPage`.
    private static let glassPanelPages: Set<Page> = [
        .home, .insights, .scratchpad, .ask, .notetaker, .dictionary, .training, .style,
        .appProfiles, .snippets, .templates, .transforms, .settings, .help, .legal,
    ]

    private var pane: some View {
        Group {
            if page.managesOwnScrolling {
                Group {
                    if Self.glassPanelPages.contains(page) {
                        pageContent
                    } else {
                        pageContent
                            .padding(.horizontal, 36)
                            .padding(.top, 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    pageContent
                        .padding(.horizontal, 36)
                        .padding(.top, 32)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .opacity(paneSwapping ? 0 : 1)
        .offset(y: paneSwapping ? 3 : 0)
    }

    /// Navigating fades the pane out, swaps, and fades back in — the
    /// mockup's `.pane-swap`, which the app was missing entirely.
    private var pageBinding: Binding<Page> {
        Binding(get: { page }, set: { select($0) })
    }

    private func select(_ newPage: Page) {
        guard newPage.isAvailable, newPage != page || overviewGroup != nil else { return }
        overviewGroup = nil
        withAnimation(.murmurEase(0.15)) { paneSwapping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            page = newPage
            withAnimation(.murmurEase(0.15)) { paneSwapping = false }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if let overviewGroup {
            GroupOverview(group: overviewGroup) { select($0) }
        } else {
            pageBody
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case .home: HomePage(app: app, page: pageBinding)
        case .insights: InsightsPage(app: app)
        case .ask: AskPage(app: app)
        case .notetaker: NotetakerPage(app: app)
        case .dictionary: DictionaryPage(page: pageBinding)
        case .training: TrainingPage(app: app, page: pageBinding)
        case .snippets: SnippetsPage(page: pageBinding)
        case .style: StylePage(app: app, page: pageBinding)
        case .transforms: TransformsPage(app: app, page: pageBinding)
        case .templates: TemplatesPage(app: app, page: pageBinding)
        case .appProfiles: AppProfilesPage(app: app, page: pageBinding)
        case .scratchpad: ScratchpadPage(app: app)
        case .settings: SettingsPage(app: app)
        case .help: HelpPage(app: app, page: pageBinding)
        case .legal: LegalPage(page: pageBinding)
        }
    }
}


/// `.rail-item` — 34pt tall, 17pt icon, 12pt gap, with the hover wash and
/// press-scale the design specifies (the app had neither).
private struct RailRow: View {
    let item: Page
    let selected: Bool
    let expanded: Bool
    let needsPermissions: Bool
    let missingCount: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    // MurmurIconView's stroke width is a fixed fraction of
                    // its rendered size (`nativeStrokeWidth * scale` in
                    // MurmurIcons.swift), not a constant point value — so
                    // sizing the icon up here is what thickens its stroke
                    // too, in the same move, rather than a separate lever.
                    MurmurIconView(icon: item.murmurIcon)
                        .frame(width: 16, height: 16)
                    if needsPermissions {
                        Circle()
                            .fill(Palette.danger)
                            .frame(width: 6, height: 6)
                            .offset(x: 5, y: -4)
                    }
                }
                if expanded {
                    Text(item.label)
                        .font(.manrope(15, .medium))
                        .lineLimit(1)
                    if needsPermissions {
                        Text("\(missingCount)")
                            .font(.manrope(10, .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Palette.danger, in: Circle())
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? .white : Palette.warmInk)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(selected ? Palette.navActivePill
                          : (hovering ? Palette.hoverWash : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.murmurEase(0.13), value: hovering)
        .help(expanded ? "" : item.label)
    }
}


/// The mockup's `teachOverview` / `shapeOverview` panes: shown when a rail
/// group is collapsed while one of its pages was open, so the pane always
/// has somewhere sensible to land.
struct GroupOverview: View {
    let group: PageGroup
    let select: (Page) -> Void

    private var subtitle: String {
        switch group {
        case .teach:
            return "Dictionary, Voice Profile, and Style — set once, applies to every future dictation."
        case .shape:
            return "Snippets, Templates, and Transforms — the mechanisms that reshape or expand what you said."
        case .capture:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: group.title, subtitle: subtitle)
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element) { index, item in
                    OverviewRow(item: item) { select(item) }
                    if index != group.items.count - 1 {
                        Rectangle().fill(Palette.border).frame(height: 1)
                    }
                }
            }
        }
    }
}

private struct OverviewRow: View {
    let item: Page
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MurmurIconView(icon: item.murmurIcon)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Palette.accentText)
                Text(item.label)
                    .font(.manrope(13, .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                MurmurIconView(icon: .arrowRight)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Palette.inkFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(hovering ? Palette.cardHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.murmurEase(0.12), value: hovering)
    }
}

/// `.rail-group-label` — the Personalize / Shape disclosure header.
///
/// The design draws this as a 22pt strip, which is a small target for a
/// mouse; worse, a bare `HStack` with a `Spacer` only hit-tests where it
/// actually painted glyphs, so clicks landing in the gap between the label
/// and its chevron did nothing at all. The strip keeps its 22pt look, but
/// the button underneath is 32pt tall, spans the full rail width, and is a
/// solid hit rectangle — plus a hover wash so it reads as clickable.
private struct GroupLabelButton: View {
    let title: String
    let isOpen: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.manrope(10.5, .bold))
                    .tracking(1.05)
                Spacer(minLength: 0)
                MurmurIconView(icon: .caret)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .foregroundStyle(Palette.warmInkFaint.opacity(hovering ? 1 : 0.75))
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(hovering ? Palette.hoverWash : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.murmurEase(0.13), value: hovering)
    }
}
