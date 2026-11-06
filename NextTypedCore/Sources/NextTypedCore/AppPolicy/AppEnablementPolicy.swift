/// Whether an app without an explicit override is on (`everywhere`, the shipping value) or off
/// (`onlySwitchedOn`).
public enum DefaultMode: String, Sendable, Equatable {
    case everywhere
    case onlySwitchedOn

    /// An absent or unknown stored string reads as `everywhere`, so the shipping path is unchanged.
    public init(storedValue: String?) {
        self = storedValue.flatMap(DefaultMode.init(rawValue:)) ?? .everywhere
    }

    /// The Apps pane picker's choice text.
    public var pickerLabel: String {
        switch self {
        case .everywhere:     "Every app"
        case .onlySwitchedOn: "Only apps I turn on"
        }
    }

    /// The footer under the Apps pane picker; it names what an app without a choice does in this mode.
    public var pickerFooter: String {
        switch self {
        case .everywhere:
            "Apps without a choice below complete, except the ones that start off."
        case .onlySwitchedOn:
            "Apps without a choice below stay off, including the ones that normally start on."
        }
    }
}

/// The surface a policy decision is about. `host` is the normalized website host (`SiteHost`), `nil` outside a browser page.
public struct SurfaceIdentity: Sendable, Equatable {
    public let bundleID: String
    public let host: String?
    public init(bundleID: String, host: String? = nil) {
        self.bundleID = bundleID
        self.host = host
    }
}

/// Why a surface is off.
public enum DisabledReason: String, Sendable, Equatable {
    case pause
    case override
    case blocklist
    case defaultOff = "default-off"
    case siteRule = "site-rule"
}

public enum EnablementVerdict: Sendable, Equatable {
    case enabled
    case disabled(DisabledReason)
}

extension EnablementVerdict {
    /// The typed context rejection this verdict stands for: `nil` when enabled, `globalOff`
    /// for the master switch (`pause`), `appOff` for every other reason.
    public var rejection: ContextRejection? {
        switch self {
        case .enabled: return nil
        case .disabled(.pause): return .globalOff
        case .disabled: return .appOff
        }
    }
}

/// Decides whether NextTyped is active in a given app, combining:
///   1. the global master switch (the pause hotkey),
///   2. a shipped blocklist of hostile apps (pre-disabled), and
///   3. per-app user overrides (which beat the blocklist).
///
/// On-by-default with a smart blocklist.
public struct AppEnablementPolicy: Sendable {
    /// Apps where NextTyped ships PRE-DISABLED. The user can still force any on.
    public static let defaultBlocklist: Set<String> = [
        // Terminals — Tab is shell completion.
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        // Password managers — sensitive, and full of secure fields. Their search, notes and custom
        // fields are not `AXSecureTextField`, so the field-level guard does not cover them.
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "org.keepassxc.keepassxc",
        "com.markmcguill.strongbox.mac",
        "com.hicknhacksoftware.MacPass",
        "me.proton.pass.electron",
        "com.lastpass.lastpassmacdesktop",
        "com.lastpass.LastPass",
        "com.keepersecurity.passwordmanager",
        "com.callpod.keepermac.lite",
        "com.nordsec.nordpass",
        "in.sinew.Enpass-Desktop",
        "com.SiberSystems.RoboForm",
        "com.outercorner.Secrets",
        // Known poor-context Electron apps — AX exposes little usable text.
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "notion.id",
        "com.hnc.Discord",
        // Native code editors / IDEs — the editor is an `AXTextArea`, so the field-size gate
        // *allows* it, but the content is source code: a prose continuation is wrong there and
        // Tab collides with the editor's own completion/indent. A bundle-ID list
        // is a stopgap; the real fix is editor/content detection,
        // which is not built yet.
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.barebones.bbedit",
        "com.panic.Nova",
        "com.google.android.studio",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.goland",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.rider",
        "com.jetbrains.rubymine",
        "com.jetbrains.datagrip",
    ]

    /// Global master switch (false = paused everywhere).
    public var globallyEnabled: Bool
    /// Per-app explicit overrides: `true` = force-on, `false` = force-off.
    public var overrides: [String: Bool]
    public var defaultMode: DefaultMode
    /// Per-website choices. Consulted only when the surface has a host.
    public var siteRules: [SiteRule]
    private let blocklist: Set<String>

    public init(
        globallyEnabled: Bool = true,
        overrides: [String: Bool] = [:],
        defaultMode: DefaultMode = .everywhere,
        siteRules: [SiteRule] = [],
        blocklist: Set<String> = AppEnablementPolicy.defaultBlocklist
    ) {
        self.defaultMode = defaultMode
        self.siteRules = siteRules
        self.globallyEnabled = globallyEnabled
        self.overrides = overrides
        self.blocklist = blocklist
    }

    /// Precedence: pause, then the most specific matching site rule (only with a host), then an explicit override, then the default mode (the blocklist applies
    /// only in `everywhere`).
    public func verdict(for surface: SurfaceIdentity) -> EnablementVerdict {
        guard globallyEnabled else { return .disabled(.pause) }
        if let host = surface.host, let rule = SiteRule.mostSpecific(in: siteRules, for: host) {
            return rule.enabled ? .enabled : .disabled(.siteRule)
        }
        if let override = overrides[surface.bundleID] {
            return override ? .enabled : .disabled(.override)
        }
        switch defaultMode {
        case .everywhere:
            return blocklist.contains(surface.bundleID) ? .disabled(.blocklist) : .enabled
        case .onlySwitchedOn:
            return .disabled(.defaultOff)
        }
    }

    public func isEnabled(forBundleID bundleID: String) -> Bool {
        verdict(for: SurfaceIdentity(bundleID: bundleID)) == .enabled
    }
}
