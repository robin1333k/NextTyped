import Testing
@testable import NextTypedCore

@Suite struct FieldSizeGateTests {
    // MARK: Suppressed — small single-line inputs (by role/subrole)

    @Test func suppressesSearchFieldBySubrole() {
        // A search box — subrole wins regardless of role/size.
        #expect(FieldSizeGate.allowsContinuation(role: "AXTextField", subrole: "AXSearchField", height: 28) == false)
    }

    @Test func suppressesSearchFieldEvenWithTextAreaRole() {
        // Subrole is the strongest signal: a search field reported with an odd role still suppresses.
        #expect(FieldSizeGate.allowsContinuation(role: "AXTextArea", subrole: "AXSearchField", height: 200) == false)
    }

    @Test func suppressesSingleLineTextField() {
        // An address/URL bar or login field — single-line by AX convention.
        #expect(FieldSizeGate.allowsContinuation(role: "AXTextField", subrole: nil, height: 30) == false)
    }

    @Test func suppressesComboBox() {
        // Google's search box / the Safari omnibox report as AXComboBox — a single-line search control,
        // even when AX exposes no usable height (size unavailable → must still suppress; this was the
        // observed gap where a ghost still appeared in the Google box).
        #expect(FieldSizeGate.allowsContinuation(role: "AXComboBox", subrole: nil, height: nil) == false)
        #expect(FieldSizeGate.allowsContinuation(role: "AXComboBox", subrole: nil, height: 22) == false)
    }

    // MARK: Allowed — large multi-line editors (by role)

    @Test func allowsMultiLineTextArea() {
        // The TextEdit document — multi-line, ghost as before.
        #expect(FieldSizeGate.allowsContinuation(role: "AXTextArea", subrole: nil, height: 600) == true)
    }

    @Test func textAreaAllowedEvenWhenShort() {
        // An explicit multi-line role is never overridden by a small height (role wins over geometry).
        #expect(FieldSizeGate.allowsContinuation(role: "AXTextArea", subrole: nil, height: 20) == true)
    }

    // MARK: Geometry fallback — ambiguous/unknown role

    @Test func suppressesShortFieldWhenRoleUnknown() {
        // No role, but a single-line-height box → treat as small.
        #expect(FieldSizeGate.allowsContinuation(role: nil, subrole: nil, height: 24) == false)
    }

    @Test func allowsTallFieldWhenRoleUnknown() {
        // No role, but clearly a multi-line area → allow.
        #expect(FieldSizeGate.allowsContinuation(role: nil, subrole: nil, height: 300) == true)
    }

    @Test func allowsWhenRoleAndSizeBothUnknown() {
        // Nothing to classify on → don't suppress (false negative is cheaper than killing an editor).
        #expect(FieldSizeGate.allowsContinuation(role: nil, subrole: nil, height: nil) == true)
    }

    @Test func allowsUnknownRoleWithCustomRoleString() {
        // A custom/web role string we don't recognise, with no size → allow.
        #expect(FieldSizeGate.allowsContinuation(role: "AXWebArea", subrole: nil, height: nil) == true)
    }

    // MARK: Height threshold boundary

    @Test func heightAtThresholdIsSuppressed() {
        // `<=` boundary: exactly the threshold counts as single-line.
        #expect(FieldSizeGate.allowsContinuation(role: nil, subrole: nil,
                                                 height: FieldSizeGate.singleLineMaxHeight) == false)
    }

    @Test func heightJustAboveThresholdIsAllowed() {
        #expect(FieldSizeGate.allowsContinuation(role: nil, subrole: nil,
                                                 height: FieldSizeGate.singleLineMaxHeight + 1) == true)
    }

    // MARK: TypingContext convenience

    @Test func noDescriptorIsAllowed() {
        // AX exposed no field descriptor → never suppress on missing data.
        let ctx = TypingContext(textBeforeCaret: "Ich war im Laden")
        #expect(FieldSizeGate.allowsContinuation(in: ctx) == true)
    }

    @Test func contextWithSearchFieldIsSuppressed() {
        let ctx = TypingContext(
            textBeforeCaret: "berl",
            field: FieldDescriptor(role: "AXTextField", subrole: "AXSearchField", width: 240, height: 28)
        )
        #expect(FieldSizeGate.allowsContinuation(in: ctx) == false)
    }

    @Test func contextWithTextAreaIsAllowed() {
        let ctx = TypingContext(
            textBeforeCaret: "Ich war im Laden und",
            field: FieldDescriptor(role: "AXTextArea", subrole: nil, width: 500, height: 600)
        )
        #expect(FieldSizeGate.allowsContinuation(in: ctx) == true)
    }
}
