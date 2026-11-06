import AppKit
import ApplicationServices
import NextTypedCore
import CoreGraphics
import ScreenCaptureKit
import Vision
import os

/// **Screen-context OCR** (the pixel branch of context gathering): capture the screen, read it
/// with Vision, attribute each block to its window, and serve the ranked result as prompt context.
///
/// A **separate provider** from `AXContextProvider` on purpose: grouped by
/// *mechanism and trust boundary*, not by output field. OCR shares nothing with the AX harvest — a
/// different permission (Screen Recording vs Accessibility), different frameworks (ScreenCaptureKit +
/// Vision vs AX), its own cadence, and its own scrub-chain (`isSecure` guards AX reads, not pixels).
/// Reply-context lives inside `AXContextProvider` precisely because it *is* an AX harvest; a Vision
/// pipeline in there would be false cohesion.
///
/// **Strictly off the predict path.** A full-screen `.accurate` pass costs 0.3–1.0 s, so `cachedContext`
/// is a synchronous read of whatever the last pass produced — it never awaits recognition. Passes are
/// kicked from the same call, gated by the pure-Core `OCRCadencePolicy` and a perceptual pre-diff, on a
/// `.utility` queue with a single-in-flight guard.
///
/// Not Core-unit-testable (ScreenCaptureKit/Vision/AX need a running app with granted permissions);
/// every decision it makes is delegated to the pure-Core `ScreenContext` types, which are.
final class ScreenOCRContextProvider: @unchecked Sendable {

    /// Recognition + budget tunables. Measured-later placeholders.
    private enum Budget {
        /// Vision drops candidates below this confidence — misreads are worse than missing text.
        static let minimumConfidence: Double = 0.4
        /// Fraction of the image height a line must occupy: sheds tiny UI text without touching prose.
        static let minimumTextHeightFraction: Float = 0.008
        /// Head-cap per ambient window before the prompt-front cap applies.
        static let ambientPerWindowChars = 600
        /// Head-cap for the focused-window fill.
        static let focusedFillChars = 1500
        /// How many ambient windows may reach the prompt.
        static let ambientWindowLimit = 2
        /// Apps remembered in the recency ordering (v1 app-level).
        static let recencyDepth = 8
        /// Per-call AX messaging timeout, matching `AXContextProvider`'s. Bounds the secure-field guard,
        /// which is the one AX read this provider does on the awaited predict path.
        static let axCallTimeout: Float = 0.1
    }

    /// Everything the last completed pass produced, plus the bookkeeping the cadence needs.
    private struct PassState {
        var context: OCRContext?
        /// Uptime seconds of the last completed pass, for throttle/TTL.
        var lastPassAt: TimeInterval?
        /// dHash of the last capture, for the pre-diff.
        var lastHash: UInt64?
        /// The window the cache describes — serving another window's text would be plain wrong.
        var surfaceKey: String?
        var inFlight = false
        /// Uptime of the last prediction-relevant keystroke (the model-residency activity signal) — the
        /// proactive gate. Kept in this lock rather than read from the (main-actor) coordinator,
        /// because the read happens on whatever executor the async context walk lands on.
        var lastActivityAt: TimeInterval?
    }

    private let ocrQueue = DispatchQueue(label: "com.robinklotz.NextTyped.screenOCR", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: PassState())
    /// App-level recency: bundle IDs most-recently-frontmost first, fed by `noteFrontmostApp`.
    private let recentApps = OSAllocatedUnfairLock(initialState: [String]())
    /// Power gating, driven by the same system signals `ModelResidencyController` listens to.
    private let powerState = OSAllocatedUnfairLock(initialState: OCRCadencePolicy.PowerState.normal)

    /// Reads the live settings (Privacy toggle + per-app switches). Injected so the provider doesn't
    /// reach into `UserDefaults` itself and can be driven in isolation.
    private let settings: @Sendable () -> ScreenOCRSettings

    init(settings: @escaping @Sendable () -> ScreenOCRSettings) {
        self.settings = settings
    }

    // MARK: - The predict-path read (synchronous, never awaits a pass)

