import AppKit
import NextTypedCore
import KeyboardShortcuts

/// Wires the Core seams to their macOS implementations and runs the prediction loop as a thin
/// **runtime** over the pure-Core `SuggestionSession` reducer: translate tap/AX/async
/// callbacks into `Event`s, hand them to the session, and interpret the returned `Effect`s. ALL the
/// suggestion-decision *policy* — admission gates, echo refill-vs-rerender, type-along, redundancy
/// restore, screenshot click-suppression, the Tab/Esc tap verdict, pause — now lives in the
/// unit-tested reducer; the App owns only IO + timers + the single cancelable predict Task.
///
/// The continuation engine is MLX (`MLXPredictionEngine`); spell-fix is `NSSpellChecker`.
@MainActor
final class AppCoordinator: ObservableObject {
    /// The one coordinator. `NextTypedApp` observes it (the menu bar icon's insertion is scene state)
    /// and `AppDelegate` drives it.
    static let shared = AppCoordinator()

    @Published var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            // Pause/resume is a reducer decision: pausing cancels in-flight work + clears (effects);
            // resuming is a no-op. (the App just forwards the toggle.)
            interpret(session.handle(.setPaused(isPaused)))
            logStatusIfChanged()
        }
    }

    /// Model load state, shown in the menu bar. Starts `.loading` (preload() runs at startup). Only the
    /// engine's `loadEvents()` stream moves it, folded through `ModelLoadStatus` (issue `model-status/210`).
    /// The free-disk refusal of the last model load, for the onboarding Model page. Nil while
    /// there is room or no check ran.
    @Published var modelDiskShortfall: ModelDiskVerdict?
    @Published var modelLoadState: ModelLoadState = .loading {
        didSet { if modelLoadState != oldValue { menuBarStateChanged(); logStatusIfChanged() } }
    }

    /// The folder the model weights were loaded from; `nil` until a load has succeeded (Settings → General).
    @Published var modelFolder: URL?

    /// The onboarding Tab practice step (issue `onboarding/148`). Fed by the real loop below; counts
    /// nothing unless the practice field is on screen.
    let tabPractice = TabPracticeModel()

    /// Launch-at-login state for the menu/Settings toggle. Mirrors the live
    /// `SMAppService` status; written only through `setLaunchAtLogin` so it can never show a state the OS
    /// didn't grant. `private(set)` — the UI flips it via the setter (which re-reads the authoritative
    /// status), not by assigning the published value.
    @Published private(set) var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    // MARK: - Settings surface (read/write for the Settings UI)
    //
    // The loop's single source of truth is `settingsStore.policy`, read FRESH from `UserDefaults` on
    // every keystroke at `currentContext` (AppCoordinator.swift ~L337). So a write here takes effect on
    // the next prediction with no extra wiring; these members only exist so the Settings panes can read
    // and mutate the same store. `objectWillChange.send()` keeps the SwiftUI controls in sync with their
    // own writes (the store isn't itself observable).

    /// Global master switch — the "Enable completions" toggle (General pane). Passthrough to the store.
    var isGloballyEnabled: Bool { settingsStore.policy.globallyEnabled }

    func setGloballyEnabled(_ enabled: Bool) {
        settingsStore.setGloballyEnabled(enabled)
        objectWillChange.send()
    }

    // Mid-text completion (FIM) has no member here on purpose. Unlike the settings above, the
    // reducer holds it as state rather than re-reading the store per keystroke — it changes which *model*
    // a caret routes to, so a flip must tear down the ghost the other path produced (`.setFIMEnabled`).
    // Until the FIM model is wired there is no Settings control to drive that, so the flag is read once
    // in `start()` and a `defaults write` takes effect on relaunch — the `snapshotReuseEnabled`
    // shape. The Settings pair lands with the model, not before it.

    /// The Short / Medium / Long ghost length (General pane). Like the
    /// FIM flag — and unlike the enablement policy, which the loop re-reads per keystroke — the reducer
    /// holds this as state: a flip must repaint the ghost that is *already* showing, and only the
    /// reducer knows what that is. It costs no inference (the buffer is already decoded), so
    /// the event repaints rather than cancelling anything.
    var completionLength: CompletionLength { settingsStore.completionLength }

    func setCompletionLength(_ length: CompletionLength) {
        settingsStore.setCompletionLength(length)
        // Repaint at the caret the ghost on screen was painted at: the picker's popup menu may still hold
        // the system-wide focus, so a fresh caret read would find none and hide the ghost.
        dispatch(.setCompletionLength(length), caret: shownCaret)
        objectWillChange.send()
    }

    // MARK: Battery posture

    private let powerObserver = PowerSourceObserver()
    private var powerSource: PowerSource = .ac
    private var lastBatteryPosture = BatteryPosture.normal
    private var lastPowerLine: String?

    /// True while on-demand mode is active; the menu shows a status line from it.
    @Published private(set) var batteryOnDemandActive = false

    /// The assigned force-activate shortcut, for the menu line and the Settings toggle.
    var forceActivateShortcutDescription: String? {
        KeyboardShortcuts.getShortcut(for: .forceActivate).map { "\($0)" }
    }

    var batterySuggestOnlyOnDemand: Bool { settingsStore.batterySuggestOnlyOnDemand }

    func setBatterySuggestOnlyOnDemand(_ enabled: Bool) {
        settingsStore.setBatterySuggestOnlyOnDemand(enabled)
        recomputeBatteryPosture()
        objectWillChange.send()
    }

    var batteryShorterCompletions: Bool { settingsStore.batteryShorterCompletions }

    func setBatteryShorterCompletions(_ enabled: Bool) {
        settingsStore.setBatteryShorterCompletions(enabled)
        recomputeBatteryPosture()
        objectWillChange.send()
    }

    /// The last engine cap update, so a quick flip pair reaches the engine in order.
    private var decodeCapTask: Task<Void, Never>?

    /// Recomputes the posture from the power source, the preference and the shortcut assignment.
    /// Dispatches `.setBatteryPosture` only when the posture changed and logs one `[power]` line per
    /// change, including the first one at launch.
    private func recomputeBatteryPosture() {
        let result = BatteryPolicy.posture(
            source: powerSource,
            preferences: BatteryPreferences(
                suggestOnlyOnDemand: settingsStore.batterySuggestOnlyOnDemand,
                shorterCompletions: settingsStore.batteryShorterCompletions),
            forceShortcutAssigned: KeyboardShortcuts.getShortcut(for: .forceActivate) != nil)
        let posture = result.posture
        batteryOnDemandActive = posture.onDemandOnly
        let line = "source=\(powerSource.rawValue) onDemand=\(posture.onDemandOnly ? "on" : "off") "
            + "cap=\(posture.decodeWordCap) reason=\(result.reason)"
        if line != lastPowerLine {
            lastPowerLine = line
            #if DEBUG
            acLog("[power]: %@", line)
            #endif
        }
        guard posture != lastBatteryPosture else { return }
        let capChanged = posture.decodeWordCap != lastBatteryPosture.decodeWordCap
        lastBatteryPosture = posture
        if capChanged {
            let previous = decodeCapTask
            let engine = predictionEngine
            let cap = posture.decodeWordCap
            decodeCapTask = Task {
                await previous?.value
                await engine.setDecodeWordCap(cap)
            }
        }
        dispatch(.setBatteryPosture(posture))
    }

    private func startBatteryObservation() {
        powerObserver.start { [weak self] source in
            self?.powerSource = source
            self?.recomputeBatteryPosture()
        }
        // The package posts this when the user records, clears or resets a shortcut.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?["name"] as? KeyboardShortcuts.Name) == .forceActivate else { return }
            MainActor.assumeIsolated {
                self?.recomputeBatteryPosture()
                self?.objectWillChange.send()   // the Settings toggle's enabled state reads the shortcut
            }
        }
    }

    /// The trailing punctuation picker (Shortcuts pane). The reducer holds it as state, like
    /// the completion length, and the launch seed below takes the same event a later flip does.
    var trailingPunctuation: TrailingPunctuation { settingsStore.trailingPunctuation }

    func setTrailingPunctuation(_ value: TrailingPunctuation) {
        settingsStore.setTrailingPunctuation(value)
        dispatch(.setTrailingPunctuation(value))
        objectWillChange.send()
    }

    // MARK: Rebindable intercept keys and the Esc picker

    /// The chords for accept word, accept all and dismiss. The event tap reads its own copy, set here
    /// at launch and on every rebind, so a keyDown never reads the defaults store.
    var interceptBindings: InterceptBindings { settingsStore.interceptBindings }

    /// Move `action` to `chord`, or return why it is refused (another of ours, typing, navigation,
    /// macOS). A refused chord changes nothing.
    func rebind(_ action: InterceptAction, to chord: KeyChord) -> BindingRefusal? {
        switch interceptBindings.rebinding(action, to: chord, globalShortcuts: Self.globalShortcutChords()) {
        case .success(let next):
            applyInterceptBindings(next)
            return nil
        case .failure(let refusal):
            acLog("[shortcuts]: rebind refused action=\(action.rawValue) reason=\(refusal)")
            return refusal
        }
    }

    /// Put `action` back on our default key. Refused when the default is now another action's chord.
    func resetBinding(_ action: InterceptAction) -> BindingRefusal? {
        rebind(action, to: InterceptBindings.defaults[action])
    }

    private func applyInterceptBindings(_ bindings: InterceptBindings) {
        settingsStore.setInterceptBindings(bindings)
        eventTap.bindings = bindings
        objectWillChange.send()
    }

    /// The chords our `KeyboardShortcuts` registrations hold now (pause, force-activate, quiet).
    static func globalShortcutChords() -> [KeyChord] {
        [KeyboardShortcuts.Name.togglePause, .forceActivate, .temporaryQuiet]
            .compactMap { KeyboardShortcuts.getShortcut(for: $0) }
            .map(KeyChord.init(shortcut:))
    }

    var escBehaviour: EscBehaviour { settingsStore.escBehaviour }

    func setEscBehaviour(_ value: EscBehaviour) {
        settingsStore.setEscBehaviour(value)
        dispatch(.setEscBehaviour(value))
        objectWillChange.send()
    }

    /// English spelling variant. The reducer applies it to the finished continuation; a flip
    /// clears the ghost showing, so the next prediction arrives in the new spelling.
    var spellingVariant: SpellingVariant { settingsStore.spellingVariant }

    func setSpellingVariant(_ variant: SpellingVariant) {
        settingsStore.setSpellingVariant(variant)
        dispatch(.setSpellingVariant(variant))
        objectWillChange.send()
    }

    // MARK: Model unload

    var modelUnloadSetting: ModelUnloadSetting { settingsStore.modelUnloadSetting }

    /// Persist the choice and hand it to the residency controller, so it applies without a relaunch.
    func setModelUnloadSetting(_ setting: ModelUnloadSetting) {
        settingsStore.setModelUnloadSetting(setting)
        residencyController.setUnloadRule(setting)
        objectWillChange.send()
    }

    // MARK: Model choice

    var modelChoice: ModelChoice { settingsStore.modelChoice }

    /// Store the pick and swap the loaded model at once: the engine releases the weights and loads the
    /// chosen model (its local folder, else the pinned Hub download). A pick equal to the stored one
    /// does nothing.
    func setModelChoice(_ choice: ModelChoice) {
        guard choice != settingsStore.modelChoice else { return }
        settingsStore.setModelChoice(choice)
        objectWillChange.send()
        Task { await predictionEngine.reloadForModelChoice() }
    }

    // MARK: Menu bar icon
    //
    // Whether the icon is inserted is `MenuBarIconPolicy` (Core); this block holds the three facts it
    // reads and the one route to Settings that works while the icon is hidden.

    /// The user's wish, mirrored from the store so SwiftUI redraws on a flip.
    @Published private(set) var showMenuBarIcon: Bool = AppSettingsStore().showMenuBarIcon

    /// Re-read at launch and on every activation (`refreshMenuBarAttention`). A model-state change does
    /// not re-read it. A grant revoked while the app runs is therefore noticed on the next activation,
    /// not instantly.
    @Published private(set) var accessibilityMissing: Bool = !Permissions.hasAccessibility

    /// A reopen of the running app asked for Settings and the icon's label has not served it yet.
    @Published var settingsRequestPending = false

    /// The icon is held in the menu bar for the moment it takes its label to serve a reopen.
    @Published private var iconHeldForSettingsRequest = false

    private var lastLoggedMenuBarState: String?

    // MARK: Surface status line

    /// What the last predict run decided, with the app it was reached for. Memory only: never stored, and
    /// it holds no text, no value length and no window title.
    struct LastSurfaceVerdict: Equatable {
        let bundleID: String
        let verdict: SurfaceVerdict
    }

    @Published private(set) var lastSurfaceVerdict: LastSurfaceVerdict?
    private var lastLoggedStatus: String?

    /// The status the menu shows for the last other app. The verdict counts only for the app it was
    /// reached for (an app switch clears it), and a quiet the user just started shows at once.
    var surfaceStatus: SurfaceStatus {
        var verdict = lastSurfaceVerdict.flatMap { $0.bundleID == lastFrontmostBundleID ? $0.verdict : nil }
        if let id = lastFrontmostBundleID, temporarilyQuietBundleIDs.contains(id),
           verdict == nil || verdict == .on {
            verdict = .temporaryQuiet
        }
        return SurfaceStatus.compose(
            paused: isPaused, accessibilityGranted: !accessibilityMissing,
            modelReady: modelLoadState.canPredict, lastVerdict: verdict)
    }

    /// The `.surfaceVerdict` effect: keep it for the app the user is writing in. Our own windows are
    /// ignored; a run never starts there.
    private func noteSurfaceVerdict(_ verdict: SurfaceVerdict) {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return }
        // A run that reached this app means the user is writing in it, even when the workspace feed
        // has not reported the switch yet (it can lag a fresh launch).
        if lastFrontmostBundleID != id { lastFrontmostBundleID = id }
        let value = LastSurfaceVerdict(bundleID: id, verdict: verdict)
        if lastSurfaceVerdict != value { lastSurfaceVerdict = value }
        logStatusIfChanged()
    }

    /// An app switch ends the verdict's meaning ("Start typing in a text field" until the next run).
    private func clearSurfaceVerdict(forSwitchTo bundleID: String) {
        if let site = lastSite, site.bundleID != bundleID { lastSite = nil }
        guard let last = lastSurfaceVerdict, last.bundleID != bundleID else { return }
        lastSurfaceVerdict = nil
        logStatusIfChanged()
    }

    // MARK: Websites

    /// The host the last context of an app had. Memory only; it holds the host and nothing else, and an
    /// app switch drops it.
    struct LastSite: Equatable {
        let bundleID: String
        let host: String
    }

    @Published private(set) var lastSite: LastSite?

    /// Called for every enablement decision of a predict run: remembers the host of a page, forgets it
    /// when the surface has none (TextEdit).
    private func noteSiteHost(for surface: SurfaceIdentity) {
        let next = surface.host.map { LastSite(bundleID: surface.bundleID, host: $0) }
        if lastSite != next { lastSite = next }
    }

    /// The site the menu offers a toggle for: the last host seen in the app the user is writing in.
    var menuSite: LastSite? {
        guard let site = lastSite, site.bundleID == lastFrontmostBundleID else { return nil }
        return site
    }

    /// Effective state on that site: site rules first, then the app's own choice (the predict path's verdict).
    var menuSiteEnabled: Bool {
        guard let site = menuSite else { return false }
        return settingsStore.policy.verdict(for: SurfaceIdentity(bundleID: site.bundleID, host: site.host)) == .enabled
    }

    /// Whether the menu site has a rule of its own, so the app entry can say so.
    var menuSiteHasRule: Bool {
        guard let site = menuSite else { return false }
        return settingsStore.siteRuleList.hasRule(for: site.host)
    }

    /// The menu toggle "Complete on <host>": writes or updates the exact rule for that host.
    func setCompleteOnLastSite(_ enabled: Bool) {
        guard let site = menuSite else { return }
        settingsStore.setSiteRuleList(settingsStore.siteRuleList.settingExact(host: site.host, enabled: enabled))
        lastSurfaceVerdict = nil
        objectWillChange.send()
        logStatusIfChanged()
    }

    /// The Websites section's rules.
    var siteRules: [SiteRule] { settingsStore.siteRuleList.rules }

    /// Adds a rule from the field. On failure nothing is stored.
    func addSiteRule(_ input: String) -> Result<Void, SiteRuleInputError> {
        switch settingsStore.siteRuleList.adding(input) {
        case .success(let list):
            settingsStore.setSiteRuleList(list)
            objectWillChange.send()
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func removeSiteRule(pattern: String) {
        settingsStore.setSiteRuleList(settingsStore.siteRuleList.removing(pattern: pattern))
        objectWillChange.send()
    }

    func setSiteRule(pattern: String, enabled: Bool) {
        settingsStore.setSiteRuleList(settingsStore.siteRuleList.setting(pattern: pattern, enabled: enabled))
        objectWillChange.send()
    }

    /// Effective state of the menu target (pause, site rules excluded: the menu knows no host), read from
    /// the same policy the predict path uses, so the toggle and the Apps pane cannot disagree.
    var menuTargetEnabled: Bool {
        guard let id = lastFrontmostBundleID else { return false }
        return settingsStore.policy.isEnabled(forBundleID: id)
    }

    /// The menu toggle "Complete in <App>": writes the permanent override the Apps pane writes.
    /// Never targets NextTyped itself; `lastFrontmostBundleID` already excludes our bundle, and the
    /// guard here keeps that true if the tracking changes.
    func setCompleteInLastApp(_ enabled: Bool) {
        guard let id = lastFrontmostBundleID, id != Bundle.main.bundleIdentifier else { return }
        setAppOverride(enabled, forBundleID: id)
        lastSurfaceVerdict = nil
        logStatusIfChanged()
    }

    private func logStatusIfChanged() {
#if DEBUG
        let status = surfaceStatus.token
        let line = "\(status) app=\(lastSurfaceVerdict?.bundleID ?? lastFrontmostBundleID ?? "-")"
        guard line != lastLoggedStatus else { return }
        lastLoggedStatus = line
        acLog("[status]: %@", line)
#endif
    }

    // MARK: Menu bar word count

    /// Today's accepted words, from the usage store's own counters.
    @Published private(set) var menuBarWords = 0

    var showWordCountInMenuBar: Bool { settingsStore.showWordCountInMenuBar }

    func setShowWordCountInMenuBar(_ enabled: Bool) {
        settingsStore.setShowWordCountInMenuBar(enabled)
        objectWillChange.send()
#if DEBUG
        if enabled { acLog("[menubar]: words=%d", menuBarWords) }
#endif
    }

    /// What the menu-bar label draws next to the icon, or `nil` for the icon alone.
    var menuBarWordsLabel: String? {
        showWordCountInMenuBar ? MenuBarWordCount.label(words: menuBarWords) : nil
    }

    private func todayWordsChanged(_ words: Int) {
        menuBarWords = words
#if DEBUG
        if showWordCountInMenuBar { acLog("[menubar]: words=%d", words) }
#endif
    }

    /// The pending release of a held icon. A newer request cancels it, so an old release cannot drop
    /// a newer hold.
    private var iconHoldRelease: Task<Void, Never>?

    private var menuBarAttention: MenuBarIconPolicy.AttentionReason? {
        MenuBarIconPolicy.attentionReason(
            accessibilityMissing: accessibilityMissing, modelFailed: modelLoadState.isFailed,
            blockingHostNotice: hostNotice?.isBlocking ?? false)
    }

    /// What `MenuBarExtra(isInserted:)` reads.
    var menuBarIconInserted: Bool {
        #if DEBUG
        // A snapshot run (`--render-settings`) is a second copy of the app beside the user's own; an icon
        // from it looks like a second running NextTyped in the menu bar.
        if Self.isSnapshotRun { return false }
        #endif
        return menuBarIconInsertedByPolicy || iconHeldForSettingsRequest
    }

    #if DEBUG
    private static let isSnapshotRun = SettingsSnapshotRenderer.outputDirectory(from: CommandLine.arguments) != nil
    #endif

    /// The policy's answer alone, without the short hold for a reopen.
    private var menuBarIconInsertedByPolicy: Bool {
        MenuBarIconPolicy.isInserted(userWantsIcon: showMenuBarIcon, needsAttention: menuBarAttention != nil)
    }

    func setShowMenuBarIcon(_ show: Bool) {
        settingsStore.setShowMenuBarIcon(show)
        showMenuBarIcon = show
        menuBarStateChanged()
    }

    /// The binding's setter: the user dragged the icon out of the menu bar (Command-drag). Treated as
    /// the toggle, unless the icon is forced, in which case the drag is undone by the next redraw.
    func menuBarIconInsertionChanged(to inserted: Bool) {
        guard inserted != menuBarIconInserted, menuBarAttention == nil, !iconHeldForSettingsRequest else { return }
        setShowMenuBarIcon(inserted)
    }

    func refreshMenuBarAttention() {
        let missing = !Permissions.hasAccessibility
        if missing != accessibilityMissing { accessibilityMissing = missing }
        menuBarStateChanged()
    }

    /// A reopen of the running app (Finder, Spotlight, Dock). Once Settings has been opened in this
    /// process, its window exists and is ordered in front directly, with no icon involved. Only the first
    /// open of a session needs the icon's label (the one place that owns `openSettings`), so a hidden
    /// icon is held for that moment.
    func requestSettingsFromReopen() {
        if SettingsWindowConfigurator.Coordinator.settingsWindow != nil {
            SettingsWindowConfigurator.Coordinator.openAndFront {}
            return
        }
        // Computed from the policy alone: a second reopen during a hold must keep the hold.
        iconHoldRelease?.cancel()
        iconHoldRelease = nil
        if !menuBarIconInsertedByPolicy {
            iconHeldForSettingsRequest = true
            acLog("[menubar]: icon held for settings request")
        }
        settingsRequestPending = true
    }

    /// The label calls this after it has opened Settings. Releases a held icon once the open is under way.
    func settingsRequestServed() {
        settingsRequestPending = false
        guard iconHeldForSettingsRequest else { return }
        iconHoldRelease?.cancel()
        iconHoldRelease = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.iconHeldForSettingsRequest = false
            self.iconHoldRelease = nil
            self.menuBarStateChanged()
        }
    }

    private func menuBarStateChanged() {
#if DEBUG
        let state: String
        if let reason = menuBarAttention, !showMenuBarIcon {
            state = "icon forced reason=\(reason.rawValue)"
        } else {
            state = showMenuBarIcon ? "icon shown" : "icon hidden"
        }
        guard state != lastLoggedMenuBarState else { return }
        lastLoggedMenuBarState = state
        acLog("[menubar]: %@", state)
#endif
    }

    // MARK: Temporary per-app quiet
    //
    // A transient layer ABOVE the stored per-app preference and never a write to it: "I have turned
    // TextEdit off" and "quiet for fifteen minutes" are different statements, and a timer that restored
    // a *guessed* value could end up ENABLING an app the user had deliberately disabled. The decision
    // lives in the reducer (which has no access to `AppSettingsStore` at all, so suppress-only is
    // structural); what the App owns is the expiry timer — the `scheduleScreenshotDisarm` shape — and
    // the ledger the menu reads.

    /// Apps currently quiet, for the menu. A mirror of the reducer's set for UI only; the reducer stays
    /// authoritative for the *decision*, and both are written through the two methods below.
    @Published private(set) var temporarilyQuietBundleIDs: Set<String> = []

    private var quietTimers: [String: Task<Void, Never>] = [:]

    /// The app a temporary quiet would apply to — the one the user is *writing in*.
    ///
    /// Deliberately not `NSWorkspace.frontmostApplication`: opening the menu-bar menu activates
    /// NextTyped, so at the moment the user picks "Pause completions in …" the frontmost app is
    /// **us**. The frontmost feed the residency ladder already installs is filtered against our own
    /// bundle ID instead, which is correct for the hotkey path too (a global hotkey does not activate
    /// an agent app, so the last frontmost app IS the app the key was pressed in).
    private(set) var lastFrontmostBundleID: String?

    /// `(bundleID, display name)` of that app, resolved late so the menu never shows a stale name.
    var temporaryQuietTarget: (bundleID: String, name: String)? {
        guard let id = lastFrontmostBundleID else { return nil }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first?.localizedName ?? id
        return (id, name)
    }

    /// Start (or restart) the quiet for the app the user is writing in.
    func quietCurrentApp(for duration: TemporaryQuietDuration) {
        guard let id = lastFrontmostBundleID else { return }
        quietTimers.removeValue(forKey: id)?.cancel()
        temporarilyQuietBundleIDs.insert(id)
        temporaryQuietEnds[id] = Date().addingTimeInterval(TimeInterval(duration.seconds))
        dispatch(.temporaryQuietStarted(bundleID: id))
        quietTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration.seconds))
            guard let self, !Task.isCancelled else { return }
            // The timer half of decision 3c: it lifts the quiet and shows nothing. The reducer holds
            // that rule (`resumedExplicitly: false`), so it is pinned by a test rather than by this
            // call site happening not to ask for a ghost.
            self.endTemporaryQuiet(bundleID: id, resumedExplicitly: false)
        }
        #if DEBUG
        acLog("[quiet]: %@ for %d min", id, duration.minutes)
        #endif
    }

    /// End it. `resumedExplicitly` is the user pressing *resume* — an explicit action produces an
    /// immediate result (the reducer regenerates); an expiring timer does not.
    func endTemporaryQuiet(bundleID: String, resumedExplicitly: Bool) {
        quietTimers.removeValue(forKey: bundleID)?.cancel()
        temporarilyQuietBundleIDs.remove(bundleID)
        temporaryQuietEnds.removeValue(forKey: bundleID)
        dispatch(.temporaryQuietEnded(bundleID: bundleID, resumedExplicitly: resumedExplicitly))
        #if DEBUG
        acLog("[quiet]: %@ ended (%@)", bundleID, resumedExplicitly ? "resumed" : "expired")
        #endif
    }

    /// The hotkey: quiet the current app for the default step, or resume it if it is already quiet.
    /// A key cannot carry a duration — the menu is where one is chosen.
    func toggleTemporaryQuietFromHotkey() {
        guard let id = lastFrontmostBundleID else { return }
        if temporarilyQuietBundleIDs.contains(id) {
            endTemporaryQuiet(bundleID: id, resumedExplicitly: true)
        } else {
            quietCurrentApp(for: TemporaryQuietDuration.hotkeyDefault)
        }
    }

    // MARK: Settings status (General and Apps)

    /// When each active quiet ends, for the Status section and the Apps row captions.
    @Published private(set) var temporaryQuietEnds: [String: Date] = [:]

    /// The model's memory tier, published by `ModelResidencyController`.
    @Published private(set) var residencyState: ModelResidencyPolicy.ModelState = .loaded

    /// Lines for the General Status section. Empty while nothing is paused, quieted or unloaded.
    func settingsStatusLines(now: Date = Date()) -> [StatusLine] {
        SettingsStatusSummary.lines(
            paused: isPaused, quiets: activeQuiets(), residency: residencyState, now: now)
    }

    /// The quiet for one app, if it is active; the Apps row reads its caption from it.
    func quiet(forBundleID id: String) -> SettingsStatusSummary.Quiet? {
        activeQuiets().first { $0.bundleID == id }
    }

    private func activeQuiets() -> [SettingsStatusSummary.Quiet] {
        temporaryQuietEnds.map { id, until in
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first?.localizedName ?? id
            return SettingsStatusSummary.Quiet(bundleID: id, appName: name, until: until)
        }
    }

    /// The Resume button of a status line. It calls the same paths as the menu: `isPaused = false`, and
    /// `endTemporaryQuiet(resumedExplicitly: true)`, which regenerates at the caret.
    func perform(_ action: StatusLine.Action) {
        switch action {
        case .resumeAll: isPaused = false
        case .resumeApp(let bundleID): endTemporaryQuiet(bundleID: bundleID, resumedExplicitly: true)
        }
    }

    #if DEBUG
    /// Snapshot fixtures only (`paused`, `quiet`): sets the pause flag and one quiet with 11 min 10 s left,
    /// without starting the expiry timer. Passing `nil` clears both.
    func debugSetStatus(paused: Bool, quietBundleID: String?) {
        isPaused = paused
        if let id = quietBundleID {
            temporaryQuietEnds = [id: Date().addingTimeInterval(11 * 60 + 10)]
            if !addedAppSources.contains(where: { $0.bundleID == id }) {
                addedAppSources.append(AppListing.Source(bundleID: id, name: "Calculator"))
            }
        } else {
            temporaryQuietEnds = [:]
            addedAppSources.removeAll { $0.bundleID == "com.apple.calculator" }
        }
    }
    #endif

    // MARK: User switches

    var isSpellingFixesEnabled: Bool { settingsStore.spellingFixesEnabled }
    func setSpellingFixesEnabled(_ enabled: Bool) {
        settingsStore.setSpellingFixesEnabled(enabled)
        objectWillChange.send()
    }

    /// A General-pane Languages switch: on means suggestions for that language.
    func isLanguageOn(_ selector: LanguageSelector) -> Bool {
        !settingsStore.languagePolicy.disabled.contains(selector)
    }

    func setLanguage(_ selector: LanguageSelector, on: Bool) {
        settingsStore.setLanguageDisabled(selector, !on)
        objectWillChange.send()
    }

    var isWindowContextEnabled: Bool { settingsStore.windowContextEnabled }
    func setWindowContextEnabled(_ enabled: Bool) {
        settingsStore.setWindowContextEnabled(enabled)
        objectWillChange.send()
    }

    var isReplyContextEnabled: Bool { settingsStore.replyContextEnabled }
    func setReplyContextEnabled(_ enabled: Bool) {
        settingsStore.setReplyContextEnabled(enabled)
        objectWillChange.send()
    }

    var isClipboardContextEnabled: Bool { settingsStore.clipboardContextEnabled }
    func setClipboardContextEnabled(_ enabled: Bool) {
        settingsStore.setClipboardContextEnabled(enabled)
        objectWillChange.send()
    }

    /// Per-app overrides for the Apps pane. `nil` = follow default/blocklist; `true`/`false` = force on/off.
    var perAppOverrides: [String: Bool] { settingsStore.policy.overrides }

    /// The Apps pane picker: what an app without an override does.
    var appDefaultMode: DefaultMode {
        #if DEBUG
        if let forced = debugAppDefaultMode { return forced }
        #endif
        return settingsStore.policy.defaultMode
    }

    func setAppDefaultMode(_ mode: DefaultMode) {
        settingsStore.setDefaultMode(mode)
        objectWillChange.send()
    }

    func appOverride(forBundleID id: String) -> Bool? { settingsStore.policy.overrides[id] }

    func setAppOverride(_ enabled: Bool?, forBundleID id: String) {
        settingsStore.setOverride(enabled, forBundleID: id)
        objectWillChange.send()
    }

    /// Effective on/off for an app (global switch + blocklist + override) — the Apps-pane row caption.
    func isEnabled(forBundleID id: String) -> Bool { settingsStore.policy.isEnabled(forBundleID: id) }

    // MARK: Screen-context OCR (Privacy pane)

    /// The OCR toggle's state. **Never** just the stored preference: OCR is only actually running when
    /// the OS also grants Screen Recording, so the switch reflects the effective state and can't show a
    /// capability the user didn't grant (the `LaunchAtLogin` precedent).
    var isScreenOCREnabled: Bool { settingsStore.screenOCREnabled && Permissions.hasScreenRecording }

    /// True when the user enabled OCR but the OS grant is missing or was revoked — the Privacy pane
    /// shows a repair row with an Open-Settings deep link for this case.
    var screenOCRNeedsPermission: Bool {
#if DEBUG
        if let debugScreenOCRNeedsPermission { return debugScreenOCRNeedsPermission }
#endif
        return settingsStore.screenOCREnabled && !Permissions.hasScreenRecording
    }

    /// True while screen-context OCR is switched on in the settings, whether or not the OS grant is
    /// there yet. The Setup pane shows its Optional section (Screen Recording) only then.
    var screenOCRRequested: Bool {
#if DEBUG
        if let debugScreenOCRRequested { return debugScreenOCRRequested }
#endif
        return settingsStore.screenOCREnabled
    }

    /// Apply the OCR toggle. Turning it **on** prompts for Screen Recording; turning it off is
    /// unconditional and immediate. The pre-permission explainer is presented by the Privacy pane
    /// *before* this is called.
    ///
    /// The stored flag records the user's **intent**; whether OCR actually runs is
    /// `intent && Permissions.hasScreenRecording`, re-read live at every use (`isScreenOCREnabled`, and
    /// the provider's own gate). That split matters because a **first** grant is not observable in this
    /// process: macOS shows the dialog, `CGRequestScreenCaptureAccess()` returns false, and preflight
    /// keeps returning false until the app is relaunched. Persisting that false would silently discard
    /// the user's choice *and* leave `screenOCRNeedsPermission` — the repair row that explains the
    /// relaunch — permanently unreachable. Intent is therefore kept, and the UI shows the honest state:
    /// the toggle reads off until the OS agrees, with the repair row saying why. No capture can happen
    /// on intent alone.
    func setScreenOCREnabled(_ enabled: Bool) {
        guard enabled else {
            settingsStore.setScreenOCREnabled(false)
            objectWillChange.send()
            return
        }
        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecordingPrompt()
        }
        settingsStore.setScreenOCREnabled(true)
        objectWillChange.send()
    }

    // MARK: Personalization (Privacy pane)

    /// The style-profile toggle. Ships **off** pending the offline probe GO
    ///  — with it off, capture stores nothing and the prompt is byte-identical to today's.
    var isPersonalizationEnabled: Bool {
        #if DEBUG
        if let forced = debugPersonalizationEnabled { return forced }
        #endif
        return settingsStore.personalizationEnabled
    }

    #if DEBUG
    /// Snapshot renderer only: shows the personalization-on state without writing the user's defaults.
    var debugPersonalizationEnabled: Bool?
    /// Snapshot renderer only: shows the "Only apps I turn on" Apps pane without writing the user's defaults.
    var debugAppDefaultMode: DefaultMode?
    #endif

    /// Apps added with "Add app..." in Settings. Lives as long as the process, so switching panes keeps them.
    var addedAppSources: [AppListing.Source] = []

    func setPersonalizationEnabled(_ enabled: Bool) {
        settingsStore.setPersonalizationEnabled(enabled)
        // Both edges go through the controller's push, so `learnedProfileIsUnreadable` keeps a single
        // owner. Clearing the flag here instead would make the coordinator a second writer, which is how
        // the two get to disagree.
        if enabled { personalization.preload() } else { personalization.refreshSaveability() }
        objectWillChange.send()
        refreshLearnedProfileExists()
    }

    /// Whether the learned profile holds anything. The menu bar reads it to decide whether to offer
    /// "Stop learning and delete profile"; a menu cannot await the store, so it is pushed.
    /// Staleness is bounded: while learning is off the profile only changes through a reset, and
    /// while it is on the menu item shows regardless.
    @Published private(set) var learnedProfileExists = false

    /// A file-existence check, not a decrypt: it never touches the Keychain, so it is safe at launch
    /// with learning off, and a leftover profile whose key is lost still counts (deleting is the repair).
    func refreshLearnedProfileExists() {
        learnedProfileExists = personalization.profileFileExists()
    }

    /// Menu-bar visibility of "Stop learning and delete profile".
    var showsStopLearningMenuItem: Bool {
        StopLearningMenuPolicy.isVisible(
            personalizationEnabled: isPersonalizationEnabled,
            profileFileExists: learnedProfileExists)
    }

    /// The menu's one step: learning off first (so nothing is captured while the delete runs), then the
    /// same `resetLearnedProfile()` the Privacy pane calls. Usage statistics are untouched.
    func stopLearningAndDeleteProfile() async {
        setPersonalizationEnabled(false)
        acLog("[style]: stop learning requested from menu bar")
        await resetLearnedProfile()
    }

    /// True while the encrypted profile exists but cannot be read, so learning is silently RAM-only
    /// . The Privacy pane and the transparency view show a repair row for this;
    /// without it the failure is invisible at exactly the surface built to make the feature transparent.
    ///
    /// **Pushed, not polled.** The store enters this state at preload and leaves it at a commit's retry —
    /// neither of which a view is watching. Refreshing it when a settings pane appears would leave a
    /// stale warning standing after the retry had already fixed it.
    @Published private(set) var learnedProfileIsUnreadable = false

    /// The learning-source denylist, surfaced per row in the Apps pane.
    func isLearningEnabled(forBundleID id: String) -> Bool {
        !settingsStore.learningDisabledBundleIDs.contains(id)
    }

    func setLearningEnabled(_ enabled: Bool, forBundleID id: String) {
        settingsStore.setLearningEnabled(enabled, forBundleID: id)
        objectWillChange.send()
    }

    /// The "what NextTyped has learned from you" view — transparency through the app, so
    /// the store itself can stay encrypted.
    func learnedProfile() async -> StyleProfile { await personalization.learnedProfile() }

    /// One-click reset: in-memory buffer, resident profile, the encrypted file AND the Keychain key.
    func resetLearnedProfile() async {
        await personalization.reset()
        refreshLearnedProfileExists()
        objectWillChange.send()
    }

    // MARK: Usage statistics (Statistics pane)

    /// The counters behind the Statistics pane — this store's whole transparency surface.
    func usageStatistics() async -> UsageStatistics {
#if DEBUG
        if let debugUsageStatistics { return debugUsageStatistics }
#endif
        return await statistics.statistics()
    }

