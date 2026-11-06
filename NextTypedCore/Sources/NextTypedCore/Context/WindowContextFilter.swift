/// Classifies an element's AX **role** as window *chrome* (an interactive control) vs *content*,
/// for the AX-harvest producer of `windowContext` (stage 1 of context gathering).
///
/// **Why this exists.** The harvest walks the focused window's subtree gathering each non-focused
/// element's `value` (and `AXStaticText` titles). Interactive controls also expose a `value` — but it
/// is a UI label or the *current selection* (a font name, a point size, a button title), not document
/// text. On a near-empty focused field (a fresh TextEdit doc) the only thing in the window besides the
/// focused editor is that chrome — the format-bar font/size/style popups — so the harvest produced a
/// spurious constant (`winCtx=57`) where it should yield nothing
/// . Feeding such cross-element/chrome text into the prompt
/// also craters acceptance (the offline probe), so the harvest skips chrome elements *and* their
/// subtrees — none of these roles legitimately parents document content.
///
/// A **denylist**, not a content allowlist: an unknown/missing role degrades toward *keeping* the
/// element (the harvest's job is to surface surrounding content, so never silently drop text from a
/// role we simply haven't enumerated). `AXTextField` stays collectible — a non-focused single-line
/// field can hold real surrounding content (a Safari form's other fields, issue 01). `AXTabGroup` is
/// kept so the active tab's content pane (an `NSTabView` child) is still reached.
///
/// Pure Core: matched against plain AX role *strings* (Core can't import the `kAX…` constants), no
/// AppKit/AX here — so the classification is unit-tested off the un-testable AX tree walk.
public enum WindowContextFilter {
    /// AX roles whose text is an interactive control's label / current selection, not document
    /// content. The element AND its subtree are skipped during the harvest (none of these parent
    /// real text). Excludes container roles that can parent content (`AXTabGroup`) and single-line
    /// content fields (`AXTextField`).
    static let chromeRoles: Set<String> = [
        // Buttons & popups — the format-bar controls whose `value` is the current selection.
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXComboBox",
        // Menus & menu bars.
        "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem",
        // Toolbars & rulers — pure-chrome containers.
        "AXToolbar", "AXRuler",
        // Toggles & segmented controls.
        "AXCheckBox", "AXRadioButton", "AXRadioGroup", "AXSegmentedControl",
        // Sliders / steppers / numeric controls.
        "AXSlider", "AXIncrementor", "AXStepper", "AXValueIndicator",
        // Misc widgets that carry incidental values.
        "AXColorWell", "AXDisclosureTriangle", "AXScrollBar", "AXImage",
        "AXProgressIndicator", "AXBusyIndicator", "AXRelevanceIndicator",
        "AXGrowArea", "AXHelpTag",
    ]

    /// Whether an element with this AX role is window chrome — its text must not be harvested and its
    /// subtree must not be walked. `nil`/unknown roles are *not* chrome (degrade toward keeping
    /// content).
    public static func isChrome(role: String?) -> Bool {
        guard let role else { return false }
        return chromeRoles.contains(role)
    }

    /// Whether the harvest must skip this element **and its subtree** — the full exclusion rule:
    /// window chrome by *role*, or the focused window's own **title** element by *identity*.
    ///
    /// **Why the title needs its own arm.** A window title is a plain `AXStaticText`, which the role
    /// denylist deliberately keeps — static text is the harvest's primary content source.
    /// So on a fresh document with no prose in it the harvest was not empty at all: it collected the
    /// document's own title (on the harness fixture, 22 characters of temp file name) and injected it
    /// at the stable prompt front. Since prefix KV reuse needs a stable front,
    /// every front token competes for a reserved share of the prompt window, and a file name does not
    /// earn one. This is NOT the format bar's popup *controls* defect, which the role arm
    /// still handles.
    ///
    /// The title arm is by **identity**, never by content: matching "looks like a filename", or the
    /// string equalling the window's title, would drop real prose from a document whose text
    /// legitimately repeats its own heading. Resolving *which* element is the title is an AX identity
    /// comparison against the window's `AXTitleUIElement` and is necessarily App-side glue — the
    /// honest seam is a `Bool` the App passes in (keep the *decision* pure, don't contort
    /// the predicate into taking geometry or strings to claim more of it as Core).
    ///
    /// Identity wins over role on purpose: the title element's role *is* content-bearing, which is
    /// precisely why the role arm cannot see it.
    public static func isExcludedFromHarvest(role: String?, isWindowTitleElement: Bool) -> Bool {
        if isWindowTitleElement { return true }
        return isChrome(role: role)
    }
}