    /// The cached OCR context for the current surface, and a kick for a refresh when the cadence
    /// allows. Returns `nil` when OCR is off, the cache is empty, expired, or belongs to another
    /// surface — degrade to today's behaviour rather than serve wrong-window context.
    ///
    /// **LOAD-BEARING PRIVACY INVARIANT — this is the ONLY thing that starts an OCR pass.**
    /// A refresh is kicked from here and nowhere else, and this is called from exactly one place:
    /// `CompositeContextProvider.currentContext`, *after* `AXContextProvider.currentContext` has
    /// returned a non-`nil` `TypingContext`. A focused secure field is rejected there
    /// (`AXContextProvider.isSecure`), so it yields no context, so no predict happens, so this is
    /// never called and **no capture is taken** — measured 2026-08-28 as zero `[ocr]` lines across a
    /// 3 min 41 s password-field focus, several times the TTL.
    ///
    /// That dormancy, not `focusedFieldIsSecure()`, is what actually keeps OCR off on secure fields.
    /// **Adding a timer-, notification- or observer-driven refresh would silently delete the
    /// protection** — the cadence's TTL backstop is a *backstop within* a predict, not a clock of its
    /// own — and no test would fail. If ambient refresh without typing is ever wanted, guard (ii) has
    /// to become the real guarantee first, which means proving `focusedFieldIsSecure()` fires (it has
    /// never been observed to: see the `focusedSecure=` field on the `[ocr]` line below).
    ///
    /// - Parameters:
    ///   - focusedBundleID: the frontmost app, for the per-app switch and the surface key.
    ///   - axWindowContext: the AX harvest for the focused window — the other half of the OCR↔AX
    ///     value-check, which is why it has to be passed in rather than re-derived.
    func cachedContext(focusedBundleID: String?, axWindowContext: String?) -> OCRContext? {
        let settings = self.settings()
        guard settings.enabled, Permissions.hasScreenRecording else { return nil }

        let surfaceKey = focusedBundleID ?? "?"
        let appAllowed = !(focusedBundleID.map { settings.disabledBundleIDs.contains($0) } ?? false)
        let now = ProcessInfo.processInfo.systemUptime

        let (cached, lastPassAt, isNewSurface, alreadyRunning, lastActivityAt) = state.withLock { s in
            (s.context, s.lastPassAt, s.surfaceKey != surfaceKey, s.inFlight, s.lastActivityAt)
        }

        // Re-read Low Power / thermal state here rather than on a timer: it is two cheap property reads,
        // and doing it at the decision point means the throttle reacts on the very next pass instead of
        // up to a tick late. A hard `.off` (lock/sleep) is latched by its signal and not overwritten.
        refreshPowerStateFromSystem()

        // Read once: an AX round-trip on the awaited predict path, and the log line below must report
        // the very verdict the policy saw — a second read could disagree with it.
        let focusedSecure = focusedFieldIsSecure()

        // Decide whether to kick a refresh. The decision is pure Core; the clock and the secure-field
        // read are ours.
        let decision = OCRCadencePolicy.decide(OCRCadencePolicy.Input(
            enabled: true,
            appAllowed: appAllowed,
            focusedFieldIsSecure: focusedSecure,
            power: powerState.withLock { $0 },
            lastActivityAt: lastActivityAt,
            lastPassAt: lastPassAt,
            isNewSurface: isNewSurface,
            now: now))

        if decision.shouldRun, !alreadyRunning {
            let claimed = state.withLock { s -> Bool in
                guard !s.inFlight else { return false }
                s.inFlight = true
                return true
            }
            if claimed {
                let excluded = settings.excludedBundleIDs
                ocrQueue.async { [weak self] in
                    guard let self else { return }
                    Task.detached(priority: .utility) {
                        await self.runPass(
                            surfaceKey: surfaceKey,
                            excludedBundleIDs: excluded,
                            axWindowContext: axWindowContext)
                    }
                }
            }
        }
        #if DEBUG
        // `focusedSecure=` is not decoration: `skip(secure-field)` has never been observed and, given
        // the invariant above, cannot be on a correct build — so without the verdict printed on every
        // decision line, "the guard is fine" and "the guard is never consulted" look identical in a
        // log. A `focusedSecure=1` here would mean the dormancy has been broken somewhere upstream.
        acLog("[ocr]: %@ surface=%@ focusedSecure=%d cached=%@",
              decision.rawValue, surfaceKey, focusedSecure ? 1 : 0,
              cached.map { "\(($0.ambient?.count ?? 0))a/\(($0.focusedFill?.count ?? 0))f" } ?? "none")
        #endif

        // Serve only same-surface, non-expired text. `appAllowed` also gates the *serve*, so switching
        // an app off takes effect immediately rather than after the cache ages out.
        guard appAllowed, !isNewSurface,
              !OCRCadencePolicy.isExpired(lastPassAt: lastPassAt, now: now),
              let cached, !cached.isEmpty
        else { return nil }
        return cached
    }