#if DEBUG
    /// Snapshot fixture `statistics-filled` (`SettingsSnapshotFixture`): a fixed value returned instead of
    /// the store's. DEBUG only; the store itself is never written.
    var debugUsageStatistics: UsageStatistics?

    /// Snapshot fixtures `ocr-waiting` and `profile-unreadable`: force the two Privacy-pane notices.
    /// DEBUG only; neither touches the settings store or the personalization store.
    var debugScreenOCRNeedsPermission: Bool? {
        didSet { objectWillChange.send() }
    }

    /// Snapshot fixture `ocr-on`: the OCR switch is on, so the Setup pane shows its Optional section.
    var debugScreenOCRRequested: Bool? {
        didSet { objectWillChange.send() }
    }

    func debugSetLearnedProfileUnreadable(_ unreadable: Bool) {
        learnedProfileIsUnreadable = unreadable
    }
#endif

    /// One-click reset: the pending batch, the resident counters and the file.
    func resetUsageStatistics() async {
        await statistics.reset()
        objectWillChange.send()
    }

    // Core seams ← app implementations.
    private let settingsStore = AppSettingsStore()

    /// The personalization profile: own-inserted capture + the frozen front-most segment. The
    /// encrypted store is a separate actor so its scan/decrypt work stays off the main actor.
    private lazy var personalization = PersonalizationController(
        store: StyleProfileStore(),
        settings: { [settingsStore] in settingsStore.personalizationSettings })

    /// Local usage statistics: accepted words per day and per app plus a
    /// measured typing rate, collected against the same fail-closed eligibility proof personalization
    /// uses. Counts and bundle IDs only — never text.
    private lazy var statistics = UsageStatisticsController(store: UsageStatisticsStore())

    /// Screen-context OCR — off by default; reads its settings live from the same store, so
    /// the Privacy toggle and the Apps pane take effect on the next pass with no extra wiring.
    private lazy var ocrProvider = ScreenOCRContextProvider(
        settings: { [settingsStore] in settingsStore.screenOCRSettings })

    /// The composed provider: AX assembles the context, OCR adds `ocrContext` on top. With OCR off
    /// this is a pass-through, so the default build behaves exactly as before.
    private lazy var contextProvider: ContextProvider = CompositeContextProvider(
        ax: AXContextProvider(), ocr: ocrProvider)

    /// The context assembler: the predict path's one question about the surface. It owns the
    /// composition the App used to perform inline — the per-app rejection alongside the
    /// provider's secure-field/chrome rejections, the fail-closed eligibility proof, and the
    /// personalization segment resolved *before* the context is handed on.
    ///
    /// `verdict` is a closure on purpose: the policy is re-read from `UserDefaults` on **every** call,
    /// which is what makes an Apps-pane switch take effect on the next prediction with no relaunch.
    private lazy var contextAssembler: ContextAssembling = ContextAssembler(
        provider: contextProvider,
        verdict: { [weak self, settingsStore] surface in
            // The assembler awaits this closure off the main actor; `lastSite` is @Published, so hop.
            Task { @MainActor [weak self] in self?.noteSiteHost(for: surface) }
            return settingsStore.policy.verdict(for: surface)
        },
        log: { line in
            // DEBUG-only like every other `[gate]:` consumer: a Release build must not write
            // the bundle ID and timing of a disabled app (password managers) to the unified log.
            // DEBUG: `acLog` feeds the diagnostics tally. Release counts the token and logs nothing.
            #if DEBUG
            acLog("%@", line)
            #else
            DiagnosticsTallyHub.shared.record(line: line)
            #endif
        },
        personalization: EligibilityProofFanout(personalization: personalization, statistics: statistics),
        languagePolicy: { [settingsStore] in settingsStore.languagePolicy },
        languageIdentifier: NaturalLanguageIdentifier(),
        clipboard: ClipboardContextSource.livePort())
    /// The engine. Real MLX unless the harness asked for the scripted fake —
    /// the choice is launch-time and env-driven, never a user setting.
    private let predictionEngine: PredictionEngine
    /// Typed handle on the fake when it is in use, so the harness channel can script/reset it.
    private let fakeEngine: FakePredictionEngine?

    init() {
        if HarnessEnvironment.engine == .fake {
            let fake = FakePredictionEngine()
            fakeEngine = fake
            predictionEngine = fake
        } else {
            fakeEngine = nil
            predictionEngine = MLXPredictionEngine()
        }
        // A census verdict raises or clears the tap-leak notice.
        eventTap.census.onVerdict = { [weak self] verdict in self?.applyTapCensus(verdict) }
        // Secure Input held by another app blinds the tap.
        secureInput.onTransition = { [weak self] transition in self?.applySecureInput(transition) }
        secureInput.start()
    }

    /// The menu notice for another app that interferes with our tap. The board picks by priority.
    @Published private(set) var hostNotice: HostNotice?
    private var hostNoticeBoard = HostNoticeBoard()

    private let secureInput = SecureInputMonitor()

    private func applySecureInput(_ transition: SecureInputTransition) {
        switch transition {
        case .enteredBlocked(let holder):
            acLog("[gate]: secure-input holder=%@", holder?.bundleID ?? "unknown")
            hostNoticeBoard.raise(.secureInputBlocked(holderName: holder?.name))
            dispatch(.eventTapBlinded)
        case .leftBlocked:
            acLog("[secure-input]: cleared")
            hostNoticeBoard.clear(.secureInputBlocked)
        case .enteredExpectedSecureField:
            acLog("[secure-input]: expected-secure-field")
        }
        publishHostNotice()
    }

    private func publishHostNotice() {
        hostNotice = hostNoticeBoard.current
        menuBarStateChanged()
    }

    private func applyTapCensus(_ verdict: EventTapLeakVerdict) {
        switch verdict {
        case .healthy:
            hostNoticeBoard.clear(.eventTapLeak)
        case .leakSuspected(let pid, _):
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
            hostNoticeBoard.raise(.eventTapLeak(ownerName: name))
        }
        publishHostNotice()
    }
    /// `[spell]:` and `[gate]:` lines name the typed word, so they exist in DEBUG builds only
    /// (a Release build writes no typed text to the unified log).
    /// The "Suggest spelling fixes" switch gates the whole checker, read per predict.
    private let spellChecker: SpellChecker = GatedSpellChecker(
        base: LanguageAwareSpellChecker(
            words: VariantAwareWordSpelling(
                base: SystemWordSpelling(),
                installed: NSSpellChecker.shared.availableLanguages,
                preferred: Locale.preferredLanguages,
                spellingVariant: { AppSettingsStore().spellingVariant }),
            identifier: NaturalLanguageIdentifier(),
            // Default off: the typo probe is over its false-suspect limit.
            typoGateEnabled: { UserDefaults.standard.bool(forKey: "typoSuspectGateEnabled") },
            log: AppCoordinator.spellLog),
        isEnabled: { AppSettingsStore().spellingFixesEnabled },
        log: { acLog("%@", $0) })
    #if DEBUG
    private static let spellLog: @Sendable (String) -> Void = { acLog("%@", $0) }
    #else
    private static let spellLog: @Sendable (String) -> Void = { DiagnosticsTallyHub.shared.record(line: $0) }
    #endif
    private let caretLocator = CaretLocator()
    private let inserter = KeyEventSynthesizer()
    private let overlay = OverlayWindowController()
    private let eventTap = EventTapController()
    private let axFocusObserver = AXFocusObserver()

    /// The single consumer of `PredictionEngine.loadEvents()`.
    private var modelEventsTask: Task<Void, Never>?

    /// "Unload model now" in the menu: the residency policy decides, and a second press does nothing.
    func unloadModelNow() { residencyController.unloadNow() }

    /// The idle RAM-reclaim ladder: a pure-Core `ModelResidencyPolicy` driven by this App
    /// effect-interpreter. `lazy` so it can share the one `predictionEngine` instance. AppCoordinator
    /// feeds it the two events it is the natural source of — `predictionActivity` (after a real predict)
    /// and `contextSwitch` (on a focus change); the controller owns the rest (tick, NSWorkspace away-
    /// signals, screen-lock, memory-pressure).
    private lazy var residencyController = ModelResidencyController(engine: predictionEngine)

    /// The pure-Core suggestion-decision reducer. Holds what used to be the App's
    /// `acceptance` / `lifecycle` / `postInsertRenderPending` / `lastContext`/`lastSuggestion` /
    /// `screenshotArmed` fields, plus the inlined policy around them — all now unit-tested.
    private var session = SuggestionSession(tabGrace: TabGrace.isEnabled(milliseconds: AppCoordinator.tabGraceMs))

    /// The Tab grace window: how long a fresh ghost is on screen
    /// before `Tab` is ours. A `defaults` key read once at launch, the `snapshotReuseEnabled` shape:
    ///
    ///     defaults write com.robinklotz.NextTyped tabGraceMs -int 300
    ///     defaults delete com.robinklotz.NextTyped tabGraceMs   # back to shipping (150)
    ///
    /// 0 turns it off, and the reducer is then built without the grace, so no clock runs at all.
    nonisolated private static let tabGraceMs = TabGrace.milliseconds(
        stored: UserDefaults.standard.object(forKey: "tabGraceMs") as? Int)

    /// The grace clock for the newest unsettled ghost (`.scheduleSettle` → `.ghostSettled`). Like the
    /// screenshot disarm, the settled *state* is the reducer's; this is only the timer.
    private var settleTask: Task<Void, Never>?
    /// Which generation owns `settleTask`. Paints finish out of order (a correction awaits twice, a
    /// continuation once), so an older `.scheduleSettle` can arrive after a newer one.
    private var settleSlot = SettleClockSlot()

    // MARK: Harness observability — DEBUG-only; no-ops in release.
    #if DEBUG
    /// The monotonic session-event counter: bumped on every reducer entry (`dispatch` / `interceptKey`),
    /// stamped on the `[present]`/`[hide]` log lines and returned in every snapshot, so a log line and a
    /// channel reply can be joined on it.
    private var seq = 0
    private var harnessServer: HarnessServer?
    private var predictCount = 0
    private var lastPredict: (seq: Int, text: String, ms: Double, trigger: String)?
    private var lastSurface: (bundleID: String, charsBefore: Int)?
    /// The caret geometry the LAST paint was computed from. Coarse frame truth (only
    /// "is it near the caret", never pixel alignment): it is what lets a scenario tell a caret-anchored
    /// bubble from a line-start-anchored one on the Electron marker path.
    private var lastCaret: CaretInfo?
    #endif
    /// The caret the ghost now on screen was painted at; nil while nothing shows. A repaint that changes
    /// no input to the caret (the completion-length flip) reuses it instead of re-reading the focused
    /// element.
    private var shownCaret: CaretInfo?

    /// Single slot: the one cancelable prediction Task. Re-issued by `.schedulePredict`
    /// (which cancels the previous), reused for the viewport reposition. Since the move into `PredictRun` its
    /// **body** is `PredictRun` — the slot did not move, only what runs inside it, and the two-phase
    /// `.contextReady` → `.predictionArrived` sequence with its cancel checks now lives in the module.
    private var inFlight: Task<Void, Never>?

    /// The 12 s screenshot-disarm timer (`.scheduleScreenshotDisarm` → `.screenshotDisarmExpired`).
    /// Arm/disarm *state* lives in the reducer; this is just the clock (the reducer stays
    /// time-free).
    private var disarmTask: Task<Void, Never>?
    /// The Esc field-pause timer. The pause itself is the reducer's state; this is the clock.
    private var fieldPauseTask: Task<Void, Never>?

    // Pinch-zoom is an NSEvent gesture a `CGEventTap` can't observe (no `CGEventType` for magnify);
    // these monitors funnel it — and the tap's scroll — into `handleViewportChange` so a visible
    // suggestion follows the host text instead of freezing at its pre-zoom position/size.
    private var viewportMonitors: [Any] = []

    // Gesture monitors are best-effort and miss some zooms (OS-dependent — confirmed: esp. zoom-OUT),
    // leaving a stale overlay. While a suggestion is visible, this light poll re-reads ONLY the caret
    // rect (a cheap probe) and triggers a full re-paint of `session.currentPresentation` on a geometry
    // change DURING IDLE — a reliable catch-all for zoom/scroll/window-move the events miss. Gated OFF
    // while typing flows (the typing path already re-renders). Stops when nothing shown.
    private var geometryPoll: Task<Void, Never>?
    private var lastProbeRect: CGRect?
    #if DEBUG
    // Churn tooling: renders-vs-ticks over the current poll window, logged periodically so
    // the poll's redundancy is measurable rather than inferred. DEBUG-only; reset when the poll (re)starts.
    private var pollTickCount = 0
    private var pollRenderCount = 0
    #endif

    // Typing-active gate for the geometry poll: a keystroke within `typingQuietWindow` means the typing
    // path owns re-rendering, so the idle poll stays quiet. `lastProbeRect` still tracks the
    // caret every tick, so the first idle tick after typing stops has a fresh baseline (no spurious fire).
    private let pollClock = ContinuousClock()
    private var lastTypingAt: ContinuousClock.Instant?
    private let typingQuietWindow: Duration = .milliseconds(300)

    // MARK: Lifecycle

    func start() async {
        // Offer to move the app to Applications before anything asks for Accessibility. When
        // the moved copy is launching, this instance is quitting and must not start the loop.
        if MoveToApplications.runAtLaunch() { return }
        refreshMenuBarAttention()
        refreshLearnedProfileExists()
        // Seed the reducer with the persisted mid-text (FIM) setting. Default off, so this is
        // a no-op flip on a fresh install; it is what makes the setting survive a relaunch.
        //
        // The engine is seeded from the SAME value in the same breath: the reducer decides whether a
        // mid-text caret may show a bridge, the engine decides which model answers the predict
        // (`FIMSite.route`), and a disagreement between the two would let a mid-text caret predict
        // *forward* — a bridge-shaped ghost that ignores the suffix. `await`ed before anything can type,
        // so no predict can observe the two out of step.
        // The style store reports whether it can actually save; the Privacy pane
        // and the transparency view read it off this published flag.
        personalization.onProfileSaveabilityChanged = { [weak self] unreadable in
            self?.learnedProfileIsUnreadable = unreadable
        }

        #if DEBUG
        acLog("[session]: tabGraceMs=%d", Self.tabGraceMs)
        #endif
        interpret(session.handle(.setCompletionLength(settingsStore.completionLength)))
        interpret(session.handle(.setTrailingPunctuation(settingsStore.trailingPunctuation)))
        interpret(session.handle(.setEscBehaviour(settingsStore.escBehaviour)))
        eventTap.bindings = settingsStore.interceptBindings
        interpret(session.handle(.setSpellingVariant(settingsStore.spellingVariant)))
        let fimEnabled = settingsStore.midTextCompletionEnabled
        interpret(session.handle(.setFIMEnabled(fimEnabled)))
        await predictionEngine.setFIMEnabled(fimEnabled)
        startBatteryObservation()
        // The launch value, once: a flip that happened inside `startBatteryObservation` is already
        // queued in `decodeCapTask`, and this runs after it.
        await decodeCapTask?.value
        await predictionEngine.setDecodeWordCap(lastBatteryPosture.decodeWordCap)
        // Warm the MLX model in the background (first run downloads it). Non-blocking: until it is
        // loaded, predict() returns an empty suggestion, so early keystrokes simply show nothing.
        // The result drives the menu-bar status (Loading model… → Model ready / failed).
        //
        // One task consumes the engine's ordered event stream and is the only writer of the state, so
        // launch, Retry, an unload and a reload inside a predict all show up the same way.
        let events = await predictionEngine.loadEvents()
        modelEventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.modelLoadState = ModelLoadStatus.apply(event, to: self.modelLoadState)
                // The Model page's disk message: set by the refusal, cleared when a load starts again.
                if case .diskTooSmall(let verdict) = event {
                    self.modelDiskShortfall = verdict
                } else if event == .loadingStarted {
                    self.modelDiskShortfall = nil
                }
                if event == .ready { await self.publishLoadedModelFolder() }
            }
        }
        Task { await predictionEngine.preload() }
        // Global pause/resume hotkey. Toggles the SAME `isPaused` the menu item
        // does, so pause flows through the one SuggestionSession pause event — no new pause
        // semantics. Ships unassigned; the user records a shortcut in Settings → General. Independent of
        // Accessibility (KeyboardShortcuts installs its own global monitor), so registered unconditionally.
        KeyboardShortcuts.onKeyUp(for: .togglePause) { [weak self] in
            self?.isPaused.toggle()
        }
        // The two shortcuts below, both **unassigned** by default and recorded in
        // Settings → Shortcuts. Force-activate asks for a suggestion where our own cold-start gates
        // declined to offer one; the quiet hotkey silences the current app for the default step (or
        // resumes it). Neither can reach past a setting the user made: force overrides only our gates,
        // and the quiet may only suppress.
        KeyboardShortcuts.onKeyUp(for: .forceActivate) { [weak self] in
            self?.dispatch(.forceActivate)
        }
        KeyboardShortcuts.onKeyUp(for: .temporaryQuiet) { [weak self] in
            self?.toggleTemporaryQuietFromHotkey()
        }
        // Seed the frontmost app the two above act on: the workspace notification only fires on a
        // *change*, so without this the first press before any app switch would have no target.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           front != Bundle.main.bundleIdentifier {
            lastFrontmostBundleID = front
        }
        // Start the idle RAM-reclaim ladder: sets the MLX cache cap + installs the away-signal
        // / memory-pressure / tick sources. Independent of Accessibility, so it runs unconditionally here.
        //
        // Screen-context OCR rides the SAME system signals rather than installing a second set of
        // observers: hard off on lock/display-sleep/system-sleep — where it also
        // drops its cache — and the frontmost feed drives the v1 app-level recency used by the ambient
        // ranking. Installed before `start()` so no signal is missed.
        residencyController.onPowerStateChange = { [weak self] state in
            guard let self else { return }
            state == .off ? self.ocrProvider.setPowerState(.off) : self.ocrProvider.resumeAfterPowerOff()
        }
        residencyController.onModelStateChange = { [weak self] state in
            self?.residencyState = state
        }
        DiagnosticsExporter.modelState = { [weak self] in
            (self?.modelLoadState ?? .loading, self?.residencyState ?? .loaded)
        }
        residencyController.onFrontmostAppChange = { [weak self] bundleID in
            self?.ocrProvider.noteFrontmostApp(bundleID)
            // …and the app a temporary quiet / a force-activate press applies to. Our own activation
            // (opening the menu or Settings) is ignored, which is exactly what makes this usable from a
            // menu item: by the time the user clicks one, we are the frontmost app.
            if let bundleID, bundleID != Bundle.main.bundleIdentifier {
                self?.lastFrontmostBundleID = bundleID
                self?.clearSurfaceVerdict(forSwitchTo: bundleID)
            }
        }
        residencyController.start()
        // Decrypt + parse the style profile now (no-op while the toggle is off) so the first context
        // switch doesn't pay it on the predict path. It stays resident from here — deliberately NOT on the
        // residency ladder (<1 MB, and residency is what makes selection reload-free).
        personalization.preload()
        // …and the counters behind the Statistics pane, so the first flush pays no decode.
        statistics.onTodayWordsChange = { [weak self] words in self?.todayWordsChanged(words) }
        statistics.preload()
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.statistics.dayChanged() }
        }
        // Guide the user through Accessibility: a window with live status + a Request button.
        // (Suppressed under the harness — a run must never pop a window in front of the fixture.)
        if !HarnessEnvironment.suppressOnboarding { PermissionsOnboarding.presentIfNeeded(coordinator: self) }
        startHarnessServerIfRequested()
        // Start the loop. The tap needs Accessibility; until granted this is a no-op until
        // `retryStartIfNeeded()` runs once the user grants it.
        await startTapIfPossible()
        // One-time nudge to disable macOS's own inline prediction. Gated on Accessibility so
        // it doesn't stack over the permission-onboarding window above, and only fires once NextTyped
        // is actually producing ghosts — the only time the double-ghost it warns about is real. On a
        // first launch where the user grants Accessibility mid-session, the nudge defers to the next
        // launch (still "on launch", just the first usable one). One-time + soft-read in the nudge.
        if Permissions.hasAccessibility, !HarnessEnvironment.suppressOnboarding {
            InlinePredictionNudge.presentIfNeeded()
        }
    }

    /// Called when the app is re-activated (e.g. returning from System Settings after granting
    /// Accessibility): bring the loop up if it isn't already running.
    func retryStartIfNeeded() async {
        refreshMenuBarAttention()
        await startTapIfPossible()
    }

    /// Toggle launch-at-login, routed through the menu/Settings toggle. Applies
    /// the change, then re-reads the **authoritative** `SMAppService` status so a denial (the user turned
    /// the app off in System Settings → Login Items) leaves the toggle reflecting reality, not the click.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            acLog("[login]: set launch-at-login=%d failed: %@", enabled ? 1 : 0, String(describing: error))
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    /// Reads the folder the engine loaded its weights from, once a load has succeeded.
    private func publishLoadedModelFolder() async {
        guard modelLoadState == .ready,
              let engine = predictionEngine as? MLXPredictionEngine else { return }
        modelFolder = await engine.loadedModelDirectory
    }

    /// Retry a failed model load: the menu-bar Retry button after a
    /// download failed (no network / low disk). Resets to `.loading` and re-runs the load.
    func retryModelLoad() {
        guard modelLoadState == .failed else { return }
        Task { await predictionEngine.retryLoad() }
    }

    /// Feeds `ModelResidencyPolicy.focusChanged`: editable = the eligibility floor
    /// AND the enablement verdict, the same two questions the predict path asks. The AX probe runs off the
    /// main actor (it has its own short messaging timeouts), so a hung host app cannot block the main
    /// thread; the verdict is read fresh on the main actor, so an Apps-pane switch applies on the next
    /// focus. A skip logs `[gate]: prewarm-skip`.
    private func residencyFocusChanged() {
        focusProbeGeneration += 1
        let generation = focusProbeGeneration
        // Our own window answers AX in-process, on the calling thread, and its SwiftUI views need the
        // main thread, so it is probed here (see `AXContextProvider.currentContext()`).
        if AXContextProvider.ownProcessIsFrontmost() {
            finishResidencyFocusChanged(probe: AXContextProvider.eligibilityFloor(), generation: generation)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let probe = AXContextProvider.eligibilityFloor()
            await self?.finishResidencyFocusChanged(probe: probe, generation: generation)
        }
    }

    /// Counts focus probes so a slow probe for an earlier focus cannot overwrite a newer answer.
    private var focusProbeGeneration = 0

    private func finishResidencyFocusChanged(probe: (rejection: ContextRejection?, bundleID: String?), generation: Int) {
        guard generation == focusProbeGeneration else { return }
        let rejection = FocusEditability.rejection(
            floor: probe.rejection, bundleID: probe.bundleID,
            verdict: { settingsStore.policy.verdict(for: $0) })
        #if DEBUG
        if let rejection { acLog("[gate]: prewarm-skip reason=%@", rejection.rawValue) }
        #endif
        residencyController.focusChanged(editable: rejection == nil, app: probe.bundleID)
    }

    private func startTapIfPossible() async {
        guard Permissions.hasAccessibility else { return }
        // `EventTapController.start` no-ops if the tap is already running.
        await eventTap.start { [weak self] event in
            self?.handleTap(event) ?? .passThrough
        }
        // Authoritative caret-moved / focus-changed trigger (start is idempotent).
        axFocusObserver.onCaretMoved = { [weak self] in self?.dispatch(.hostEcho) }
        axFocusObserver.onFocusChanged = { [weak self] in
            self?.dispatch(.focusChanged)
            // A focus change is a context boundary: drop the KV-cache + flush.
            self?.residencyController.contextSwitch()
            self?.residencyFocusChanged()
            // …and the ONE cadence at which personalization commits what was typed in the field we just
            // left and re-selects the injected exemplars. Riding the same signal is what
            // makes the re-selection free: the cache is being invalidated anyway.
            self?.personalization.contextSwitch()
            // Same boundary for the usage counters: commit what was written in the field we just left,
            // or discard it if that field never proved eligible.
            self?.statistics.contextSwitch()
        }
        axFocusObserver.start()
        installViewportMonitors()
    }

    func stop() {
        #if DEBUG
        harnessServer?.stop()
        #endif
        eventTap.stop()
        // Best-effort write-through of the usage counters. Nothing async is
        // guaranteed to run out of `applicationWillTerminate`, so the store's short debounce — not this
        // call — is what bounds what a quit costs.
        statistics.shutdown()
        axFocusObserver.stop()
        residencyController.stop()
        inFlight?.cancel()
        disarmTask?.cancel()
        for timer in quietTimers.values { timer.cancel() }
        quietTimers.removeAll()
        stopGeometryPoll()
        for monitor in viewportMonitors { NSEvent.removeMonitor(monitor) }
        viewportMonitors.removeAll()
    }

    // MARK: The synchronous tap callback (runs on the main run-loop thread)

    /// Translate a classified `TapEvent` into the reducer's interface and return its synchronous verdict
    /// to macOS. Tab/Esc go through `interceptKey` (their `TapDecision` depends on whether something is
    /// showing); everything else is a `handle` event that passes through. The reducer owns the pause /
    /// screenshot-arm / regenerate decisions, so this method has no policy of its own.
    private func handleTap(_ event: TapEvent) -> TapDecision {
        switch event {
        case .command(let key):
            // `Tab` / `⌥Tab`: the reducer decides suppress-vs-passThrough, and only ever suppresses
            // while a ghost is visible.
            bumpSeq()
            // What is on screen decides whether the write this returns is an *accepted completion* or an
            // applied correction — they produce the same effect shapes, and only a continuation counts
            // . Read before the intercept, because the intercept consumes it.
            let showing = session.currentPresentation
            let (decision, effects) = session.interceptKey(key)
            logIntercept(String(describing: key), decision, effects)
            let acceptedWords = AcceptedWordCount.inEffects(effects, showing: showing)
            statistics.noteAccepted(words: acceptedWords)
            if acceptedWords > 0 { tabPractice.noteAccepted(key) }
            interpret(effects)
            return decision

        case .dismiss:
            // Esc: hard clear + mute proactive regen, but still reach the host — except during an armed
            // ⌘⇧3/4/5 window, where the reducer keeps the ghost.
            bumpSeq()
            let (decision, effects) = session.interceptKey(.escape)
            logIntercept("escape", decision, effects)
            interpret(effects)
            return decision

        case .character(let typed):
            lastTypingAt = pollClock.now   // keep the idle geometry poll quiet while typing
            // Own-inserted capture: typed characters are the primary style-forming source.
            // Buffered here, committed only against the eligibility proof from the predict path.
            personalization.noteTyped(typed)
            // Keystrokes for the measured typing rate. Buffered like the capture above and committed
            // against the same eligibility proof, so menus and password fields never enter the figure.
            statistics.noteTyped()
            dispatch(.typed(typed))
            return .passThrough

        case .caretMove(let deletion, let lineBreak):
            // A delete shrinks the host text — so shrink the capture buffer with it, or the profile would
            // learn characters the user removed. A Return types no character but DOES break the line, and
            // without recording it two lines would be learned as one concatenated run.
            if let deletion { personalization.noteDeletion(deletion) }
            if lineBreak { personalization.noteTyped("\n") }
            dispatch(.caretMove)
            return .passThrough

        case .pointer:
            dispatch(.pointer)
            return .passThrough

        case .viewportChange:
            // A re-paint of `currentPresentation` at fresh pixels — geometry, never a re-decide — so it
            // stays App-side and doesn't enter the reducer.
            handleViewportChange()
            return .passThrough

        case .screenshotShortcut:
            dispatch(.screenshotShortcut)
            return .passThrough

        case .ignore:
            return .passThrough
        }
    }

    // MARK: Event dispatch + effect interpretation (the reducer boundary)

    /// The `interceptKey` counterpart of `dispatch`'s event log: the synchronous Tab/→/Esc verdicts were
    /// previously invisible in the DEBUG log. Logs even with no effects — for
    /// intercepts the *decision* (and the armed-Esc no-op) is the interesting part; fires only on
    /// intercept-candidate keys, not per keystroke.
    private func logIntercept(_ key: String, _ decision: TapDecision, _ effects: [Effect]) {
        #if DEBUG
        acLog("[session]: intercept(%@) → %@%@", key, String(describing: decision),
              effects.isEmpty ? "" : ", " + describe(effects))
        #endif
    }

    /// Hand an `Event` to the reducer and interpret the resulting effects. The single place AX/timer
    /// callbacks re-enter the loop.
    private func dispatch(_ event: Event, caret: CaretInfo? = nil) {
        bumpSeq()
        let effects = session.handle(event)
        #if DEBUG
        // Settings flips log even when they produce nothing: pause/resume is a user-visible feature
        // whose no-op arms are exactly the interesting ones, and a silent `[]` is why the missing
        // resume-regeneration had to be found by a human rather than read out of a run log
        // . Input events stay effect-gated — they fire per keystroke.
        if !effects.isEmpty || Self.alwaysLogged(event) {
            acLog("[session]: %@ → %@", describe(event), effects.isEmpty ? "no effects" : describe(effects))
        }
        #endif
        interpret(effects, caret: caret)
    }

    #if DEBUG
    /// The trigger as it appears in the `[skeleton]` line. `caretMove` is kept verbatim for the
    /// ordinary navigation case — scenarios and run bundles grep it — while the accept refill names
    /// itself, because "which kind of caret move was this" is exactly what `WordCompletionGate`
    /// decides on.
    private static func describe(_ trigger: SuggestionTrigger) -> String {
        switch trigger {
        case .typing: return "typing"
        case .acceptRefill: return "acceptRefill"
        default: return "caretMove"
        }
    }

    /// Events logged regardless of whether they produced effects — see `dispatch`.
    private static func alwaysLogged(_ event: Event) -> Bool {
        switch event {
        case .setPaused, .setFIMEnabled, .setCompletionLength, .setSpellingVariant,
             .setTrailingPunctuation, .setBatteryPosture, .setEscBehaviour, .fieldPauseExpired: return true
        // A force-activate that produced nothing is precisely the interesting case:
        // a press answered by silence is the complaint this feature exists to avoid making.
        case .forceActivate, .temporaryQuietStarted, .temporaryQuietEnded: return true
        // Once per ghost, and the one line that says when `Tab` became ours.
        case .ghostSettled: return true
        default: return false
        }
    }
    #endif

    /// Execute a batch of effects **in list order**, carrying an already-fetched caret through to any
    /// `.present` so a freshly-predicted ghost renders at the caret the predict Task already read.
    ///
    /// List order is part of the reducer's contract — the reducer decides *what*, in a list whose order is
    /// meaningful, and this is the runtime that executes it — but it used to hold only by accident. Every
    /// effect ran synchronously during the walk except a `.present` of something, which scheduled a
    /// detached `Task` and returned; that paint therefore landed after the whole rest of the batch. The
    /// two arms of one effect case ran on two different schedules, so `[.present(x),.present(.none)]`
    /// hid *first* and painted second — the reverse of what the reducer asked for
    /// . Nothing produces that batch today; this was a trap, and its
    /// failure mode is a ghost painted over `reducer=none`, the class of bug it took the harness to catch.
    ///
    /// So: the walk runs each effect in turn, and when it reaches the one effect that **cannot** finish
    /// synchronously — painting needs the caret, which is an `await` onto the `CaretLocator` actor — it
    /// hands the *remainder of the batch* to the same `Task`, after the paint. The synchronous hide is
    /// untouched and stays immediate whenever it precedes a paint, which is what keeps a stale ghost from
    /// lingering. One batch relies on this on purpose: a fresh ghost arrives as
    /// `[.present(ghost),.scheduleSettle(n)]`, and running the settle effect behind the paint is what
    /// starts the Tab grace clock when the ghost is on screen, not when it was decided (on Electron
    /// the caret read before the paint can lag). Every other batch still ends in its `.present`.
    ///
    /// Deliberately neither of the two shapes the ticket sketched: making the paint synchronous would
    /// mean hoisting the caret read out of `present`, which `repaint()` (the geometry poll, whose whole
    /// point is a *fresh* read) cannot give up; and interpreting the whole batch inside one Task would
    /// give up the immediate hide the comment below protects. This keeps both.
    private func interpret(_ effects: [Effect], caret: CaretInfo? = nil) {
        for (index, effect) in effects.enumerated() {
            switch effect {
            case .insert(let text):
                inserter.insert(text)
                // An accepted ghost is own text too — the style-forming source is "typed **+**
                // accepted", and this is the synthetic-key path that inserts it.
                personalization.noteOwnInsert(text)
            case .replace(let charactersBack, let replacement):
                inserter.replace(charactersBack: charactersBack, with: replacement)
                // Mirror the edit in the capture buffer: the misspelling the user typed is gone, the accepted
                // correction takes its place.
                for _ in 0..<charactersBack { personalization.noteDeletion(.backward) }
                personalization.noteOwnInsert(replacement)
            case .present(.none):
                // Hide synchronously so a stale ghost vanishes immediately (no lingering overlap).
                overlay.hide()
                stopGeometryPoll()
                logHide()
            case .present(let presentation):
                // The asynchronous one. Everything still queued behind it runs after it, on the same Task,
                // so the batch keeps the order the reducer wrote it in.
                let remainder = Array(effects[(index + 1)...])
                Task { [weak self] in
                    guard let self else { return }
                    await self.present(presentation, caret: caret)
                    self.interpret(remainder, caret: caret)
                }
                return
            case .schedulePredict(let trigger, let debounceMs):
                runPredict(trigger: trigger, debounceMs: debounceMs)
            case .runInference:
                // `PredictRun` is this effect's one named consumer: it plucks the case out of
                // phase 1's list because the work continues on the SAME Task, and hands everything else
                // back here as a batch. So reaching this arm means an effect list containing
                // `.runInference` was executed by something other than the run — the effect would be
                // silently dropped, which is exactly what the old `break` did and why the case looked
                // unhandled.
                //
                // Deliberately an assertion rather than a typed phase-1 return: giving phase 1 its own
                // return type so the enum holds only executable cases is the cleaner typing and was
                // **rejected**, because it reopens the reducer's single-door
                // `handle(_:) -> [Effect]` interface as a side effect of a structural change.
                assertionFailure("Effect.runInference reached the interpreter; its only consumer is PredictRun")
            case .cancelInFlight:
                inFlight?.cancel()
            case .scheduleScreenshotDisarm(let seconds):
                runScreenshotDisarm(seconds: seconds)
            case .scheduleSettle(let generation):
                // Reached after the `.present` it follows has painted (the walk resumes behind the
                // paint), so the grace counts from what the user could actually see.
                runSettleClock(generation: generation)
            case .scheduleFieldPauseExpiry(let seconds, let generation):
                runFieldPauseExpiry(seconds: seconds, generation: generation)
            case .surfaceVerdict(let verdict):
                noteSurfaceVerdict(verdict)
            case .logGate(let token):
                // Observability only: a gate suppression is otherwise
                // indistinguishable in the log from every other `present(none)`, and both bars' operating
                // conditions — "local and quiet", and whether N = 8 is calibrated — are only answerable as
                // a rate. DEBUG-only, like every other `acLog` consumer of these tokens.
                // Release counts the token in the diagnostics tally (first token only) but logs nothing.
                #if DEBUG
                acLog("[gate]: %@", token)
                #else
                DiagnosticsTallyHub.shared.record(line: "[gate]: \(token)")
                #endif
            }
        }
    }

    // MARK: Prediction (the two-phase async seam)

    /// The `.schedulePredict` interpreter: one cancelable Task (single slot) whose **body** is
    /// the pure-Core `PredictRun`. The sequence — debounce, context, caret, phase 1,
    /// spell-check, predict, phase 2, and the six `Task.isCancelled` checks between them — lives in the
    /// module and is unit-tested there. What stays here is the slot and the real adapters.
    ///
    /// **Cancellation is inherited structurally**: cancelling this Task is observed by the module's own
    /// `Task.isCancelled` checks, so a superseded pipeline still never dispatches a stale event. Nothing
    /// about the slot moved — only the body did.
    ///
    /// **The retain cycle is broken at the adapters, not here** — `PredictRun` is a struct holding eight
    /// strong existentials, so an adapter with a strong coordinator reference would make
    /// `coordinator → Task → PredictRun → adapter → coordinator` a cycle. Every adapter that touches the
    /// coordinator holds it **weakly** instead.
    ///
    /// The deleted body did the same job differently, and the difference is worth naming: it was
    /// `[weak self]` + `guard let self`, which aborted a run whose coordinator was *already* gone and
    /// then held it strongly for the rest — so a mid-run deallocation could not happen at all. Holding it
    /// strongly is exactly what must not come back, so the abort is reproduced in its old position (the
    /// `guard` below, before the debounce) and mid-run liveness is enforced where it costs the least:
    /// `LivenessGatedAssembler` answers `nil`, which is the one gate the whole tail hangs off — no focus
    /// registration, no caret read, no eligibility proof, and phase 1 then drops the run.
    private func runPredict(trigger: SuggestionTrigger, debounceMs: Int) {
        let run = PredictRun<CaretInfo>(
            wait: TaskSleepWait(),
            context: LivenessGatedAssembler(coordinator: self, assembler: contextAssembler),
            focus: FocusTrackingAdapter(observer: axFocusObserver),
            caret: CaretReadingAdapter(locator: caretLocator),
            reducer: ReducerPortAdapter(coordinator: self),
            spellChecker: spellChecker,
            engine: predictionEngine,
            activity: ActivitySinkAdapter(coordinator: self))
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            // The old `guard let self`, in its old place: a coordinator already gone when the Task starts
            // aborts before the debounce rather than sleeping out a run nobody will read.
            guard self != nil else { return }
            await run.run(trigger: trigger, debounceMs: debounceMs)
        }
    }

    // MARK: The App side of the `PredictRun` ports
    //
    // Four bridging methods, each the one thing Core cannot do for itself. They are `fileprivate` so the
    // adapters at the foot of this file — deliberately separate types, so each holds only what it needs —
    // can reach them.

    /// The reducer port's `handle`: bump the harness sequence counter, then hand the event to the
    /// reducer.
    ///
    /// Deliberately **no** `[session]` log line. The predict path calls `session.handle` directly and has
    /// always bypassed `dispatch`, so no such line exists today for `.contextReady` or
    /// `.predictionArrived`; adding one here would put three new DEBUG lines into every predict, and into
    /// every harness run bundle. Worth doing on purpose one day, never worth doing as a side effect of a
    /// cutover.
    fileprivate func predictHandle(_ event: Event) -> [Effect] {
        bumpSeq()
        return session.handle(event)
    }

    /// The reducer port's `execute`: the batch walk, carrying the caret **this run** read so a
    /// freshly-decided ghost paints where the predict looked. The list-order guarantee
    ///  lives in `interpret(_:caret:)` and is untouched by the cutover.
    fileprivate func predictExecute(_ effects: [Effect], caret: CaretInfo?) {
        interpret(effects, caret: caret)
    }

    /// The `[skeleton]` line — an observable harness scenarios assert on, which is why the port requires
    /// it and the module calls it only when a context was obtained.
    fileprivate func predictNoteContextObtained(_ context: TypingContext, trigger: SuggestionTrigger) {
        #if DEBUG
        acLog("[skeleton]: %@ — %d chars before caret, app=%@",
              Self.describe(trigger),
              context.textBeforeCaret.count, context.bundleID ?? "?")
        #endif
    }

    /// The one post-predict activity signal, fanned out (one sink, because residency, the OCR
    /// cadence and the harness `predicts` counter are the same statement — they fire together and only
    /// after a **real** predict, never on the gated correction-only path).
    ///
    /// The `#if DEBUG` split lives here rather than in the module: `PredictRun` builds the whole payload
    /// unconditionally, because a payload that exists only in DEBUG is a payload no test can assert on.
    /// Residency and OCR fire in every configuration; only the three harness counters are DEBUG-gated,
    /// which is exactly where the `#if DEBUG` sat before the cutover.
    fileprivate func predictRecordActivity(_ activity: PredictActivity) {
        #if DEBUG
        predictCount += 1
        // `seq` is read BEFORE the final `.predictionArrived` bumps it — same as before the cutover,
        // where these three assignments sat between the predict and the last `bumpSeq()`.
        lastPredict = (seq, activity.suggestionText, activity.elapsedMs,
                       activity.trigger == .typing ? "typing" : "caretMove")
        lastSurface = (activity.app ?? "?", activity.prefixLength)
        #endif
        // Prediction-relevant activity: a predict ran into an editable, gates-passed field,
        // so this — NOT raw keystrokes — is what keeps the model warm and resets the idle clock.
        residencyController.predictionActivity(app: activity.app)
        // The same activity signal gates the OCR cadence — writing keeps
        // screen-context fresh; gaming / watching a film runs no passes at all.
        ocrProvider.notePredictionActivity()
    }

    // MARK: Screenshot disarm timer

    /// Start/restart the 12 s screenshot-disarm clock; on elapse, tell the reducer to disarm. The
    /// arm/disarm *state* is the reducer's — this is just the timer (the reducer stays time-free).
    private func runScreenshotDisarm(seconds: Int) {
        disarmTask?.cancel()
        disarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(seconds)))
            guard let self, !Task.isCancelled else { return }
            self.dispatch(.screenshotDisarmExpired)
        }
    }

    // MARK: Tab grace clock

    /// Start the grace clock for `generation`, superseding any older one; on elapse, tell the reducer
    /// that ghost has settled. The cancel is load-bearing: there is one clock, and the reducer ignores a
    /// stale generation's `.ghostSettled`. So an older generation whose paint finished late must not
    /// take the clock from a newer one, or the newer ghost never settles and its `Tab` reaches the host
    /// as a literal tab. `settleSlot` refuses that older claim.
    private func runSettleClock(generation: Int) {
        guard settleSlot.claim(generation: generation) else {
            #if DEBUG
            acLog("[session]: settle clock for generation %d skipped, a newer one owns it", generation)
            #endif
            return
        }
        settleTask?.cancel()
        let ms = Self.tabGraceMs
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard let self, !Task.isCancelled else { return }
            self.dispatch(.ghostSettled(generation: generation))
        }
    }

    /// The Esc field-pause clock: on elapse, tell the reducer which pause ran out. A newer Esc
    /// replaces the task; the generation guards a timer that fires anyway.
    private func runFieldPauseExpiry(seconds: Int, generation: Int) {
        fieldPauseTask?.cancel()
        fieldPauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(seconds)))
            guard let self, !Task.isCancelled else { return }
            self.dispatch(.fieldPauseExpired(generation: generation))
        }
    }

    // MARK: Viewport changes (zoom / scroll) — a pure re-paint, App-side

    /// Trackpad pinch-zoom is an `NSEvent` gesture that a `CGEventTap` cannot see (there's no
    /// `CGEventType` for magnify), so without this the overlay freezes at its pre-zoom frame while
    /// the host text rescales. Scroll rides the tap; these monitors add the zoom gesture. Both
    /// funnel into `handleViewportChange`. Idempotent — safe to call on every activation.
    private func installViewportMonitors() {
        guard viewportMonitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.magnify, .smartMagnify]) { [weak self] _ in
            MainActor.assumeIsolated {
                #if DEBUG
                acLog("[viewport]: .magnify gesture (global monitor)")
                #endif
                self?.handleViewportChange()
            }
        }
        if let global { viewportMonitors.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleViewportChange() }
            return event
        }
        if let local { viewportMonitors.append(local) }
    }

    /// Zoom or scroll moved/resized the host text under a VISIBLE suggestion. The caret didn't move,
    /// so we re-paint the SAME presentation (no re-inference, no re-decide) at the fresh geometry: hide
    /// it during the gesture, then re-render once it settles (~150 ms). A bare scroll/zoom with nothing
    /// on screen is ignored. Reuses the single `inFlight` slot, so any real edit supersedes a pending
    /// reposition and a gesture flood collapses to one hide + one re-render.
    private func handleViewportChange() {
        if isPaused { return }
        guard session.currentPresentation != .none else { return }
        #if DEBUG
        acLog("[viewport]: change → hide + reposition")
        #endif
        overlay.hide()
        stopGeometryPoll()                       // stay hidden during the gesture; repaint restarts it
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, !self.isPaused else { return }
            await self.repaint()
        }
        // The slot may have held a predict run still decoding behind an early ghost: tell the
        // reducer it died, so the early ghost stops waiting for a full decode that never lands. A refill
        // this schedules cancels the reposition above and takes the slot; that run paints anew.
        dispatch(.runCancelled)
    }

    // MARK: Rendering

    /// Paint a presentation. Correction → prefix-diff strike; continuation → the sliding display window;
    /// `.none` → hide. The App owns caret geometry + inline-vs-bubble; the reducer only said *what*.
    private func present(_ presentation: Presentation, caret providedCaret: CaretInfo?) async {
        switch presentation {
        case .none:
            overlay.hide()
            stopGeometryPoll()
            logHide()
        case .correction(let correction):
            let caret: CaretInfo?
            if let providedCaret { caret = providedCaret } else { caret = await caretLocator.caretInfo() }
            let wordRect = await caretLocator.wordBounds(charactersBack: correction.charactersBackFromCaret)
            guard session.currentPresentation == presentation else { return }   // superseded while awaiting
            overlay.showCorrection(correction.original, replacement: correction.replacement,
                                   wordRect: wordRect, caret: caret)
            recordCaret(caret)
            ensureGeometryPoll()
            logPresent()
        case .continuation(let ghost):
            let caret: CaretInfo?
            if let providedCaret { caret = providedCaret } else { caret = await caretLocator.caretInfo() }
            // Re-paint guard: this paint was decided BEFORE the caret `await`; if the reducer moved on
            // meanwhile (a type-along exhausted the buffer → `present(none)` hid synchronously), painting
            // now would resurrect a ghost the reducer no longer holds — the harness caught a lone "s"
            // visible over `reducer=none` (scenario boundary-refill). Paint only what is current.
            guard session.currentPresentation == presentation else { return }
            // Paint only the sliding display window (≤5 words); the buffer keeps the rest so `Tab` peels
            // it with no re-inference. Geometry is computed from the drawn window.
            // `consumesPrecedingSpace`: the accept will replace the space before the caret, so the
            // ghost is painted one space-width further left — the preview must read `Winter. Es`,
            // which is what `Tab` produces, not `Winter. Es`.
            overlay.showContinuation(ghost.text,
                                     consumesPrecedingSpace: ghost.consumesPrecedingSpace,
                                     caret: caret)
            tabPractice.noteGhost()
            recordCaret(caret)
            ensureGeometryPoll()
            logPresent()
        }
    }

    /// Re-paint whatever the reducer currently wants shown, at fresh caret geometry — used by the
    /// viewport reposition and the idle geometry poll. Pure re-paint: it never re-decides the suggestion.
    private func repaint() async {
        await present(session.currentPresentation, caret: nil)
    }

    // MARK: Geometry poll (catches zoom/scroll the gesture monitors miss)

    /// Poll the caret geometry while a suggestion is visible. Idempotent — one task at a time.
    private func ensureGeometryPoll() {
        guard geometryPoll == nil else { return }
        geometryPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                await self.pollCaretGeometry()
            }
        }
    }

    private func stopGeometryPoll() {
        geometryPoll?.cancel()
        geometryPoll = nil
        lastProbeRect = nil
        shownCaret = nil
        #if DEBUG
        pollTickCount = 0
        pollRenderCount = 0
        #endif
    }

    /// Cheap probe (caret rect only). If it moved/resized under a still-visible suggestion (zoom,
    /// scroll, window move) **while idle** without any event firing, re-paint at the fresh geometry. The
    /// `GeometryPoll.shouldRerender` decision (pure Core) suppresses the tick while typing flows — the
    /// typing path already re-rendered that keystroke. The baseline rect is refreshed every
    /// tick (incl. while typing-paused) so the first idle tick compares against the current caret.
    private func pollCaretGeometry() async {
        guard !isPaused, session.currentPresentation != .none else { stopGeometryPoll(); return }
        guard let probe = await caretLocator.caretRectProbe() else { return }
        let baseline = lastProbeRect
        lastProbeRect = probe
        let shouldRender = GeometryPoll.shouldRerender(
            probe: caretProbe(probe),
            baseline: baseline.map(caretProbe),
            typingActive: isTypingActive())
        if shouldRender {
            #if DEBUG
            acLog("[viewport]: poll detected idle geometry change → re-render")
            #endif
            await repaint()
        }
        recordPollChurn(rendered: shouldRender)
    }

    /// True while the typing path is actively re-rendering (a keystroke within `typingQuietWindow`),
    /// so the idle geometry poll defers to it instead of firing a redundant render.
    private func isTypingActive() -> Bool {
        guard let lastTypingAt else { return false }
        return pollClock.now - lastTypingAt < typingQuietWindow
    }

    /// Bridge the AX `CGRect` caret probe into the pure-Core `CaretProbe` the poll decision consumes
    /// (mirrors `CaretLocator.glyphBox` → `GlyphBox`). Only origin + height matter for change detection.
    private func caretProbe(_ r: CGRect) -> CaretProbe {
        CaretProbe(minX: Double(r.minX), minY: Double(r.minY), height: Double(r.height))
    }

    /// Record one poll tick (and whether it re-rendered) and periodically surface the renders-vs-ticks
    /// ratio (~every 5 s) so the poll's churn is measurable, not inferred from the per-fire log line.
    /// DEBUG-only tooling — a no-op in release.
    #if DEBUG
    private func recordPollChurn(rendered: Bool) {
        pollTickCount += 1
        if rendered { pollRenderCount += 1 }
        guard pollTickCount % 25 == 0 else { return }
        let pct = Double(pollRenderCount) / Double(pollTickCount) * 100
        acLog("[viewport]: poll churn %d/%d renders/ticks (%.0f%%) over this poll window",
              pollRenderCount, pollTickCount, pct)
    }
    #else
    private func recordPollChurn(rendered: Bool) {}
    #endif

    // MARK: Harness channel — DEBUG-only

    private func bumpSeq() {
        #if DEBUG
        seq += 1
        #endif
    }

    private func recordCaret(_ caret: CaretInfo?) {
        shownCaret = caret
        #if DEBUG
        lastCaret = caret
        #endif
    }

    /// The presentation-truth log line: what the overlay *actually* shows after a paint, stamped with
    /// `seq` so it joins the channel snapshot. Reads the panel, not the reducer, on purpose.
    private func logPresent() {
        #if DEBUG
        let st = overlay.state()
        let m = st.main
        acLog("[present] seq=%d kind=%@ mode=%@ visible=%d text=\"%@\" frame=%.0f,%.0f,%.0f,%.0f%@",
              seq, m.kind, m.mode, m.visible ? 1 : 0, m.text,
              m.frame.minX, m.frame.minY, m.frame.width, m.frame.height,
              st.overflow.visible ? " overflow=\"\(st.overflow.text)\"" : "")
        #endif
    }

    private func logHide() {
        #if DEBUG
        acLog("[hide] seq=%d", seq)
        #endif
    }

    private func startHarnessServerIfRequested() {
        #if DEBUG
        guard let path = HarnessEnvironment.socketPath else { return }
        // Say what the harness overrode, not just that it launched. A neutralised learning denylist is
        // invisible in a bundle otherwise — and "the run's outcome depended on state nothing recorded"
        // is the defect this override exists to fix; leaving the override itself
        // unrecorded would move that silence one layer up rather than end it.
        if HarnessEnvironment.neutralisesLearningDenylist {
            let denied = settingsStore.learningDisabledBundleIDs
            acLog("[harness]: learning denylist neutralised (%d entr%@ ignored)",
                  denied.count, denied.count == 1 ? "y" : "ies")
        }
        let server = HarnessServer(path: path) { [weak self] json in
            await MainActor.run {
                let request = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
                let reply = self?.handleHarnessRequest(request) ?? ["error": "gone"]
                let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
        }
        server.start()
        harnessServer = server
        #endif
    }

    #if DEBUG
    private func handleHarnessRequest(_ request: [String: Any]) -> [String: Any] {
        switch request["cmd"] as? String {
        case "ping":
            return ["ok": true, "t": AppLogClock.millisSinceLaunch()]
        case "snapshot":
            return snapshot()
        case "accessibility.request":
            // Raise the system Accessibility prompt for THIS app (the onboarding window is suppressed
            // under the harness, so this is how a run can ask for the grant without a UI click).
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(opts)
            return ["ok": true, "trusted": trusted]
        case "onboarding.open":
            // The onboarding window is suppressed under the harness; a scenario opens it on purpose
            // to drive the Tab demo with real keys.
            PermissionsOnboarding.present(coordinator: self)
            return ["ok": true]
        case "reset":
            inFlight?.cancel()
            disarmTask?.cancel()
            settleTask?.cancel()
            settleSlot = SettleClockSlot()
            fieldPauseTask?.cancel()
            session = SuggestionSession(tabGrace: TabGrace.isEnabled(milliseconds: Self.tabGraceMs))
            interpret(session.handle(.setCompletionLength(settingsStore.completionLength)))
        interpret(session.handle(.setTrailingPunctuation(settingsStore.trailingPunctuation)))
            interpret(session.handle(.setEscBehaviour(settingsStore.escBehaviour)))
            interpret(session.handle(.setSpellingVariant(settingsStore.spellingVariant)))
            interpret(session.handle(.setFIMEnabled(settingsStore.midTextCompletionEnabled)))
            interpret(session.handle(.setBatteryPosture(lastBatteryPosture)))
            overlay.hide()
            stopGeometryPoll()
            predictCount = 0
            lastPredict = nil
            Task { [predictionEngine, fakeEngine] in
                await fakeEngine?.reset()
                await predictionEngine.invalidateKVCache()
            }
            acLog("[harness]: reset seq=%d", seq)
            return ["ok": true, "seq": seq]
        case "diagnostics.export":
            guard let path = request["path"] as? String, path.hasPrefix("/") else { return ["error": "path"] }
            return DiagnosticsExporter.exportForHarness(to: path)
        case "fake.script":
            guard let fake = fakeEngine else { return ["error": "engine is not fake"] }
            let raw = request["rules"] as? [[String: Any]] ?? []
            let rules = raw.map {
                FakePredictionEngine.Rule(suffix: $0["suffix"] as? String ?? "",
                                          answer: $0["answer"] as? String ?? "",
                                          latencyMs: $0["latencyMs"] as? Int ?? 0)
            }
            Task { await fake.setRules(rules) }
            acLog("[harness]: fake.script rules=%d", rules.count)
            return ["ok": true, "rules": rules.count]
        default:
            return ["error": "unknown cmd"]
        }
    }

    /// The snapshot: reducer intent + overlay fact side by side.
    private func snapshot() -> [String: Any] {
        let reducer: [String: Any]
        switch session.currentPresentation {
        case .none:                   reducer = ["kind": "none"]
        case .continuation(let g):    reducer = ["kind": "continuation", "text": g.text,
                                                 "settled": session.isPresentationSettled]
        case .correction(let c):      reducer = ["kind": "correction", "text": "\(c.original)→\(c.replacement)",
                                                 "settled": session.isPresentationSettled]
        }
        let st = overlay.state()
        func panel(_ p: OverlayWindowController.PanelState) -> [String: Any] {
            ["visible": p.visible, "kind": p.kind, "text": p.text, "mode": p.mode,
             "frame": [p.frame.minX, p.frame.minY, p.frame.width, p.frame.height]]
        }
        var out: [String: Any] = [
            "seq": seq,
            "t": AppLogClock.millisSinceLaunch(),
            "paused": isPaused,
            "model": modelLoadState.menuLabel,
            "modelReady": modelLoadState.canPredict,
            "engine": fakeEngine == nil ? "real" : "fake",
            "accessibility": Permissions.hasAccessibility,
            "reducer": reducer,
            "overlay": ["main": panel(st.main), "overflow": panel(st.overflow)],
            "predictCount": predictCount,
            "status": surfaceStatus.token,
            "menuBarWords": menuBarWords,
        ]
        if let lp = lastPredict {
            out["lastPredict"] = ["seq": lp.seq, "text": lp.text, "ms": lp.ms, "trigger": lp.trigger]
        }
        if let ls = lastSurface {
            out["surface"] = ["bundleID": ls.bundleID, "charsBefore": ls.charsBefore]
        }
        if let c = lastCaret {
            out["caret"] = ["x": c.axRect.minX, "y": c.axRect.minY,
                            "w": c.axRect.width, "h": c.axRect.height,
                            "marker": c.usesMarkerGeometry, "textToRight": c.hasTextToRight]
        }
        return out
    }
    #endif

    // MARK: DEBUG describe helpers (event/effect-boundary observability)

    #if DEBUG
    private func describe(_ event: Event) -> String {
        switch event {
        case .typed(let s):              return "typed(\(s.debugDescription))"
        case .caretMove:                 return "caretMove"
        case .pointer:                   return "pointer"
        case .screenshotShortcut:        return "screenshotShortcut"
        case .screenshotDisarmExpired:   return "screenshotDisarmExpired"
        case .hostEcho:                  return "hostEcho"
        case .focusChanged:              return "focusChanged"
        case .contextReady(_, _, let t, _): return "contextReady(\(t))"
        case .predictionArrived:         return "predictionArrived"
        case .typoSuspected:             return "typoSuspected"
        case .firstWordsArrived:         return "firstWordsArrived"
        case .eventTapBlinded:           return "eventTapBlinded"
        case .runCancelled:              return "runCancelled"
        case .setPaused(let p):          return "setPaused(\(p))"
        case .setFIMEnabled(let e):      return "setFIMEnabled(\(e))"
        case .setCompletionLength(let l): return "setCompletionLength(\(l.rawValue))"
        case .setBatteryPosture(let p):  return "setBatteryPosture(onDemand=\(p.onDemandOnly) cap=\(p.decodeWordCap))"
        case .setSpellingVariant(let v): return "setSpellingVariant(\(v.rawValue))"
        case .setTrailingPunctuation(let v): return "setTrailingPunctuation(\(v.rawValue))"
        case .setEscBehaviour(let v): return "setEscBehaviour(\(v.rawValue))"
        case .fieldPauseExpired(let g): return "fieldPauseExpired(\(g))"
        case .forceActivate:             return "forceActivate"
        case .temporaryQuietStarted(let id):
            return "temporaryQuietStarted(\(id))"
        case .temporaryQuietEnded(let id, let explicit):
            return "temporaryQuietEnded(\(id), \(explicit ? "resumed" : "expired"))"
        case .ghostSettled(let generation): return "ghostSettled(\(generation))"
        }
    }

    private func describe(_ effects: [Effect]) -> String {
        effects.map { effect in
            switch effect {
            case .insert:                  return "insert"
            case .replace:                 return "replace"
            case .present(.none):          return "present(none)"
            case .present(.continuation):  return "present(continuation)"
            case .present(.correction):    return "present(correction)"
            case .schedulePredict(let t, _): return "schedulePredict(\(t))"
            case .runInference:            return "runInference"
            case .cancelInFlight:          return "cancelInFlight"
            case .scheduleScreenshotDisarm: return "scheduleScreenshotDisarm"
            case .scheduleSettle(let generation): return "scheduleSettle(\(generation))"
            case .scheduleFieldPauseExpiry: return "scheduleFieldPauseExpiry"
            case .logGate(let token):      return "logGate(\(token))"
            case .surfaceVerdict(let v):   return "surfaceVerdict(\(v))"
            }
        }.joined(separator: ", ")
    }
    #endif
}

