import Foundation
import NextTypedCore

/// `UserDefaults`-backed preferences, exposed to the loop as an
/// `AppEnablementPolicy`. Persists ONLY preferences —
/// never typed text (the privacy spine).
/// `@unchecked Sendable`: the class holds no mutable state of its own — every read goes straight to
/// `UserDefaults`, which is documented as thread-safe but isn't annotated `Sendable`. That is what lets
/// the screen-OCR provider read the live settings from its own background queue rather than caching a
/// copy that could go stale behind a Settings change.
final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    /// `defaults` is injectable so a test can use a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Keys {
        static let globallyEnabled = "globallyEnabled"
        static let overrides = "appOverrides"
        static let screenOCREnabled = "screenOCREnabled"
        static let personalizationEnabled = "personalizationEnabled"
        static let learningDisabled = "personalizationLearningDisabledBundleIDs"
        static let midTextCompletionEnabled = "midTextCompletionEnabled"
        static let completionLength = "completionLength"
        static let spellingVariant = "spellingVariant"
        static let trailingPunctuation = "trailingPunctuation"
        static let interceptBindings = "interceptBindings"
        static let escBehaviour = "escBehaviour"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let appDefaultMode = "appDefaultMode"
        static let siteRules = "siteRules"
        static let disabledLanguages = "disabledLanguages"
        static let modelUnloadAfterIdle = "modelUnloadAfterIdle"
        static let modelChoice = "modelChoice"
        static let spellingFixesEnabled = "spellingFixesEnabled"
        static let windowContextEnabled = "windowContextEnabled"
        static let replyContextEnabled = "replyContextEnabled"
        static let clipboardContextEnabled = "clipboardContextEnabled"
        static let showWordCountInMenuBar = "showWordCountInMenuBar"
        static let batterySuggestOnlyOnDemand = "batterySuggestOnlyOnDemand"
        static let batteryShorterCompletions = "batteryShorterCompletions"
    }

    // MARK: Battery

    /// "Suggest only when I ask while on battery". **Defaults to false**: an absent key reads as off.
    var batterySuggestOnlyOnDemand: Bool {
        defaults.bool(forKey: Keys.batterySuggestOnlyOnDemand)
    }

    func setBatterySuggestOnlyOnDemand(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.batterySuggestOnlyOnDemand)
    }

    /// "Shorter suggestions on battery". **Defaults to false**: an absent key reads as off.
    var batteryShorterCompletions: Bool {
        defaults.bool(forKey: Keys.batteryShorterCompletions)
    }

    func setBatteryShorterCompletions(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.batteryShorterCompletions)
    }

    var policy: AppEnablementPolicy {
        AppEnablementPolicy(
            globallyEnabled: defaults.object(forKey: Keys.globallyEnabled) as? Bool ?? true,
            overrides: defaults.dictionary(forKey: Keys.overrides) as? [String: Bool] ?? [:],
            defaultMode: DefaultMode(storedValue: defaults.string(forKey: Keys.appDefaultMode)),
            siteRules: SiteRule.decode(defaults.object(forKey: Keys.siteRules))
        )
    }

    /// The Languages switches in General. The stored array lists what is switched off (`en`, `de`,
    /// `*` for all other languages); absent means nothing is off. Read on every context assembly, so a
    /// flip applies to the next predict.
    var languagePolicy: LanguagePolicy {
        LanguagePolicy(stored: defaults.object(forKey: Keys.disabledLanguages))
    }

    func setLanguageDisabled(_ selector: LanguageSelector, _ disabled: Bool) {
        var policy = languagePolicy
        if disabled { policy.disabled.insert(selector) } else { policy.disabled.remove(selector) }
        if policy.disabled.isEmpty {
            defaults.removeObject(forKey: Keys.disabledLanguages)
        } else {
            defaults.set(policy.storedValue, forKey: Keys.disabledLanguages)
        }
    }

    /// Today's accepted words next to the menu-bar icon. Absent means on.
    var showWordCountInMenuBar: Bool {
        defaults.object(forKey: Keys.showWordCountInMenuBar) as? Bool ?? true
    }

    func setShowWordCountInMenuBar(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.showWordCountInMenuBar)
    }

    /// The Websites section's rules, read from the same key `policy` reads.
    var siteRuleList: SiteRuleList {
        SiteRuleList(rules: SiteRule.decode(defaults.object(forKey: Keys.siteRules)))
    }

    func setSiteRuleList(_ list: SiteRuleList) {
        defaults.set(list.stored, forKey: Keys.siteRules)
    }

    /// Writes the Apps pane's default mode under `appDefaultMode`; `policy` reads it on every call.
    func setDefaultMode(_ mode: DefaultMode) {
        defaults.set(mode.rawValue, forKey: Keys.appDefaultMode)
    }

    func setGloballyEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.globallyEnabled)
    }

    /// `nil` clears the override (app reverts to default/blocklist behavior).
    func setOverride(_ enabled: Bool?, forBundleID id: String) {
        var dict = defaults.dictionary(forKey: Keys.overrides) as? [String: Bool] ?? [:]
        dict[id] = enabled
        defaults.set(dict, forKey: Keys.overrides)
    }

    // MARK: User switches

    /// "Suggest spelling fixes" (General). Absent means on; read per predict.
    var spellingFixesEnabled: Bool {
        defaults.object(forKey: Keys.spellingFixesEnabled) as? Bool ?? true
    }

    func setSpellingFixesEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.spellingFixesEnabled)
    }

    /// "Window text" (Privacy). Absent means on; read per predict, so a flip needs no relaunch.
    var windowContextEnabled: Bool {
        defaults.object(forKey: Keys.windowContextEnabled) as? Bool ?? true
    }

    func setWindowContextEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.windowContextEnabled)
    }

    /// "Reply context" (Privacy). Absent means on; read per predict.
    var replyContextEnabled: Bool {
        defaults.object(forKey: Keys.replyContextEnabled) as? Bool ?? true
    }

    func setReplyContextEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.replyContextEnabled)
    }

    /// "Use what I copied as context" (Privacy). **Defaults to false**: an absent key reads
    /// as off. `ClipboardContextSource` re-reads the same key on every predict, so a flip needs no relaunch.
    var clipboardContextEnabled: Bool {
        defaults.object(forKey: Keys.clipboardContextEnabled) as? Bool ?? false
    }

    func setClipboardContextEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.clipboardContextEnabled)
    }

    // MARK: Screen-context OCR

    /// The Privacy-panel OCR toggle. **Defaults to false** — an absent key must read as OFF, so a fresh
    /// install never captures the screen and never asks for Screen Recording.
    var screenOCREnabled: Bool {
        defaults.bool(forKey: Keys.screenOCREnabled)
    }

    func setScreenOCREnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.screenOCREnabled)
    }

    // MARK: Mid-text completion / FIM

    /// The mid-text (FIM) master gate — `SuggestionSession.fimEnabled`. **Defaults to false.**
    ///
    /// Deliberately **not** surfaced in Settings yet. It is meant to ship as a normal feature toggle, but
    /// only once the FIM model is behind it: the Core routing/stop/accept logic has landed while the
    /// second model is still gated on the offline probe, so flipping this today would let a mid-text
    /// caret predict *forward* — a bridge-shaped ghost that ignores the suffix. Until the model lands it
    /// is a developer flag, the same shape as `snapshotReuseEnabled`:
    ///
    ///     defaults write com.robinklotz.NextTyped midTextCompletionEnabled -bool YES
    var midTextCompletionEnabled: Bool {
        defaults.bool(forKey: Keys.midTextCompletionEnabled)
    }

    func setMidTextCompletionEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.midTextCompletionEnabled)
    }

    // MARK: Completion length (General pane)

    /// How long the ghost is — Short / Medium / Long over the display window. Stored as the
    /// **named step**, so re-tuning what a step means never invalidates a stored preference; an absent
    /// or unrecognised value reads as the shipping default (Medium, the pre-setting behaviour).
    var completionLength: CompletionLength {
        CompletionLength(stored: defaults.string(forKey: Keys.completionLength))
    }

    func setCompletionLength(_ length: CompletionLength) {
        defaults.set(length.rawValue, forKey: Keys.completionLength)
    }

    // MARK: Trailing punctuation (Shortcuts pane)

    /// Which accept keys insert trailing punctuation with the word. Stored as the named case; absent
    /// reads as `bothShortcuts`, the behaviour before the picker existed.
    ///
    ///     defaults write com.robinklotz.NextTyped trailingPunctuation -string neither
    var trailingPunctuation: TrailingPunctuation {
        TrailingPunctuation(stored: defaults.string(forKey: Keys.trailingPunctuation))
    }

    func setTrailingPunctuation(_ value: TrailingPunctuation) {
        defaults.set(value.rawValue, forKey: Keys.trailingPunctuation)
    }

    // MARK: Intercept keys and Esc behaviour (Shortcuts pane)

    /// The chords for accept word, accept all and dismiss, stored as JSON. Absent, unreadable or
    /// colliding data reads as the defaults (`Tab`, `⌥Tab`, `Esc`); `InterceptBindings.restored` decides.
    var interceptBindings: InterceptBindings {
        InterceptBindings.restored(from: defaults.data(forKey: Keys.interceptBindings))
    }

    func setInterceptBindings(_ value: InterceptBindings) {
        if value == .defaults {
            defaults.removeObject(forKey: Keys.interceptBindings)
        } else if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Keys.interceptBindings)
        } else {
            acLog("[settings]: interceptBindings encode failed, kept the stored value")
        }
    }

    /// What Esc does beyond hiding the ghost. Absent reads as `dismissOnly`, the Esc before the picker.
    ///
    ///     defaults write com.robinklotz.NextTyped escBehaviour -string dismissAndPauseField
    var escBehaviour: EscBehaviour {
        defaults.string(forKey: Keys.escBehaviour).flatMap(EscBehaviour.init(rawValue:)) ?? .dismissOnly
    }

    func setEscBehaviour(_ value: EscBehaviour) {
        defaults.set(value.rawValue, forKey: Keys.escBehaviour)
    }

    // MARK: Spelling variant (General pane)

    /// Off / British / Canadian English, stored as the named case. Default off: output is the
    /// model's own spelling, byte-identical to before the setting existed.
    var spellingVariant: SpellingVariant {
        SpellingVariant(stored: defaults.string(forKey: Keys.spellingVariant))
    }

    func setSpellingVariant(_ variant: SpellingVariant) {
        defaults.set(variant.rawValue, forKey: Keys.spellingVariant)
    }

    // MARK: Model unload (General pane)

    /// When the model leaves RAM. Absent, unknown, or `sec15` in a Release build reads as `.automatic`.
    ///
    ///     defaults write com.robinklotz.NextTyped modelUnloadAfterIdle -string min5
    var modelUnloadSetting: ModelUnloadSetting {
        ModelUnloadSetting(
            storedValue: defaults.string(forKey: Keys.modelUnloadAfterIdle),
            allowDebugValues: Self.allowsDebugUnloadValues)
    }

    func setModelUnloadSetting(_ setting: ModelUnloadSetting) {
        defaults.set(setting.rawValue, forKey: Keys.modelUnloadAfterIdle)
    }

    /// The model the user picked. Absent or unknown reads as `.automatic`, today's folder rule.
    /// `MLXPredictionEngine.currentPlan()` reads the same key from `UserDefaults.standard`.
    ///
    ///     defaults write com.robinklotz.NextTyped modelChoice -string 2b
    var modelChoice: ModelChoice {
        ModelChoice(stored: defaults.string(forKey: Keys.modelChoice))
    }

    func setModelChoice(_ choice: ModelChoice) {
        defaults.set(choice.rawValue, forKey: Keys.modelChoice)
    }

    /// The 15-second value exists for the VM harness and only in DEBUG builds.
    static var allowsDebugUnloadValues: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // MARK: Menu bar icon (General pane)

    /// Whether the user wants the menu bar icon. **Absent reads as shown**, so the shipping path is
    /// unchanged. `MenuBarIconPolicy` decides whether the icon is inserted; this is only the wish.
    var showMenuBarIcon: Bool {
        defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true
    }

    func setShowMenuBarIcon(_ show: Bool) {
        defaults.set(show, forKey: Keys.showMenuBarIcon)
    }

    // MARK: Personalization (Privacy pane)

    /// The style-profile toggle. **Defaults to false**, and that default is a *quality* gate, not a
    /// privacy one: personalization is cleared to ship default-ON, but the house
    /// eval rule stacks on top — the offline probe must show a lift (EN/DE separately, net of
    /// the front budget it displaces) before the default flips. Until then it ships off + experimental.
    var personalizationEnabled: Bool {
        defaults.bool(forKey: Keys.personalizationEnabled)
    }

    func setPersonalizationEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.personalizationEnabled)
    }

    /// The **learning-source denylist**: apps that still get completions but are never learned
    /// from. Deliberately its own list, not the Apps-pane off-switch: "don't learn from my password
    /// manager's notes field" and "don't complete in Terminal" are different questions.
    var learningDisabledBundleIDs: Set<String> {
        Set(defaults.stringArray(forKey: Keys.learningDisabled) ?? [])
    }

    func setLearningEnabled(_ enabled: Bool, forBundleID id: String) {
        var disabled = learningDisabledBundleIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(Array(disabled).sorted(), forKey: Keys.learningDisabled)
    }

    /// Live personalization settings for the controller, read fresh on every use.
    var personalizationSettings: PersonalizationSettings {
        PersonalizationSettings(
            // The harness forces capture off unless a scenario opted into a throwaway profile
            // : a run's typed sentences must never reach the user's profile.
            enabled: policy.globallyEnabled
                && (personalizationEnabled || HarnessEnvironment.personalization == .temp)
                && HarnessEnvironment.personalization != .off,
            // A harness run neutralises the denylist: it is a preference the harness does
            // not control, and one denylisted fixture host silently fails every capture scenario.
            learningDisabledBundleIDs: HarnessEnvironment.neutralisesLearningDenylist
                ? [] : learningDisabledBundleIDs)
    }

    /// Live OCR settings for `ScreenOCRContextProvider`. The per-app switch is read from the SAME
    /// overrides the completion policy uses, which is what makes an app turned off in the Apps pane mean
    /// **(a)+(b)** for OCR: no OCR while it is focused *and* excluded from every
    /// capture. Only explicit `false` overrides count — the shipped blocklist governs *completions*, and
    /// silently extending it to "never photograph" would exclude Terminal/Xcode from ambient context for
    /// reasons that have nothing to do with privacy.
    var screenOCRSettings: ScreenOCRSettings {
        let policy = self.policy
        let disabled = Set(policy.overrides.filter { !$0.value }.keys)
        return ScreenOCRSettings(
            enabled: policy.globallyEnabled && screenOCREnabled && !HarnessEnvironment.ocrForcedOff,
            disabledBundleIDs: disabled)
    }
}
