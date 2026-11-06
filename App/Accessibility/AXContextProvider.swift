import ApplicationServices
import AppKit
import NextTypedCore
import os

/// Reads near-caret text + the focused app via the Accessibility API
/// Returns `nil` when nothing usable is exposed
/// (secure field, or an app that gives no text) so the loop degrades gracefully.
///
/// Also the **AX-harvest** producer of `windowContext` (the "C1" lever): on a
/// window change it caches the focused window's broader *non-focused* visible text and serves it at
/// the prediction prefix's front. The harvest is DISJOINT from `textBeforeCaret` — feeding the focused
/// field's own text twice craters acceptance below baseline (the offline probe: EN overlap 0.05 vs
/// no-ctx 0.15 vs disjoint 0.82), so the focused element's subtree is skipped during the walk and an
/// overlap guard drops anything that would re-feed the near-caret tail.
///
/// CONCURRENCY: a `final class` (not an actor) so the latency-critical `currentContext()` read path is
/// never serialized behind a harvest. The blocking AX tree walk runs OFF this path on `harvestQueue`
/// with a per-call AX messaging timeout + a wall-clock budget; only the finished string crosses back,
/// under `state`'s lock. The cache is keyed by a window-identity `WindowStamp`: `currentContext()`
/// returns `windowContext` only when the cached stamp matches the *current* focused window (else `nil`,
/// degrade — never wrong-context — and kick a fresh harvest). This also covers the app-already-focused-
/// at-launch path that fires no focus-changed event, so no Core seam change is needed.
final class AXContextProvider: ContextProvider {
    /// Char/budget tunables.
    private enum Budget {
        /// Earlier-in-document head slice of the focused field (the part the engine's recent-window
        /// token cap drops on a long doc) — the single-field "earlier context" lever for TextEdit.
        static let focusedHead = 1200
        /// Only harvest a focused-head once the doc is at least this long…
        static let focusedLongDoc = 2500
        /// …and the caret is this far past the head, so head and near-caret tail stay disjoint.
        static let focusedHeadGap = 800
        static let harvestNodes = 400
        static let harvestDepth = 12
        static let harvestSeconds = 0.12
        static let perCallTimeout: Float = 0.1
        static let harvestStoreChars = 4000
        /// Length of the near-caret tail probed by the disjointness guard.
        static let overlapProbeChars = 120
    }

    /// User switch for the whole `windowContext` segment (Privacy -> "Window text").
    ///
    /// Read live from `AppSettingsStore` on every predict, so a flip applies to the next predict with no
    /// relaunch. Absent means on. The same key also serves the isolating arm of
    /// the context-enrichment measurement (`defaults write com.robinklotz.NextTyped windowContextEnabled -bool NO`).
    ///
    /// Suppression is total: `resolveWindowContext` returns before touching the cache, so no harvest
    /// is dispatched either.
    private let settingsStore = AppSettingsStore()

    /// Identity of "the same window" for cache staleness: pid + a hash of the window element.
    /// CFHash collisions only cost a redundant harvest or a slightly-stale serve, never correctness.
    private struct WindowStamp: Equatable, Sendable {
        let pid: pid_t
        let windowHash: Int
    }

    private struct HarvestState {
        var text: String?
        var stamp: WindowStamp?
        var harvesting: WindowStamp?
    }

    /// Carries a CF `AXUIElement` into the `@Sendable` harvest closure. The AX API is thread-agnostic,
    /// so using the element off the calling thread is safe.
    private struct SendableElement: @unchecked Sendable { let element: AXUIElement }

    private let harvestQueue = DispatchQueue(label: "com.robinklotz.NextTyped.windowHarvest", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: HarvestState())

    // MARK: site host

    /// The focused element's nearest `AXWebArea`, found once per focused element. `webArea == nil` with a
    /// matching key means "this element has none" (TextEdit), so a burst of keystrokes costs no ancestor
    /// walk. A new focused element replaces the entry. Only the host is ever derived from the page URL.
    private struct SiteState {
        var key: Int?
        var webArea: SendableElement?
        var loggedHost: String??
    }

    private let siteState = OSAllocatedUnfairLock(initialState: SiteState())

    private enum SiteBudget {
        static let ascentSteps = 40
        static let perCallTimeout: Float = 0.1
    }

    // MARK: reply-context state

    /// Budget for the reply-context descent. Larger than the windowContext walk (Electron transcript turns
    /// live at d≈29–33 vs. windowContext's depth-12) but strictly OFF-path (`harvestQueue`) with per-call
    /// AX timeouts + a wall-clock budget, so a slow/hung host can never stall.
    private enum ReplyBudget {
        static let descentNodes = 2500
        static let descentDepth = 40
        static let descentSeconds = 0.5
        static let perCallTimeout: Float = 0.1
        static let ascentSteps = 40
    }

