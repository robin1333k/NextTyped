import Testing
@testable import NextTypedCore

@Suite struct WindowContextFilterTests {
    // MARK: Chrome / interactive controls — text is a UI label or current selection, never content

    @Test func skipsFormatBarPopups() {
        // The TextEdit format-bar font/size/style popups: their `value` is the current selection
        // ("Helvetica", "Regular", "12") — chrome, the root cause of the spurious winCtx=57.
        #expect(WindowContextFilter.isChrome(role: "AXPopUpButton") == true)
        #expect(WindowContextFilter.isChrome(role: "AXMenuButton") == true)
        #expect(WindowContextFilter.isChrome(role: "AXComboBox") == true)
    }

    @Test func skipsButtonsAndMenus() {
        #expect(WindowContextFilter.isChrome(role: "AXButton") == true)
        #expect(WindowContextFilter.isChrome(role: "AXMenu") == true)
        #expect(WindowContextFilter.isChrome(role: "AXMenuItem") == true)
        #expect(WindowContextFilter.isChrome(role: "AXMenuBar") == true)
        #expect(WindowContextFilter.isChrome(role: "AXMenuBarItem") == true)
    }

    @Test func skipsToolbarAndContainerChrome() {
        // Pure-chrome containers: their whole subtree is controls, never document text.
        #expect(WindowContextFilter.isChrome(role: "AXToolbar") == true)
        #expect(WindowContextFilter.isChrome(role: "AXRuler") == true)
    }

    @Test func skipsStepperAndSliderControls() {
        #expect(WindowContextFilter.isChrome(role: "AXIncrementor") == true)
        #expect(WindowContextFilter.isChrome(role: "AXStepper") == true)
        #expect(WindowContextFilter.isChrome(role: "AXSlider") == true)
        #expect(WindowContextFilter.isChrome(role: "AXCheckBox") == true)
        #expect(WindowContextFilter.isChrome(role: "AXRadioButton") == true)
        #expect(WindowContextFilter.isChrome(role: "AXColorWell") == true)
        #expect(WindowContextFilter.isChrome(role: "AXScrollBar") == true)
        #expect(WindowContextFilter.isChrome(role: "AXImage") == true)
        #expect(WindowContextFilter.isChrome(role: "AXSegmentedControl") == true)
    }

    // MARK: Content roles — genuine surrounding text the harvest exists to collect

    @Test func keepsTextAreaAndStaticText() {
        // The harvest's purpose (issue 01): a long doc's earlier text, a Safari form's surrounding
        // page prose. These carry real content and must stay collectible.
        #expect(WindowContextFilter.isChrome(role: "AXTextArea") == false)
        #expect(WindowContextFilter.isChrome(role: "AXStaticText") == false)
        #expect(WindowContextFilter.isChrome(role: "AXTextField") == false)
        #expect(WindowContextFilter.isChrome(role: "AXWebArea") == false)
    }

    @Test func keepsGenericContainers() {
        // Groups / scroll areas parent content and must be descended into, not skipped.
        #expect(WindowContextFilter.isChrome(role: "AXGroup") == false)
        #expect(WindowContextFilter.isChrome(role: "AXScrollArea") == false)
    }

    @Test func keepsTabGroupSoContentPanesAreReached() {
        // A tab group can parent the active tab's *content* (NSTabView), so it must not be skipped
        // wholesale — that would drop real surrounding text.
        #expect(WindowContextFilter.isChrome(role: "AXTabGroup") == false)
    }

    // MARK: Unknown / missing role — degrade toward keeping content (never silently drop on nil)

    @Test func keepsUnknownRole() {
        #expect(WindowContextFilter.isChrome(role: "AXSomeFutureRole") == false)
        #expect(WindowContextFilter.isChrome(role: nil) == false)
    }

    // MARK: Editability floor — the SECOND consumer
    //
    // `isChrome` is now reused on the *focused* element at `AXContextProvider.currentContext`: a
    // chrome role produces no `TypingContext`, so the app never predicts on a button/checkbox/menu.
    // These pins guard that floor's contract independently of the harvest's. A harvest-motivated
    // edit to `chromeRoles` that, say, dropped `AXButton` (to keep a button's label as surrounding
    // text) would silently re-open the focused-control predict hole — these tests catch it.

