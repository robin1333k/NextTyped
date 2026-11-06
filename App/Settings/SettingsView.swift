import AppKit
import NextTypedCore
import SwiftUI

/// The Settings window: a fixed sidebar of sections on the sidebar material, and the selected pane on the
/// right with its title in the titlebar strip. Sections whose backend does not exist are not stubbed.
///
/// A hand-rolled `HStack` (not `NavigationSplitView`) on purpose: the split view injects an automatic
/// sidebar-collapse toolbar button and a top toolbar inset that push the traffic lights out of place.
/// The sidebar is fixed and non-collapsible, with the window controls floating over it, which
/// `SettingsWindowConfigurator` sets up (transparent full-size titlebar). The shell therefore ignores the
/// top safe area and draws its own 28 pt strip: the traffic lights over the sidebar, the pane title over
/// the detail column. That strip stays draggable because the window moves by its background.
struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    /// Shared (not `@State`) so a deep link can choose the pane while the window is closed or open.
    @ObservedObject private var navigation = SettingsNavigation.shared
    /// The same Accessibility state the Setup pane reads; feeds the Setup row's badge.
    @StateObject private var permissions = PermissionsModel()
    /// Set only by the snapshot renderer (`SettingsSnapshotRenderer`) to open any pane directly,
    /// without touching the shared selection. A sidebar selection clears it.
    @State private var pinned: SettingsSection?
    @FocusState private var sidebarFocused: Bool
    private var selection: SettingsSection { pinned ?? navigation.selection }

    /// Height of the titlebar strip: the traffic lights sit in it over the sidebar, the pane title over
    /// the detail column.
    static let titlebarHeight: CGFloat = 28

    init(initialSelection: SettingsSection? = nil) {
        _pinned = State(initialValue: initialSelection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                paneTitle
                detail
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 480, idealHeight: 560)
        .background(SettingsWindowConfigurator())
    }

    /// The list selection. Writing it is a user choice, so it also drops the renderer's pin.
    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(
            get: { selection },
            set: { newValue in
                guard let newValue else { return }
                pinned = nil
                navigation.selection = newValue
            })
    }

    private var setupBadge: Int? {
        SetupAttention.badgeCount(accessibilityMissing: !permissions.hasAccessibility,
                                  modelFailed: coordinator.modelLoadState.isFailed)
    }

    /// True in the snapshot renderer. Its offscreen window is never key, and there the list's own
    /// selection highlight draws as a black bar with an invisible title. The renderer therefore turns the
    /// list selection off and the row draws an accent highlight itself; the live window never does.
    private var drawsRendererHighlight: Bool {
#if DEBUG
        SettingsSnapshotRenderer.isRendering
#else
        false
#endif
    }

    private var sidebar: some View {
        List(selection: drawsRendererHighlight ? .constant(nil) : sidebarSelection) {
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, badge: section == .setup ? setupBadge : nil,
                           rendererHighlight: drawsRendererHighlight && section == selection)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 28)
        .focused($sidebarFocused)
        // Clear the window controls (full-size content titlebar), 30 pt as before.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 30) }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
        // Arrow keys move the selection only while the list has focus. Give it focus on open, as
        // System Settings does with its sidebar, so Down and Up work without a click first.
        .onAppear { sidebarFocused = true }
    }

    /// The selected pane's name in the titlebar strip, leading-aligned with the grouped form's sections.
    private var paneTitle: some View {
        Text(selection.title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, minHeight: Self.titlebarHeight, maxHeight: Self.titlebarHeight,
                   alignment: .leading)
            .padding(.horizontal, 30)   // the grouped form insets its section headers 30 pt
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .setup:   SetupSettingsView()
        case .general: GeneralSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .privacy: PrivacySettingsView()
        case .apps:       AppsSettingsView()
        case .statistics: StatisticsSettingsView()
        case .about:      AboutSettingsView()
        }
    }
}

/// The Settings sidebar selection, shared so `nexttyped://settings/<pane>` can set it. The value
/// outlives the window, which is what makes a bare `nexttyped://settings` open the last pane.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selection: SettingsSection = .setup
    private init() {}
}

extension SettingsSection {
    init(_ pane: DeepLinkPane) {
        switch pane {
        case .setup: self = .setup
        case .general: self = .general
        case .shortcuts: self = .shortcuts
        case .privacy: self = .privacy
        case .apps: self = .apps
        case .statistics: self = .statistics
        case .about: self = .about
        }
    }
}