    /// Longest a static-text part may be and still be treated as an echoed **speaker label** rather than
    /// body prose. Speaker labels are a few words ("Claude responded:"); anything longer is a paragraph.
    private static let maxSpeakerLabelChars = 40

    /// Turn-level freshness key: a new turn changes the transcript container's child count.
    private struct ReplyStamp: Equatable, Sendable {
        let pid: pid_t
        let containerChildCount: Int
    }

    private struct ReplyHarvestState {
        var text: String?
        var stamp: ReplyStamp?
        /// The cached transcript container, for the O(1) child-count freshness probe + re-harvest without
        /// re-descent. Nil until the first successful descent finds it (self-healing on a stale ref).
        var container: SendableElement?
        var harvesting = false
    }

    private let replyState = OSAllocatedUnfairLock(initialState: ReplyHarvestState())
    private let replyDescriptor = ReplySurfaceDescriptor.anthropicChat

    /// The `SurfaceEligibility` floor alone, for the pre-warm at focus time: the same four checks
    /// `currentContext()` makes, in the same order, without the window harvest, the reply harvest or any
    /// text slicing. Returns the rejection (`nil` = passed) and the frontmost app's bundle ID.
    ///
    /// Static, so the caller needs no provider instance, and safe off the main actor for another app's
    /// window (our own windows must be probed on the main actor, see `currentContext()`): every AX call has a
    /// short messaging timeout (`FloorProbe.perCallTimeout`), so a hung host cannot block for the system
    /// default of several seconds. The text check asks `AXNumberOfCharacters` first (a number, no copy of
    /// the document); only a host without that attribute falls back to reading `AXValue`.
    static func eligibilityFloor() -> (rejection: ContextRejection?, bundleID: String?) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, FloorProbe.perCallTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return (.noFocus, bundleID) }
        let element = focused as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(element, FloorProbe.perCallTimeout)
        if isSecure(element) { return (.secure, bundleID) }
        if WindowContextFilter.isChrome(role: string(element, kAXRoleAttribute)) { return (.chrome, bundleID) }
        if !hasText(element) { return (.noText, bundleID) }
        return (nil, bundleID)
    }

    private enum FloorProbe {
        static let perCallTimeout: Float = 0.1
    }

    /// `true` when the element exposes document text. Same answer as `string(element, kAXValueAttribute) != nil`,
    /// but a host that reports a character count answers without copying the text.
    private static func hasText(_ element: AXUIElement) -> Bool {
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           countRef is NSNumber { return true }
        return string(element, kAXValueAttribute) != nil
    }

    func currentContext() async -> ContextOutcome {
        // An AX call into our own process is answered in-process, on the calling thread. Our windows are
        // SwiftUI, whose accessibility getters run view code that must be on the main thread (a model
        // picker binding trapped there, 2026-11-04). So our own window is read on the main actor.
        if Self.ownProcessIsFrontmost() {
            return await MainActor.run { self.readContext() }
        }
        return readContext()
    }

    /// True while one of our own windows (Settings, onboarding, the Tab practice step) is frontmost.
    static func ownProcessIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func readContext() -> ContextOutcome {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            // An Electron host launched after the last app switch, or whose first write failed while it
            // launched, has no tree yet: retry the activation so the next keystroke can see the field.
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                ManualAccessibilityActivation.shared.activate(pid: pid, for: .focus)
            }
            return .rejected(.noFocus)
        }
        let element = focused as! AXUIElement

        // NEVER read secure/password fields.
        if isSecure(element) { return .rejected(.secure) }

        let role = string(element, kAXRoleAttribute)

        // Editability floor: never predict on a focused window-*chrome* control
        // (a button, checkbox, menu, slider, popup …). Its `value` is a UI label / current
        // selection, not document text — a prose continuation there is meaningless and `Tab`
        // would collide with the control. Reuse `WindowContextFilter.isChrome` — the same chrome
        // denylist the harvest applies to non-focused elements — so the focused element is judged
        // by the *one* source of truth, symmetrically. This sits at the trust boundary next to
        // `isSecure`: a chrome role yields no `TypingContext` at all, so nothing leaks into harvest,
        // caret geometry, or predict spend. Unknown/`nil` roles degrade to allow ("im Zweifel rein"),
        // which deliberately protects the fragile, never-fully-logged web/Electron editable roles.
        if WindowContextFilter.isChrome(role: role) {
            #if DEBUG
            acLog("[surface]: chrome-suppressed role=%@ app=%@",
                  role ?? "?",
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
            #endif
            return .rejected(.chrome)
        }

        let subrole = string(element, kAXSubroleAttribute)
        let value = string(element, kAXValueAttribute)
        #if DEBUG
        acLog("[ctx]: role=%@ subrole=%@ valueLen=%@ app=%@",
              role ?? "?", subrole ?? "-",
              value.map { String($0.count) } ?? "nil",
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
        #endif
        guard let value else { return .rejected(.noText) }

        // Caret = location of the selected-text range; its LENGTH is the selection (0 = a collapsed
        // caret, the ordinary case). An unreadable range reads as "caret at the end, nothing selected",
        // so missing AX data never suppresses (`SelectionGate`).
        let selectedRange = selectedRange(element)
        let caret = min(selectedRange?.location ?? value.count, value.count)
        // Deliberately NOT clamped against the remaining text length: AX ranges are UTF-16 offsets
        // while `value.count` counts Characters (the caret NOTE below), so a non-BMP glyph before the
        // selection makes `value.count - caret` too small — and a clamp would then silently report a
        // real selection as none, turning the gate off exactly where it is hardest to notice. The gate
        // asks only *is anything selected*, for which the raw length is already the whole answer.
        let selectionLength = max(0, selectedRange?.length ?? 0)
        // NOTE(hardening): AX ranges are UTF-16 offsets; this uses Character offsets,
        // which diverge for emoji/combining marks. Fine for English/German v1.
        let splitIndex = value.index(value.startIndex, offsetBy: caret)
        let textBeforeCaret = String(value[..<splitIndex])
        let textAfterCaret = String(value[splitIndex...])

        let windowContext = resolveWindowContext(
            focused: element, value: value, caret: caret, before: textBeforeCaret
        )

        // Reply-context: the interlocutor's most-recent turn on a known reply surface. A
        // SEPARATE harvest path with its own cache slot + turn-level freshness — disjoint from the
        // windowContext walk above. Gated by descriptor applicability (non-chat apps pay ~nothing).
        let replyContext = resolveReplyContext(focused: element, before: textBeforeCaret)

        // Field descriptor (role/subrole + size) for the Core FieldSizeGate — suppress in small
        // single-line inputs (search/address bars). Size is off the focused element's frame.
        let elementSize = size(element)
        let field = FieldDescriptor(
            role: role,
            subrole: subrole,
            width: elementSize.map { Double($0.width) },
            height: elementSize.map { Double($0.height) }
        )

        return .context(TypingContext(
            textBeforeCaret: textBeforeCaret,
            textAfterCaret: textAfterCaret,
            windowContext: windowContext,
            replyContext: replyContext,
            selectionLength: selectionLength,
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            field: field,
            siteHost: resolveSiteHost(focused: element)
        ))
    }

    // MARK: site host

    /// The normalized host of the page the focused element sits in, or `nil` outside a web area. The URL
    /// is read, reduced by `SiteHost.normalize` and dropped within this function: no property, log or
    /// prompt segment ever holds more than the host. Logs `[surface]: site=<host|none>` when the focused
    /// element or the host changes, not per keystroke.
    private func resolveSiteHost(focused: AXUIElement) -> String? {
        let key = Int(bitPattern: CFHash(focused))
        let cached: (hit: Bool, area: SendableElement?) = siteState.withLock { s in
            s.key == key ? (true, s.webArea) : (false, nil)
        }
        let area: SendableElement?
        if cached.hit {
            area = cached.area
        } else {
            let found = webArea(from: focused).map { SendableElement(element: $0) }
            siteState.withLock { s in
                s.key = key
                s.webArea = found
                s.loggedHost = nil  // a new focused element logs its host again, even when unchanged
            }
            area = found
        }
        var url: String?
        if let area {
            _ = AXUIElementSetMessagingTimeout(area.element, SiteBudget.perCallTimeout)
            url = Self.url(area.element)
            if url == nil {
                // A stale web area (page replaced) reads no URL: forget it, the next read walks again.
                // The next read re-resolves and logs the host once more.
                siteState.withLock { $0.key = nil; $0.webArea = nil }
            }
        }
        let host = url.flatMap(SiteHost.normalize)
        let changed = siteState.withLock { s -> Bool in
            if let last = s.loggedHost, last == host { return false }
            s.loggedHost = .some(host)
            return true
        }
        if changed { acLog("[surface]: site=%@", host ?? "none") }
        return host
    }

    /// Ascends to the nearest `AXWebArea`, bounded in steps and stopping at the window.
    private func webArea(from element: AXUIElement) -> AXUIElement? {
        var current = element
        var visited = Set<Int>()
        for _ in 0..<SiteBudget.ascentSteps {
            _ = AXUIElementSetMessagingTimeout(current, SiteBudget.perCallTimeout)
            if !visited.insert(Int(bitPattern: CFHash(current))).inserted { return nil }
            let role = string(current, kAXRoleAttribute)
            if role == "AXWebArea" { return current }
            if role == (kAXWindowRole as String) { return nil }
            guard let parent = copyElement(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// `AXURL` as a string; hosts return a `CFURL` or a string.
    private static func url(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    // MARK: windowContext (AX-harvest)

    /// Assemble the disjoint broader context: cached non-focused window text + (for a long focused doc)
    /// its earlier head, then drop anything that would re-feed the near-caret tail.
    private func resolveWindowContext(focused: AXUIElement, value: String, caret: Int, before: String) -> String? {
        // Experiment switch — before the cache read, so a suppressed
        // run dispatches no harvest at all. Absent ⇒ enabled, so shipping behaviour is unchanged.
        guard settingsStore.windowContextEnabled else {
            acLog("[ctx]: winCtx=off reason=user")
            return nil
        }
        // Our own window: the harvest walks it on `harvestQueue`, off the main thread, which our SwiftUI
        // views do not allow (see `currentContext()`), and its text is our own UI, not the user's writing.
        if Self.ownProcessIsFrontmost() {
            acLog("[ctx]: winCtx=off reason=own-window")
            return nil
        }

        // 1) Cached surrounding (non-focused) window text, keyed by window identity. Returns nil and
        //    kicks an off-path harvest when the cache is stale/empty for the current window.
        var surrounding: String?
        if let window = windowRoot(for: focused) {
            let st = stamp(for: window)
            let decision: (text: String?, dispatch: Bool) = state.withLock { s in
                if s.stamp == st { return (s.text, false) }
                if s.harvesting == st { return (nil, false) }   // a harvest for this window is already in flight
                s.harvesting = st
                return (nil, true)
            }
            surrounding = decision.text
            if decision.dispatch {
                let win = SendableElement(element: window)
                let foc = SendableElement(element: focused)
                // If `self` outlives to run this, `harvest` always clears `harvesting` for `st`. If it's
                // deallocated first, the `harvesting` flag dies with `state` (both live on `self`), so the
                // un-cleared flag is moot — there's no surviving instance left to read it.
                harvestQueue.async { [weak self] in
                    self?.harvest(window: win, focused: foc, stamp: st)
                }
            }
        }

        // 2) Earlier-in-document head of the FOCUSED field. Gated on doc length + caret position so the
        //    head stays disjoint from the near-caret text (full overlap craters acceptance — see B in
        //    the offline probe). Derived from the already-read `value`, so no extra AX cost.
        var head: String?
        if value.count > Budget.focusedLongDoc, caret >= Budget.focusedHead + Budget.focusedHeadGap {
            head = String(value.prefix(Budget.focusedHead))
        }

        // 3) Combine + disjointness guard: never re-feed the near-caret tail (the harmful double-count).
        let pieces = [surrounding, head]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        let combined = pieces.joined(separator: "\n\n")

        let tail = String(before.suffix(Budget.overlapProbeChars))
        if tail.count >= 12, combined.contains(tail) { return nil }

        return combined
    }

    /// Walk the focused window's subtree (off the prediction path), excluding the focused element, and
    /// store the harvested text under the given window stamp.
    private func harvest(window: SendableElement, focused: SendableElement, stamp: WindowStamp) {
        let result = collectWindowText(root: window.element, focused: focused.element)
        state.withLock { s in
            s.text = result
            s.stamp = stamp
            if s.harvesting == stamp { s.harvesting = nil }
        }
    }

    /// Iterative pre-order DFS over the window subtree, gathering text from non-focused, non-secure
    /// elements. Bounded by node count, depth, and wall-clock — and a per-call AX messaging timeout —
    /// so a slow/hung host can never stall. A visited set guards the graph-shaped AX tree against cycles.
    private func collectWindowText(root: AXUIElement, focused: AXUIElement) -> String? {
        let deadline = Date().addingTimeInterval(Budget.harvestSeconds)

        // Disjointness backstop: never collect the focused field's own value, even if CFEqual fails to
        // match the focused element across the systemwide-vs-tree refs (feeding it twice craters
        // acceptance below baseline — offline probes). Bound its read with a per-call timeout too.
        _ = AXUIElementSetMessagingTimeout(focused, Budget.perCallTimeout)
        let focusedValue = string(focused, kAXValueAttribute)

        // The window's own TITLE element. It is a plain `AXStaticText`, so the
        // role denylist keeps it — rightly, static text is what the harvest exists to collect — and on
        // a fresh document it was the ONLY thing harvested: the file name, at the reserved prompt front
        // . The window advertises the element, so the exclusion is an IDENTITY
        // comparison; matching on the title *string* would drop real prose from a document that repeats
        // its own heading. A host that doesn't advertise one (Safari) yields `nil` and is unchanged.
        let titleElement = copyElement(root, kAXTitleUIElementAttribute)

        var collected: [String] = []
        var totalChars = 0
        var visited = Set<Int>()
        var stack: [(el: AXUIElement, depth: Int)] = [(root, 0)]
        var nodes = 0
        #if DEBUG
        var trace: [String] = []   // role tags of the pieces actually collected, for harvest identification
        var titlePiecesSkipped = 0 // the window-title element, skipped by identity
        #endif

        while let (el, depth) = stack.popLast() {
            if nodes >= Budget.harvestNodes || Date() > deadline { break }
            nodes += 1

            // The messaging timeout is PER-OBJECT (AXUIElement.h: set on `root` it would NOT cover child
            // elements), so set it on every element before we message it — a slow/hung node then bails in
            // ~perCallTimeout, and the post-call deadline check bounds total harvest time.
            _ = AXUIElementSetMessagingTimeout(el, Budget.perCallTimeout)

            if CFEqual(el, focused) { continue }            // skip the focused element AND its subtree (disjointness)
            if !visited.insert(Int(bitPattern: CFHash(el))).inserted { continue }   // cycle / double-visit guard
            if isSecure(el) { continue }

            // Skip interactive controls / chrome AND their subtrees (pure-Core role classifier): their
            // `value` is a UI label or current selection (a font name, a size), not document content —
            // the source of the spurious constant winCtx on a near-empty doc.
            // None of these roles legitimately parents real text.
            let role = string(el, kAXRoleAttribute)
            let isTitle = titleElement.map { CFEqual(el, $0) } ?? false
            if WindowContextFilter.isExcludedFromHarvest(role: role, isWindowTitleElement: isTitle) {
                #if DEBUG
                if isTitle { titlePiecesSkipped += 1 }
                #endif
                continue
            }

            if let v = string(el, kAXValueAttribute), !v.isEmpty, v != focusedValue {
                if append(v, to: &collected, total: &totalChars) {
                    #if DEBUG
                    trace.append((role ?? "?") + ":v")
                    #endif
                }
            } else if role == (kAXStaticTextRole as String),
                      let title = string(el, kAXTitleAttribute), !title.isEmpty {
                if append(title, to: &collected, total: &totalChars) {
                    #if DEBUG
                    trace.append((role ?? "?") + ":t")
                    #endif
                }
            }
            if totalChars >= Budget.harvestStoreChars { break }

            if depth < Budget.harvestDepth, let children = children(el) {
                // Push reversed so the first child pops first → document reading order.
                for child in children.reversed() { stack.append((child, depth + 1)) }
            }
        }

        let joined = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        // Identifies what the harvest collected: the role
        // tags + a sample of the joined text. A near-empty doc should now log pieces=0 / chars=0.
        // `titleSkipped` makes the one thing this walk deliberately DROPS visible: the reason /06 went
        // unnoticed for months is that the harvest reported a plausible number with no way to see what
        // was in it. 0 on a host that advertises no title element, 1 where the title was excluded.
        acLog("[harvest]: nodes=%ld pieces=%ld chars=%ld titleSkipped=%ld roles=[%@] sample=\"%@\"",
              nodes, collected.count, joined.count, titlePiecesSkipped,
              trace.joined(separator: ","), String(joined.prefix(120)))
        #endif
        return joined.isEmpty ? nil : String(joined.prefix(Budget.harvestStoreChars))
    }

    /// Appends a harvested snippet, trimmed; skips single glyphs and immediate dups. Returns whether
    /// it was actually added (so the DEBUG harvest trace reflects only collected pieces).
    @discardableResult
    private func append(_ snippet: String, to collected: inout [String], total: inout Int) -> Bool {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }   // skip single glyphs / chrome noise
        if collected.last == trimmed { return false }    // dedup immediate repeats
        collected.append(trimmed)
        total += trimmed.count
        return true
    }

    // MARK: reply-context

    /// Serve the cached interlocutor turn for a known reply surface, dispatching an off-path re-harvest
    /// when the transcript container's child count has changed (a new turn streamed in). Everything
    /// expensive (the ascend-then-descend) runs on `harvestQueue`; on this latency-critical path we do at
    /// most ONE `kAXChildren` read (the O(1) freshness probe) plus the pure per-segment overlap guard.
    private func resolveReplyContext(focused: AXUIElement, before: String) -> String? {
        // Applicability gate — non-chat apps pay nothing.
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              replyDescriptor.bundleIDs.contains(bundleID) else { return nil }

        // User switch (Privacy -> "Reply context"): before any cache read or descent, so nothing is
        // harvested while it is off. Logged only on a reply surface, where the switch changes something.
        guard settingsStore.replyContextEnabled else {
            acLog("[reply]: off reason=user")
            return nil
        }

        var pid: pid_t = 0
        _ = AXUIElementGetPid(focused, &pid)

        // `container` stays wrapped in `SendableElement` across the lock boundary (a bare `AXUIElement`
        // is not `Sendable`).
        let cached = replyState.withLock {
            (text: $0.text, stamp: $0.stamp, container: $0.container)
        }

        if let container = cached.container, let stamp = cached.stamp, stamp.pid == pid {
            let live = childCount(container.element)   // O(1) freshness probe on the cached container
            if live == nil || live != stamp.containerChildCount {
                dispatchReplyHarvest(focused: focused, pid: pid)   // a new turn (or a lost ref) → re-harvest
            }
            return guardedReply(cached.text, before: before)   // serve cache (possibly one turn stale)
        }

        // No cached container → harvest off-path. Serve whatever we have (nil on the first pass).
        dispatchReplyHarvest(focused: focused, pid: pid)
        return guardedReply(cached.text, before: before)
    }

    /// Per-segment overlap guard: drop reply-context if it re-feeds the near-caret tail (the
    /// quoting case — "You said X, but…" where X was copied from the interlocutor). Fail-closed
    /// speaker separation is the primary disjointness guarantee; this is the secondary quoting backstop.
    private func guardedReply(_ text: String?, before: String) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let tail = String(before.suffix(Budget.overlapProbeChars))
        if tail.count >= 12, text.contains(tail) { return nil }
        return text
    }

    private func dispatchReplyHarvest(focused: AXUIElement, pid: pid_t) {
        let already = replyState.withLock { s -> Bool in
            if s.harvesting { return true }
            s.harvesting = true
            return false
        }
        guard !already else { return }
        let foc = SendableElement(element: focused)
        harvestQueue.async { [weak self] in
            self?.harvestReply(focused: foc, pid: pid)
        }
    }

    /// Off-path: ascend to the web-content root, descend the transcript into ordered turns, select the
    /// most-recent interlocutor turn (fail-closed, pure Core), and cache it under the transcript
    /// container's child-count stamp (the freshness signal).
    private func harvestReply(focused: SendableElement, pid: pid_t) {
        activateReplyAX(pid: pid)   // ensure the Electron a11y tree is up (idempotent)

        guard let root = webContentRoot(from: focused.element) else {
            replyState.withLock { $0.text = nil; $0.stamp = nil; $0.container = nil; $0.harvesting = false }
            #if DEBUG
            acLog("[reply]: no AXWebArea above the focused element (surface not a web transcript)")
            #endif
            return
        }

        let (turns, container) = descendTranscript(root: root)
        let text = replyDescriptor.selectReplyContext(from: turns)
        let count = container.map { childCount($0) ?? 0 } ?? 0
        let stamp = ReplyStamp(pid: pid, containerChildCount: count)
        let boxed = container.map { SendableElement(element: $0) }   // box across the @Sendable withLock boundary
        replyState.withLock {
            $0.text = text
            $0.stamp = stamp
            $0.container = boxed
            $0.harvesting = false
        }
        #if DEBUG
        acLog("[reply]: turns=%ld emitted=%@ chars=%ld childCount=%ld sample=\"%@\"",
              turns.count, text != nil ? "yes" : "no", text?.count ?? 0, count,
              String((text ?? "").prefix(120)))
        #endif
    }

    /// Ascend (kAXParent) to the nearest `AXWebArea`. Depth-capped + visited-guarded (Electron stacks ~20
    /// wrapper layers between the compose field and the web root).
    private func webContentRoot(from element: AXUIElement) -> AXUIElement? {
        var current = element
        var visited = Set<Int>()
        for _ in 0..<ReplyBudget.ascentSteps {
            _ = AXUIElementSetMessagingTimeout(current, ReplyBudget.perCallTimeout)
            if !visited.insert(Int(bitPattern: CFHash(current))).inserted { break }
            if string(current, kAXRoleAttribute) == "AXWebArea" { return current }
            guard let parent = copyElement(current, kAXParentAttribute) else { break }
            current = parent
        }
        return nil
    }

    /// One pre-order DFS under the web root that both **segments the transcript into turns** and derives
    /// the **freshness container**. Segmentation is heading-driven and locale-tolerant, and — being flat —
    /// is robust to however many wrapper layers sit between a turn's speaker `AXHeading` and its message
    /// text: a classifiable `AXHeading` opens a new turn, and every subsequent `AXStaticText` (in doc
    /// order, until the next such heading) is that turn's content. Chrome subtrees (sidebar/nav) are
    /// skipped whole. Bounded by node/depth/wall-clock.
    ///
    /// Freshness container = the **deepest common ancestor of the turn-opening headings** (the "Chat
    /// messages" group). It must be the shared ancestor, NOT a heading's immediate parent: each turn sits
    /// in its own per-turn article, so a heading's parent is a single article whose child-count is stable
    /// as *sibling* turns stream in — probing it would never invalidate the cache (the exact staleness E
    /// exists to fix). The DCA's child set, by contrast, gains a child per new turn. Computed from a
    /// parent-map built during the walk: tally every ancestor of every turn heading, pick max-count, break
    /// ties toward the deepest (the tightest group that still contains all turns).
    private func descendTranscript(root: AXUIElement) -> (turns: [ReplyTurn], container: AXUIElement?) {
        let deadline = Date().addingTimeInterval(ReplyBudget.descentSeconds)
        var turns: [ReplyTurn] = []
        var current: (label: String, parts: [String])?
        var parentOf: [Int: AXUIElement] = [:]
        var depthOf: [Int: Int] = [:]
        var headingEls: [AXUIElement] = []
        var visited = Set<Int>()
        var stack: [(el: AXUIElement, depth: Int, parent: AXUIElement?)] = [(root, 0, nil)]
        var nodes = 0

        func flush() {
            if let c = current {
                turns.append(ReplyTurn(speakerLabel: c.label, text: c.parts.joined(separator: " ")))
            }
            current = nil
        }

        while let (el, depth, parent) = stack.popLast() {
            if nodes >= ReplyBudget.descentNodes || Date() > deadline { break }
            nodes += 1
            _ = AXUIElementSetMessagingTimeout(el, ReplyBudget.perCallTimeout)
            let hash = Int(bitPattern: CFHash(el))
            if !visited.insert(hash).inserted { continue }
            if isSecure(el) { continue }   // never harvest a secure field (isSecure on every element)

            let role = string(el, kAXRoleAttribute)
            if WindowContextFilter.isChrome(role: role) { continue }   // skip sidebar/nav chrome + subtree

            if let parent { parentOf[hash] = parent }
            depthOf[hash] = depth

            if role == "AXHeading", let label = headingString(el), replyDescriptor.classify(label) != .unknown {
                flush()                                   // close the previous turn
                current = (label: label, parts: [])       // open this one
                headingEls.append(el)
            } else if role == (kAXStaticTextRole as String), current != nil {
                // Collect the turn's body text, but drop two AX-echo artefacts the Anthropic-chat
                // surfaces emit (claude.ai + Electron, runtime-verified 2026-07-10): the speaker label
                // rendered *again* as a static text ("Claude responded:" — a classifiable label, never
                // body prose) and a heading's first line echoed as a duplicate leading paragraph. Left in,
                // both leak the label and duplicate the first sentence into the injected reply-context.
                // The label test is LENGTH-BOUNDED on purpose: `classify` is a substring match tuned for
                // short speaker labels ("You said:"), so running it over a full paragraph would silently
                // drop any body prose that happens to contain such a phrase — e.g. an interlocutor
                // paragraph quoting "you said". A real label echo is a handful of words.
                if let s = string(el, kAXValueAttribute) ?? string(el, kAXTitleAttribute),
                   !s.isEmpty,
                   !(s.count <= Self.maxSpeakerLabelChars && replyDescriptor.classify(s) != .unknown),
                   current?.parts.last != s {                 // skip a consecutive duplicate (heading-line echo)
                    current?.parts.append(s)
                }
            }

            if depth < ReplyBudget.descentDepth, let children = children(el) {
                for child in children.reversed() { stack.append((child, depth + 1, el)) }
            }
        }
        flush()   // close the final open turn

        return (turns, deepestCommonAncestor(of: headingEls, parentOf: parentOf, depthOf: depthOf))
    }

    /// The deepest element that is an ancestor of the most turn headings (their DCA when they share one),
    /// walked from the DFS parent-map. `nil` when there are no headings. See `descendTranscript` for why
    /// this — not a heading's immediate parent — is the correct freshness container.
    private func deepestCommonAncestor(
        of headings: [AXUIElement], parentOf: [Int: AXUIElement], depthOf: [Int: Int]
    ) -> AXUIElement? {
        guard !headings.isEmpty else { return nil }
        var count: [Int: Int] = [:]
        var element: [Int: AXUIElement] = [:]
        for heading in headings {
            var cursor = Int(bitPattern: CFHash(heading))
            var seen = Set<Int>()
            while let parent = parentOf[cursor] {
                let key = Int(bitPattern: CFHash(parent))
                if !seen.insert(key).inserted { break }
                count[key, default: 0] += 1
                element[key] = parent
                cursor = key
            }
        }
        let best = count.max { lhs, rhs in
            (lhs.value, depthOf[lhs.key] ?? 0) < (rhs.value, depthOf[rhs.key] ?? 0)
        }
        return best.flatMap { element[$0.key] }
    }

    /// A heading element's text — its value, title, or description, whichever AX exposes first.
    private func headingString(_ element: AXUIElement) -> String? {
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(element, attr as String), !s.isEmpty { return s }
        }
        return nil
    }

    /// The number of direct children of `element` (the freshness probe), or `nil` if AX exposes none.
    private func childCount(_ element: AXUIElement) -> Int? {
        _ = AXUIElementSetMessagingTimeout(element, ReplyBudget.perCallTimeout)
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success
        else { return nil }
        return Int(count)
    }

    /// Turn on the Electron renderer a11y tree for reply-harvest, once per pid — through the
    /// SAME ``ManualAccessibilityActivation`` the caret path uses. This was a second copy of that policy
    /// and it had drifted: it latched the pid *before* the write and threw the result away, so a single
    /// transient failure (the app still launching) permanently suppressed the reply harvest for that app,
    /// and it never pruned a terminated pid. Both cost silence — `[reply]: turns=0 emitted=no` reads
    /// exactly like a surface with no transcript.
    private func activateReplyAX(pid: pid_t) {
        ManualAccessibilityActivation.shared.activate(pid: pid, for: .reply)
    }

    // MARK: AX helpers

    private func isSecure(_ element: AXUIElement) -> Bool { Self.isSecure(element) }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? { Self.string(element, attribute) }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        if string(element, kAXRoleAttribute) == (kAXSecureTextFieldSubrole as String) { return true }
        if let subrole = string(element, kAXSubroleAttribute), subrole.contains("Secure") { return true }
        return false
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// The focused element's size in points, or `nil` if AX exposes none. Feeds the FieldSizeGate's
    /// single-line geometry fallback (see `CaretLocator.elementFrame`, which reads the same attribute).
    private func size(_ element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// The host's selected-text range. BOTH halves are load-bearing: `location` is the caret, and
    /// `length` is the one fact that says whether anything is selected — which the `SelectionGate`
    /// needs, and which this reader used to discard one line before use.
    /// A non-empty selection reaches the loop from a mouse drag as well as from ⌘A, and only this
    /// range sees both.
    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The element's children, type-checked against `AXUIElementGetTypeID()` (AX can return
    /// heterogeneous arrays — a blind force-cast would crash).
    private func children(_ element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let array = ref as? [AnyObject]
        else { return nil }
        var out: [AXUIElement] = []
        out.reserveCapacity(array.count)
        for child in array where CFGetTypeID(child as CFTypeRef) == AXUIElementGetTypeID() {
            out.append(child as! AXUIElement)
        }
        return out.isEmpty ? nil : out
    }

    /// The window containing `element`: its `kAXWindow`, else a depth-capped, visited-guarded parent walk.
    private func windowRoot(for element: AXUIElement) -> AXUIElement? {
        if let window = copyElement(element, kAXWindowAttribute) { return window }
        var current = element
        var visited = Set<Int>()
        for _ in 0..<15 {
            if !visited.insert(Int(bitPattern: CFHash(current))).inserted { break }
            if string(current, kAXRoleAttribute) == (kAXWindowRole as String) { return current }
            guard let parent = copyElement(current, kAXParentAttribute) else { break }
            current = parent
        }
        return nil
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func stamp(for window: AXUIElement) -> WindowStamp {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(window, &pid)
        return WindowStamp(pid: pid, windowHash: Int(bitPattern: CFHash(window)))
    }
}