// MARK: - `PredictRun` adapters
//
// `PredictRun`'s ports in their real form. Each is a separate type holding only what it needs, and every
// one that reaches `AppCoordinator` holds it **weakly** — see `runPredict` for why that is the whole
// retain-cycle story and what it replaces.

/// The debounce (`PredictWaiting`).
///
/// `try? await Task.sleep` and nothing else: sleep-then-cancel, so a newer keystroke cancelling the
/// enclosing Task wakes this immediately and the module's `Task.isCancelled` check turns that into a
/// dropped run. **`Task.sleep` throwing on cancellation is load-bearing** — a non-cancellable wait would
/// leave every superseded run sitting out its full debounce before noticing. The duration is reducer
/// policy and arrives as a parameter (`SuggestionSession.debounceMs(for:)`).
@MainActor
private struct TaskSleepWait: PredictWaiting {
    func wait(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// Both consumers of the **one** eligibility proof, behind Core's single `ContextPersonalizing` port.
///
/// The proof is one fact — "the predict path produced a real context for this surface" — and two
/// subsystems ride it: own-text capture and usage statistics (
/// which counts only what was accepted into a surface that proved eligible). Fanning out **here** keeps
/// that shared dependency visible and keeps `ContextAssembler` from growing a second personalization-
/// shaped parameter for a collaborator that is not personalization. Whoever adds a third consumer adds
/// it to this type, not to the Core seam.
///
/// `segment` belongs to personalization alone — statistics has no notion of a prompt-front segment.
@MainActor
private struct EligibilityProofFanout: ContextPersonalizing {
    let personalization: PersonalizationController
    let statistics: UsageStatisticsController

    func noteEligibleSurface(bundleID: String?) {
        personalization.noteEligibleSurface(bundleID: bundleID)
        statistics.noteEligibleSurface(bundleID: bundleID)
    }

    func segment(for context: TypingContext) async -> String? {
        await personalization.segment(for: context)
    }
}

/// The context assembler behind a **liveness gate**.
///
/// Not a delegation for its own sake: it is the one place mid-run coordinator liveness can be enforced
/// without holding the coordinator strongly for the run's duration, and it is enough on its own, because
/// a `nil` context is what skips the focus registration and the caret read and drops the run at phase 1.
/// Assembling anyway would run the eligibility proof for a surface no longer being written into.
@MainActor
private struct LivenessGatedAssembler: ContextAssembling {
    weak var coordinator: AppCoordinator?
    let assembler: ContextAssembling

    func assembledContext() async -> ContextOutcome? {
        guard coordinator != nil else { return nil }
        return await assembler.assembledContext()
    }
}

/// Registering the focused element's selection notification — the `hostEcho` source. Holds the observer
/// directly (it does not reference the coordinator except through its own `[weak self]` callbacks), so
/// no weak dance is needed here.
@MainActor
private struct FocusTrackingAdapter: FocusTracking {
    let observer: AXFocusObserver
    func ensureTrackingFocusedElement() { observer.ensureTrackingFocusedElement() }
}

/// The caret read, filled in with the App's `CaretInfo` (a generic pass-through: Core carries
/// the value from here to the paint without ever looking inside it). `CaretLocator` is an actor and
/// knows nothing of the coordinator, so this holds it strongly.
@MainActor
private struct CaretReadingAdapter: CaretReading {
    typealias Caret = CaretInfo
    let locator: CaretLocator

    func readCaret() async -> CaretReadout<CaretInfo>? {
        guard let info = await locator.caretInfo() else { return nil }
        return CaretReadout(caret: info, facts: CaretFacts(hasTextToRight: info.hasTextToRight))
    }
}

/// The run's door to the reducer (not reopened). **Weak** coordinator.
/// A deallocated coordinator answers `[]`, which drops the run at phase 1 — the `guard let inference`
/// there returns before anything downstream can run.
@MainActor
private struct ReducerPortAdapter: SuggestionReducing {
    typealias Caret = CaretInfo
    weak var coordinator: AppCoordinator?

    func handle(_ event: Event) -> [Effect] { coordinator?.predictHandle(event) ?? [] }

    func execute(_ effects: [Effect], caret: CaretInfo?) {
        coordinator?.predictExecute(effects, caret: caret)
    }

    func noteContextObtained(_ context: TypingContext, trigger: SuggestionTrigger) {
        coordinator?.predictNoteContextObtained(context, trigger: trigger)
    }
}

/// The one post-predict activity sink, fanned out by the coordinator. **Weak** coordinator.
@MainActor
private struct ActivitySinkAdapter: PredictActivityRecording {
    weak var coordinator: AppCoordinator?
    func recordPredict(_ activity: PredictActivity) { coordinator?.predictRecordActivity(activity) }
}