/// The sidebar sections, in sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case setup, general, shortcuts, privacy, apps, statistics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup:   "Setup"
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .apps:       "Apps"
        case .statistics: "Statistics"
        case .about:      "About"
        }
    }

    /// The tile table. Red is reserved for errors and destructive actions, so no tile uses it.
    var symbol: String {
        switch self {
        case .setup:   "checkmark.shield"
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .privacy: "hand.raised.fill"
        case .apps:       "square.grid.2x2"
        case .statistics: "chart.bar.fill"
        case .about:      "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .setup:   .orange
        case .general: .gray
        case .shortcuts: Self.grayBlue
        case .privacy: .blue
        case .apps:       .indigo
        case .statistics: .purple
        case .about:      .gray
        }
    }

    /// The gray-blue tile: the system gray blended with the system blue.
    private static let grayBlue = Color(nsColor: NSColor.systemGray.blended(withFraction: 0.45, of: .systemBlue)
                                        ?? .systemGray)
}

/// A sidebar row: a 20 pt tinted rounded-square tile, the section title and, on Setup, the count of
/// unmet requirements. The list draws the selection highlight and the selected accessibility trait.
private struct SidebarRow: View {
    let section: SettingsSection
    let badge: Int?
    /// Snapshot renderer only: draw the selection highlight the offscreen list cannot.
    var rendererHighlight = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(section.tint.gradient))
                .accessibilityHidden(true)
            Text(section.title)
                .foregroundStyle(rendererHighlight ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
            Spacer(minLength: 0)
            if let badge {
                SidebarCountBadge(count: badge)
            }
        }
        .frame(height: 28)
        .background {
            if rendererHighlight {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor)
                    .padding(.horizontal, -8)
            }
        }
    }
}

/// The red count capsule System Settings puts on a row that needs the user (a pending update). Red is
/// right here: each count is an unmet requirement.
private struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(.red))
            .accessibilityLabel(count == 1 ? "1 requirement unmet" : "\(count) requirements unmet")
    }
}