    @Test func floorSuppressesFocusedNonEditableControls() {
        // The observed leaks: QuickTime's `AXCheckBox` fired 71×; a focused
        // `AXButton`/`AXMenu`/`AXPopUpButton` must never reach the prediction path.
        #expect(WindowContextFilter.isChrome(role: "AXButton") == true)
        #expect(WindowContextFilter.isChrome(role: "AXCheckBox") == true)
        #expect(WindowContextFilter.isChrome(role: "AXMenu") == true)
        #expect(WindowContextFilter.isChrome(role: "AXMenuItem") == true)
        #expect(WindowContextFilter.isChrome(role: "AXPopUpButton") == true)
        #expect(WindowContextFilter.isChrome(role: "AXSlider") == true)
        // `AXComboBox` is deliberately chrome here too (matches `FieldSizeGate`'s suppress arm).
        #expect(WindowContextFilter.isChrome(role: "AXComboBox") == true)
    }

    @Test func floorKeepsFocusedEditableSurfaces() {
        // The surfaces the app MUST keep working on, none of which may become chrome:
        //   `AXTextArea`  — TextEdit / Apple Notes / Claude Desktop (confirmed) editors.
        //   `AXTextField` — corrections still flow (it is deliberately excluded from chrome).
        //   `AXWebArea` / unknown — claude.ai's compose role was never logged; degrade-to-allow
        //   makes that unknown irrelevant (the denylist's whole point vs. a strict allowlist).
        #expect(WindowContextFilter.isChrome(role: "AXTextArea") == false)
        #expect(WindowContextFilter.isChrome(role: "AXTextField") == false)
        #expect(WindowContextFilter.isChrome(role: "AXWebArea") == false)
        #expect(WindowContextFilter.isChrome(role: "AXGroup") == false)
        #expect(WindowContextFilter.isChrome(role: nil) == false)
    }

    // MARK: The window's own title
    //
    // A title is plain `AXStaticText` — content by the role denylist's rule, and rightly so (static
    // text is what the harvest exists to collect). The exclusion is therefore a SECOND arm, keyed on
    // the element's identity, and these pins state both directions of that split.

    @Test func theWindowsOwnTitleIsNotDocumentContext() {
        // The observed defect: on a fresh document the only harvested piece was the title static
        // text (`fixture-<stamp>.txt`), 22 chars of file name at the reserved prompt front.
        #expect(WindowContextFilter.isExcludedFromHarvest(role: "AXStaticText", isWindowTitleElement: true) == true)
    }

    @Test func identityWinsOverRoleForTheTitle() {
        // Whatever role the host gives its title element, identity decides — the role arm cannot see
        // it (that is the whole reason this ticket exists).
        #expect(WindowContextFilter.isExcludedFromHarvest(role: "AXTextField", isWindowTitleElement: true) == true)
        #expect(WindowContextFilter.isExcludedFromHarvest(role: nil, isWindowTitleElement: true) == true)
    }

    @Test func otherStaticTextIsStillHarvested() {
        // The regression that matters: `AXStaticText` is the harvest's primary content source
        // . A long document's surrounding prose must be untouched by the title arm.
        #expect(WindowContextFilter.isExcludedFromHarvest(role: "AXStaticText", isWindowTitleElement: false) == false)
        #expect(WindowContextFilter.isExcludedFromHarvest(role: "AXTextArea", isWindowTitleElement: false) == false)
        #expect(WindowContextFilter.isExcludedFromHarvest(role: nil, isWindowTitleElement: false) == false)
    }

    @Test func theRoleArmStillDeniesChrome() {
        // The `/02` defect is unchanged by the new arm: the format-bar popups stay out.
        #expect(WindowContextFilter.isExcludedFromHarvest(role: "AXPopUpButton", isWindowTitleElement: false) == true)
        #expect(WindowContextFilter.isExcludedFromHarvest(role: "AXComboBox", isWindowTitleElement: false) == true)
    }
}