    // MARK: - Signals from the App (mirrors the ModelResidency sources)

    /// A predict just ran into an editable, gates-passed field — the same "prediction-relevant
    /// activity" signal `ModelResidencyController` consumes, reused here as the proactive
    /// gate: no writing, no OCR.
    func notePredictionActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.lastActivityAt = now }
    }

    /// Frontmost app changed — feeds the v1 app-level recency ordering used by the ambient ranking.
    func noteFrontmostApp(_ bundleID: String?) {
        guard let bundleID else { return }
        recentApps.withLock { apps in
            apps.removeAll { $0 == bundleID }
            apps.insert(bundleID, at: 0)
            if apps.count > Budget.recencyDepth { apps.removeLast(apps.count - Budget.recencyDepth) }
        }
    }

    /// Screen locked / display or system asleep ⇒ hard off (privacy *and* nothing useful to read);
    /// Low Power / thermal pressure ⇒ lengthen the throttle. Cached text is dropped on a hard off, so
    /// nothing captured before the lock survives it.
    func setPowerState(_ newState: OCRCadencePolicy.PowerState) {
        powerState.withLock { $0 = newState }
        if newState == .off {
            state.withLock { s in
                s.context = nil
                s.lastHash = nil
                s.surfaceKey = nil
            }
        }
    }

    /// Re-read the machine's energy posture from the system (Low Power Mode / thermal state). Called
    /// on the residency tick; `off` is set explicitly by the lock/sleep signals and is not overwritten
    /// here.
    func refreshPowerStateFromSystem() {
        guard powerState.withLock({ $0 }) != .off else { return }
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
        powerState.withLock { $0 = constrained ? .constrained : .normal }
    }

    /// Screen unlocked / woke ⇒ OCR may run again (the next pass repopulates the cache).
    ///
    /// Waking is **not** the same as unlocking: a machine that wakes to the lock screen would otherwise
    /// re-arm capture during the wake→unlock window, contradicting the Privacy panel's promise that
    /// capture stops while the screen is locked. So the latch only lifts once the session says it is
    /// genuinely unlocked.
    func resumeAfterPowerOff() {
        guard !Self.screenIsLocked() else { return }
        powerState.withLock { $0 = .normal }
        refreshPowerStateFromSystem()
    }

    /// Live lock state from the session dictionary. An unreadable dictionary degrades to "locked"
    /// (stay off) — the safe direction for a privacy latch.
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (session["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    // MARK: - The pass (off-path)

    private func runPass(surfaceKey: String, excludedBundleIDs: Set<String>, axWindowContext: String?) async {
        defer { state.withLock { $0.inFlight = false } }

        // EVERY exit stamps the attempt, not just the successful ones (`abandonPass`). A pass that bails
        // — secure field, no shareable content, capture failure — must still start the throttle clock,
        // or the cadence keeps seeing `lastPassAt == nil`, returns `run(...)` on every prediction, and a
        // persistently failing capture becomes an unthrottled whole-screen capture loop: precisely the
        // battery scenario the cadence exists to prevent.

        // Re-check the secure-field guard at pass time: focus may have moved into a password field
        // between the kick and here, and guard (ii) suppresses the WHOLE capture, not one window.
        // Kept as depth even though it has never been observed to fire — the protection that actually
        // holds today is the predict-path dormancy documented at `cachedContext`, and this is what
        // would catch a regression of it.
        guard !focusedFieldIsSecure() else { return abandonPass() }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return abandonPass() }

        // Pre-capture exclusion (scrub-chain guard (iv)) — these apps' pixels are never captured.
        let excludedApps = content.applications.filter {
            excludedBundleIDs.contains($0.bundleIdentifier)
        }

        let focused = focusedWindowIdentity(in: content)
        let displayRects = content.displays.map { ($0.displayID, Self.displayRect($0)) }
        let windows = content.windows.map { Self.screenWindow(from: $0, displays: displayRects) }
        let bands = Self.chromeBands()

        // ---- Capture every on-line display (cheap next to recognition; cross-monitor is what makes
        //      ambient reference context work at all). ----
        var captures: [(image: CGImage, displayRect: OCRRect)] = []
        for display in content.displays {
            let filter = SCContentFilter(
                display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let displayRect = Self.displayRect(display)
            // Native pixel resolution — umlaut fidelity has priority over speed.
            let scale = Self.backingScale(for: display)
            config.width = Int(displayRect.width * scale)
            config.height = Int(displayRect.height * scale)
            config.showsCursor = false

            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) {
                captures.append((image, displayRect))
            }
        }
        guard !captures.isEmpty else { return abandonPass() }

        // ---- Perceptual pre-diff, over ALL displays combined: one hash for the whole screen state,
        //      so a change on any monitor forces the read and an unchanged screen costs no recognition.
        //      An unhashable capture yields `nil` ⇒ treated as changed (fail toward correct context). ----
        let combinedHash: UInt64? = captures.reduce(into: UInt64?.some(0)) { accumulated, capture in
            guard accumulated != nil,
                  let grid = Self.grayscaleGrid(from: capture.image),
                  let hash = PerceptualScreenHash.hash(grayscaleGrid: grid)
            else { accumulated = nil; return }
            // Rotate before mixing so two displays swapping content still changes the combined hash.
            accumulated = (accumulated! << 1 | accumulated! >> 63) ^ hash
        }
        if let combinedHash {
            // The shortcut is only valid for the surface the cache already describes. On a NEW surface
            // the pixels may well be identical (an 8×8 dHash is coarse, and a focus change often moves
            // nothing on screen) while the *attribution* has changed completely — the focused window is
            // a different one, so Tier 1 and Tier 2 are re-assigned. Taking the shortcut there would
            // serve App A's text as App B's screen context.
            let unchanged = state.withLock { s -> Bool in
                let sameSurface = s.surfaceKey == surfaceKey && s.context != nil
                let same = sameSurface
                    && PerceptualScreenHash.isUnchanged(previous: s.lastHash, current: combinedHash)
                s.lastHash = combinedHash
                return same
            }
            if unchanged {
                // Nothing changed — keep the cached text and just re-stamp it, so the TTL doesn't
                // expire context that is still accurate.
                state.withLock { s in s.lastPassAt = ProcessInfo.processInfo.systemUptime }
                #if DEBUG
                acLog("[ocr]: pre-diff unchanged — recognition skipped")
                #endif
                return
            }
        }

        let blocks = captures.flatMap { Self.recognize($0.image, displayRect: $0.displayRect) }

        let attributed = OCRWindowAttribution.attribute(
            blocks: blocks, windows: windows, focusedWindowID: focused?.windowID, screenBands: bands)

        let context = buildContext(
            from: attributed,
            focused: focused,
            axWindowContext: axWindowContext)

        state.withLock { s in
            s.context = context
            s.lastPassAt = ProcessInfo.processInfo.systemUptime
            s.surfaceKey = surfaceKey
        }

        #if DEBUG
        acLog("[ocr]: pass blocks=%ld windows=%ld ambient=%ld focusedFill=%ld",
              blocks.count, windows.count,
              context?.ambient?.count ?? 0, context?.focusedFill?.count ?? 0)
        #endif
    }

    /// A pass that produced no text: start the throttle clock anyway so a persistently failing capture
    /// can't spin. The surface is deliberately NOT claimed — `surfaceKey` records which surface the
    /// cached *text* describes, and this pass produced none.
    private func abandonPass() {
        state.withLock { $0.lastPassAt = ProcessInfo.processInfo.systemUptime }
    }

    /// Turn attributed blocks into the two prompt roles: the value-checked focused fill and the ranked
    /// ambient text. Chrome never reaches this — it was dropped at attribution.
    private func buildContext(
        from attributed: [OCRWindowAttribution.AttributedBlock],
        focused: (windowID: UInt32, rect: OCRRect, displayID: UInt32)?,
        axWindowContext: String?
    ) -> OCRContext? {
        let usable = attributed.filter {
            $0.tier != .chrome && $0.block.confidence >= Budget.minimumConfidence
        }

        // Tier 1 — the focused window, gated by the OCR↔AX value-check.
        let focusedText = Self.joinInReadingOrder(usable.filter { $0.tier == .focused })
        var focusedFill: String?
        if !focusedText.isEmpty {
            switch OCRValueCheck.verdict(
                ocrText: SensitiveTextScrub.scrub(focusedText), axText: axWindowContext) {
            case .redundant:
                focusedFill = nil
            case .fill(let text):
                focusedFill = String(text.prefix(Budget.focusedFillChars))
            }
        }

        // Tier 2 — other content windows, grouped then ranked.
        let recency = recentApps.withLock { $0 }
        var byWindow: [UInt32: (window: ScreenWindow, blocks: [OCRWindowAttribution.AttributedBlock])] = [:]
        for item in usable where item.tier == .ambient {
            guard let window = item.window else { continue }
            byWindow[window.windowID, default: (window, [])].blocks.append(item)
        }
        let candidates = byWindow.values.map { entry in
            OCRAmbientRanking.Candidate(
                window: entry.window,
                text: String(SensitiveTextScrub.scrub(Self.joinInReadingOrder(entry.blocks))
                    .prefix(Budget.ambientPerWindowChars)),
                recencyIndex: entry.window.bundleID.flatMap { recency.firstIndex(of: $0) })
        }
        let ranked = OCRAmbientRanking.rank(
            candidates,
            focusedWindowRect: focused?.rect,
            focusedDisplayID: focused?.displayID,
            limit: Budget.ambientWindowLimit)
        let ambient = ranked.map(\.text).joined(separator: "\n\n")

        let context = OCRContext(
            ambient: ambient.isEmpty ? nil : ambient,
            focusedFill: focusedFill)
        return context.isEmpty ? nil : context
    }

    // MARK: - Vision

    /// Recognise text in one display's capture and map it into screen points.
    private static func recognize(_ image: CGImage, displayRect: OCRRect) -> [OCRTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = Budget.minimumTextHeightFraction
        // Intersect with what this machine actually supports, so an unavailable language can't make
        // the whole request fail (the user writes DE — losing DE silently would be the worst outcome).
        let wanted = ["de-DE", "en-US"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let available = wanted.filter { supported.contains($0) }
            if !available.isEmpty { request.recognitionLanguages = available }
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let rect = OCRGeometry.screenRect(
                normalizedX: box.origin.x,
                normalizedY: box.origin.y,
                normalizedWidth: box.size.width,
                normalizedHeight: box.size.height,
                in: displayRect)
            return OCRTextBlock(
                text: candidate.string, rect: rect, confidence: Double(candidate.confidence))
        }
    }

    /// Join blocks top-to-bottom then left-to-right — the reading order the prompt wants, which the
    /// Vision observation order does not guarantee.
    private static func joinInReadingOrder(_ items: [OCRWindowAttribution.AttributedBlock]) -> String {
        items
            .map(\.block)
            .sorted { lhs, rhs in
                // Same visual line (within half a line height) ⇒ order by x.
                if abs(lhs.rect.minY - rhs.rect.minY) < max(lhs.rect.height, rhs.rect.height) * 0.5 {
                    return lhs.rect.minX < rhs.rect.minX
                }
                return lhs.rect.minY < rhs.rect.minY
            }
            .map(\.text)
            .joined(separator: "\n")
    }

    // MARK: - Capture helpers

    /// dHash input: the capture downsampled to a 9×8 grayscale grid. Cheap next to recognition, which
    /// is the point — this is what lets an unchanged screen cost almost nothing.
    private static func grayscaleGrid(from image: CGImage) -> [[Double]]? {
        let width = PerceptualScreenHash.gridWidth + 1
        let height = PerceptualScreenHash.gridHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).map { row in
            (0..<width).map { column in Double(pixels[row * width + column]) }
        }
    }

    /// A display's frame in global top-left points (`CGDisplayBounds` semantics — the same space
    /// `SCWindow.frame` uses, so attribution compares like with like).
    private static func displayRect(_ display: SCDisplay) -> OCRRect {
        let bounds = CGDisplayBounds(display.displayID)
        return OCRRect(x: bounds.origin.x, y: bounds.origin.y,
                       width: bounds.size.width, height: bounds.size.height)
    }

    private static func backingScale(for display: SCDisplay) -> Double {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == display.displayID
        }
        return Double(screen?.backingScaleFactor ?? 2)
    }

    /// Reduce an `SCWindow` to the facts the pure decisions need, resolving which display it sits on
    /// (by frame intersection) so the ranking's same-display proximity bonus has something to compare.
    private static func screenWindow(
        from window: SCWindow, displays: [(UInt32, OCRRect)]
    ) -> ScreenWindow {
        let frame = window.frame
        let displayID = displays.first { _, rect in
            let centerX = frame.midX, centerY = frame.midY
            return rect.contains(x: centerX, y: centerY)
        }?.0 ?? displays.first?.0 ?? 0
        return ScreenWindow(
            windowID: window.windowID,
            bundleID: window.owningApplication?.bundleIdentifier,
            layer: window.windowLayer,
            rect: OCRRect(x: frame.origin.x, y: frame.origin.y,
                          width: frame.size.width, height: frame.size.height),
            displayID: displayID)
    }

    /// Menu-bar and Dock bands, in global top-left points: the strips of each screen's frame that its
    /// `visibleFrame` excludes. A geometric backstop for chrome that reports a content window layer.
    private static func chromeBands() -> [OCRRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        let flipTop = primary.frame.maxY
        return NSScreen.screens.flatMap { screen -> [OCRRect] in
            let frame = screen.frame
            let visible = screen.visibleFrame
            // Convert both to top-left origin before differencing.
            let frameTop = flipTop - frame.maxY
            let visibleTop = flipTop - visible.maxY
            var bands: [OCRRect] = []
            if visibleTop > frameTop {           // menu-bar strip
                bands.append(OCRRect(x: frame.minX, y: frameTop,
                                     width: frame.width, height: visibleTop - frameTop))
            }
            let frameBottom = frameTop + frame.height
            let visibleBottom = visibleTop + visible.height
            if frameBottom > visibleBottom {     // Dock strip (when the Dock is on the bottom)
                bands.append(OCRRect(x: frame.minX, y: visibleBottom,
                                     width: frame.width, height: frameBottom - visibleBottom))
            }
            return bands
        }
    }

    // MARK: - Focused window + secure-field guard (AX reads, kept minimal)

    /// Identify the focused window inside the ScreenCaptureKit snapshot by matching the frontmost
    /// app's pid and the AX focused window's frame. Deliberately avoids the private
    /// `_AXUIElementGetWindow`: a geometric match degrades to "no Tier-1" when it fails, whereas a
    /// private symbol degrades to a broken build on some future OS.
    private func focusedWindowIdentity(in content: SCShareableContent)
        -> (windowID: UInt32, rect: OCRRect, displayID: UInt32)?
    {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontmost.processIdentifier
        guard let axRect = Self.focusedWindowAXRect(pid: pid) else { return nil }

        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
        }
        // Best frame match — AX and CG frames agree to within rounding when they describe the same
        // window, so the nearest-origin candidate is the right one.
        let best = candidates.min { lhs, rhs in
            Self.frameDistance(lhs.frame, axRect) < Self.frameDistance(rhs.frame, axRect)
        }
        guard let best, Self.frameDistance(best.frame, axRect) < 40 else { return nil }
        let rect = OCRRect(x: best.frame.origin.x, y: best.frame.origin.y,
                           width: best.frame.size.width, height: best.frame.size.height)
        let displayID = content.displays.first {
            CGDisplayBounds($0.displayID).intersects(best.frame)
        }?.displayID ?? 0
        return (best.windowID, rect, displayID)
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        abs(lhs.origin.x - rhs.origin.x) + abs(lhs.origin.y - rhs.origin.y)
            + abs(lhs.size.width - rhs.size.width) + abs(lhs.size.height - rhs.size.height)
    }

    /// The focused window's frame via AX, in global top-left points (AX already uses that space).
    private static func focusedWindowAXRect(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let value = windowRef, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Scrub-chain guard (ii): a focused secure text field suppresses the **whole** capture. The
    /// pixels of a filled password field can land anywhere on screen, so window-scoping this would be
    /// a false guarantee.
    private func focusedFieldIsSecure() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        // This runs on the awaited predict path, so every AX read here is bounded: the timeout is
        // PER-OBJECT (AXUIElement.h), hence set on both the system-wide element and the focused one.
        // Without it an unresponsive frontmost app stalls the whole prediction pipeline.
        _ = AXUIElementSetMessagingTimeout(systemWide, Budget.axCallTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let element = focused as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(element, Budget.axCallTimeout)

        // Same shape as `AXContextProvider.isSecure` deliberately — one definition of "secure" across
        // both trust boundaries, so the AX guard and the pixel guard can't drift apart.
        if attribute(element, kAXRoleAttribute) == (kAXSecureTextFieldSubrole as String) { return true }
        if let subrole = attribute(element, kAXSubroleAttribute), subrole.contains("Secure") { return true }
        return false
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