/// Reaches the hosting `NSWindow` to give the Settings window a chrome with a transparent,
/// full-size-content titlebar with a hidden title, so the sidebar runs to the top edge and the window
/// controls float over it (instead of the default centered title + split-view toggle button).
// Not `private`: `MenuBarContent` calls `Coordinator.frontFromMenu()` after `openSettings()`,
// which is the only trigger that fires on an open the window itself never notices.
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ nsView: NSView, context: Context) {
#if DEBUG
        // The snapshot renderer's offscreen window must never be fronted or activated.
        if SettingsSnapshotRenderer.isRendering { return }
#endif
        // `window` is nil until the view is in the hierarchy — defer to the next runloop. Idempotent, so
        // re-applying on every SwiftUI update (e.g. selection change) is harmless.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            context.coordinator.attach(to: window)
        }
    }

    /// Owns the front-most activation, which must fire **per window appearance** rather than per
    /// SwiftUI update — hence a coordinator with a key-window observation instead of a line in
    /// `updateNSView` (that runs on every selection change and would re-steal focus while the user
    /// works elsewhere).
    @MainActor
    final class Coordinator {
        private weak var observed: NSWindow?
        private var keyObserver: NSObjectProtocol?

        /// The Settings window, once SwiftUI has built it. The menu path needs a handle on it and
        /// `SettingsLink`/`openSettings` return none, so the configurator — which is inside that very
        /// window — records it here as it goes past.
        static weak var settingsWindow: NSWindow?

        /// Open Settings and land it in front **in the same runloop turn**, rather than ordering it in
        /// and correcting afterwards.
        ///
        /// Two defects were fixed here in sequence on 2026-08-31, and the second only became visible
        /// once the first was gone:
        ///
        /// 1. `SettingsLink` opens the scene and returns **nothing**, so every front attempt had to
        ///    live inside the window, keyed off `didBecomeKeyNotification`. On a reopen the singleton
        ///    window is the same object — `attach` returns early — so that notification was the only
        ///    trigger left, and it does not arrive on exactly the opens that fail: another app keeps
        ///    the foreground, our window is ordered in behind it and never becomes key. Measured
        ///    against the window server's z-order: Settings behind Finder, three opens in a row, and
        ///    **no `[settings]` line at all** — an open that left no trace rather than a wrong verdict.
        ///
        /// 2. Fixing that by fronting *after* `openSettings()` made the window appear in the wrong
        ///    place and then jump forward — visible, and reported as such. The order is the whole
        ///    point: **take the foreground first, then let the window be ordered in.** An app that is
        ///    already active has its new window placed on top by the window server, so there is no
        ///    wrong position to correct.
        ///
        /// Hence: activate, order the window we already have (the reopen case, which is every open
        /// after the first), *then* ask SwiftUI to open. The deferred passes exist only for the very
        /// first open, where the scene does not exist yet and there is nothing to order — they are
        /// idempotent, and on a reopen they find the window already in front and change nothing.
        ///
        /// One verification pass runs afterwards, so an open still produces exactly one `[settings]`
        /// line however many ordering attempts it took.
        @MainActor
        static func openAndFront(_ open: () -> Void) {
            NSApp.activate()
            if let window = settingsWindow { place(window) }
            open()
            for delay in [0.0, 0.12] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let window = settingsWindow, window.isVisible else { return }
                    place(window)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let window = settingsWindow, window.isVisible else { return }
                verify(window)
            }
        }

        /// The ordering half: cheap, idempotent, and silent. Separated from `verify` so the ladder can
        /// run several times per open without writing several lines about it.
        static func place(_ window: NSWindow) {
            // Show up where the cursor is, not where this singleton was last opened.
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }

        /// Start observing (and activate for) the window we just got.
        func attach(to window: NSWindow) {
            Self.settingsWindow = window
            guard observed !== window else { return }
            observed = window
            keyObserver.map(NotificationCenter.default.removeObserver)
            // A reopen reuses the same `NSWindow`, so a one-shot activation would only fix the first
            // open. SwiftUI makes the window key when it re-orders it in — riding that gets the app
            // activated on every reopen too. (KVO on `isVisible` would be the more direct signal but
            // it is main-actor-isolated, so no key path can be formed under Swift 6.)
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { Self.bringToFront(window) }
            }
            Self.bringToFront(window)
        }

        // No `deinit` cleanup: the Settings window is a singleton that outlives the coordinator, and a
        // nonisolated deinit cannot touch the main-actor-isolated observer under Swift 6. Re-attaching
        // removes the previous registration, so at most one is ever live.

        /// Read the four facts that together decide whether the user can see the window. Kept next to
        /// the AppKit calls because reading them is the untestable half; *judging* them is
        /// `WindowFronting` in Core, so the proposition itself is pinned by tests.
        private static func probe(_ window: NSWindow) -> WindowFrontingState {
            WindowFrontingState(
                appIsActive: NSApp.isActive,
                windowIsVisible: window.isVisible,
                windowIsKey: window.isKeyWindow,
                windowIsUnoccluded: window.occlusionState.contains(.visible),
                windowIsAboveOtherApps: appAbove(window) == nil)
        }

        /// The owner of the first **other application's** window drawn above ours, or `nil` when there
        /// is none — the fifth fact of `WindowFrontingState`, and the only one that can see a partial
        /// cover.
        ///
        /// `occlusionState` reports *at least part of the window is on screen*, so a window with one
        /// visible corner is `.visible` and the four older facts all held while the user was looking at
        /// Finder (2026-08-31). The window server's own z-order is the thing that was never asked.
        ///
        /// `.optionOnScreenAboveWindow` lists exactly the windows above ours, and the filter is
        /// narrow on purpose:
        ///
        /// - **layer 0 only.** The menu bar, the Dock and every overlay panel — our own ghost included
        ///   — live above the normal level by design; counting them would report `behind-app` on every
        ///   single open.
        /// - **another PID.** Our own windows above the Settings window are not this defect.
        ///
        /// No permission is involved: window number, layer and owner are public list attributes.
        /// `kCGWindowName` is the one Screen Recording gates, and it is deliberately not read.
        private static func appAbove(_ window: NSWindow) -> String? {
            let id = CGWindowID(window.windowNumber)
            guard window.windowNumber > 0,
                  let list = CGWindowListCopyWindowInfo(
                    [.optionOnScreenAboveWindow, .excludeDesktopElements], id) as? [[String: Any]]
            else { return nil }
            let mine = ProcessInfo.processInfo.processIdentifier
            for info in list {
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != mine
                else { continue }
                return (info[kCGWindowOwnerName as String] as? String) ?? "pid \(pid)"
            }
            return nil
        }

        #if DEBUG
        private static func report(_ verdict: WindowFrontingVerdict,
                                   _ state: WindowFrontingState,
                                   escalated: Bool,
                                   window: NSWindow) {
            // `above=` names the offender rather than reporting a bare 0, because "who is in front of
            // us" is the first question a failing open raises and the log is the only place to answer
            // it after the fact.
            acLog("[settings]: open %@ escalated=%d active=%d visible=%d key=%d unoccluded=%d above=%@ policy=%ld space=%d",
                  verdict.rawValue,
                  escalated ? 1 : 0,
                  state.appIsActive ? 1 : 0,
                  state.windowIsVisible ? 1 : 0,
                  state.windowIsKey ? 1 : 0,
                  state.windowIsUnoccluded ? 1 : 0,
                  appAbove(window) ?? "-",
                  NSApp.activationPolicy().rawValue,
                  window.collectionBehavior.contains(.moveToActiveSpace) ? 1 : 0)
        }
        #endif

        /// Bring the Settings window in front of whatever the user is looking at, **without** a Dock
        /// icon and **without** floating above everything afterwards.
        ///
        /// Why this is needed at all: NextTyped is an `LSUIElement` agent, and an accessory app is
        /// **not activated** when a scene opens from `MenuBarExtra`. The Settings window is therefore
        /// ordered in behind whatever app is frontmost — with another app in front (or on its full
        /// screen) the user sees nothing happen at all. `SettingsLink` is the supported way to open
        /// the scene but exposes no activation hook, so the fix lives with the window instead of the
        /// menu item — which also covers ⌘, and a reopen.
        ///
        /// Three things changed here on 2026-08-30, each answering a requirement the user set after
        /// the previous build failed its re-test:
        ///
        /// - **The `.accessory →.regular` activation-policy bump is gone.** It was the one mechanism
        ///   that ever got the window to the front, and its price — a Dock icon and a ⌘-Tab entry while
        ///   Settings is open — is the price the user withdrew. The app stays an agent throughout, so
        ///   there is no policy to restore on close either and that observer is gone with it.
        ///
        /// - **`orderFrontRegardless()` replaces the policy bump as the mechanism.** It is the call
        ///   that lets an inactive app put a window on screen, and — unlike `.floating`, which an
        ///   earlier run used only as a *discriminator* and which would be its own bug — it is a
        ///   one-shot ordering, not a window level. The window behaves like any other window the
        ///   moment the user clicks away.
        ///
        /// - **`.moveToActiveSpace`.** The Settings window is a reused singleton and its
        ///   `collectionBehavior` was never set, so AppKit ordered it in on whichever Space it was
        ///   last opened on: open it, switch desktop, open it again, and the activation lands
        ///   somewhere the user cannot see. That reproduces the reported *"einmal funktioniert's und
        ///   dann nicht mehr"* with no activation-denial story at all. Deliberately **not**
        ///   `.canJoinAllSpaces`, which would make it follow the user everywhere — a different bug.
        ///
        /// **The escalation is guarded on the verdict, not on `NSApp.isActive`.** That guard is the
        /// defect this rewrite removes: the process can be active while the window sits behind
        /// another app, in which case the old ladder short-circuited at step 1 and logged nothing, so
        /// a failing open was indistinguishable from a succeeding one. The verdict now requires the
        /// window to be visible, unobscured, key *and* the app active (`WindowFronting`, Core), and a
        /// line is emitted on **every** open rather than only when the ladder ran out.
        ///
        /// Activation is **asynchronous**, so both probes run a runloop delay after the attempt they
        /// judge; reading the state in the same turn proves nothing and did once report a false
        /// failure.
        static func bringToFront(_ window: NSWindow) {
            NSApp.activate()
            place(window)
            verify(window)
        }

        /// Judge one open, escalate once if it fell short, and write the single line that records it.
        /// True while a verification pass is already scheduled for this open. Without it an open
        /// writes **two** lines: the menu path schedules one, and the window becoming key schedules
        /// another a few milliseconds later. The acceptance criterion is one line
        /// per open — a grep that counts opens has to count opens.
        private static var verifyPending = false

        static func verify(_ window: NSWindow) {
            guard !verifyPending else { return }
            verifyPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let first = probe(window)
                guard WindowFronting.needsEscalation(first) else {
                    verifyPending = false
                    #if DEBUG
                    report(.fronted, first, escalated: false, window: window)
                    #endif
                    return
                }
                // Only escalate while the window is still open. If the user closed it — or opened
                // Settings and immediately went back to work — yanking the foreground back would be
                // the focus-stealing this ticket forbids.
                guard window.isVisible else {
                    verifyPending = false
                    #if DEBUG
                    report(WindowFronting.verdict(first), first, escalated: false, window: window)
                    #endif
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                place(window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    verifyPending = false
                    #if DEBUG
                    let second = probe(window)
                    report(WindowFronting.verdict(second), second, escalated: true, window: window)
                    #endif
                }
            }
        }
    }
}
