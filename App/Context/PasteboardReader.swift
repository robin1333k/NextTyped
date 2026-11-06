import AppKit
import NextTypedCore
import Foundation

/// The seam `ClipboardContextSource` reads the clipboard through, so a fake can stand in.
protocol ClipboardReading: Sendable {
    /// One observation of the general pasteboard for this predict. Never reads content unless
    /// `ClipboardContextPolicy.mayReadContent` allows it.
    func snapshot(enabled: Bool) -> ClipboardSnapshot
}

/// Reads `NSPasteboard.general` on the predict path, and only there: no timer, no observer.
///
/// Order, cheapest and least invasive first:
/// 1. `changeCount` (no content read) feeds `ClipboardAgeTracker`, so the first-seen age of a copy
///    is known even before the toggle is switched on.
/// 2. With the toggle off the reader stops. Nothing else is touched.
/// 3. `accessBehavior ==.alwaysDeny` (macOS 15.4+, the "Paste from Other Apps" setting) returns an
///    `osDenied` snapshot and stops.
/// 4. The type list is read for the nspasteboard.org concealed and transient markers.
/// 5. The string is read only if `mayReadContent` says the verdict could still be `inject`. A
///    content read is what raises the macOS paste alert, so every earlier return avoids it.
final class PasteboardReader: ClipboardReading, @unchecked Sendable {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let lock = NSLock()
    private var tracker = ClipboardAgeTracker()
    /// The bounded head of the string for one `changeCount`, so the content is read at most once per
    /// copy and not on every predict. Dropped when the count changes or the copy goes stale. In memory
    /// only, never stored.
    private var cachedHead: (changeCount: Int, text: String)?

    func snapshot(enabled: Bool) -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        let nowMs = Int(ProcessInfo.processInfo.systemUptime * 1000)
        lock.lock()
        let age = tracker.firstSeenAgeMs(changeCount: count, nowMs: nowMs)
        lock.unlock()

        guard enabled else {
            // Switched off: keep none of the last copy in memory.
            lock.lock()
            cachedHead = nil
            lock.unlock()
            return ClipboardSnapshot(enabled: false, changeCount: count, firstSeenAgeMs: age)
        }
        if Self.accessIsDenied(pasteboard) {
            return ClipboardSnapshot(enabled: true, osAccessDenied: true, changeCount: count,
                                     firstSeenAgeMs: age)
        }
        let types = pasteboard.types ?? []
        let concealed = types.contains(Self.concealedType)
        let transient = types.contains(Self.transientType)
        let hasText = types.contains(.string)
        var text = ""
        if hasText, ClipboardContextPolicy.mayReadContent(
            enabled: true, osAccessDenied: false, isConcealed: concealed,
            isTransient: transient, firstSeenAgeMs: age) {
            lock.lock()
            let cached = cachedHead
            lock.unlock()
            if let cached, cached.changeCount == count {
                text = cached.text
            } else {
                // Bounded before it is kept, like the policy bounds it before it works on it.
                text = String((pasteboard.string(forType: .string) ?? "")
                    .prefix(ClipboardContextPolicy.boundedHeadChars))
                lock.lock()
                cachedHead = (count, text)
                lock.unlock()
            }
        } else {
            lock.lock()
            cachedHead = nil
            lock.unlock()
        }
        return ClipboardSnapshot(enabled: true, changeCount: count, firstSeenAgeMs: age,
                                 isConcealed: concealed, isTransient: transient,
                                 hasText: hasText, text: text)
    }

    /// Whether macOS blocks pasteboard reading for this app. Reads no content, so it raises no paste
    /// alert; the Privacy row uses it to show the blocked state.
    static func accessIsDenied(_ pasteboard: NSPasteboard) -> Bool {
        if #available(macOS 15.4, *) { return pasteboard.accessBehavior == .alwaysDeny }
        return false
    }
}

/// Decides the clipboard context for one predict. `ContextAssembler` calls it only for an enabled app
/// , so a disabled app never reaches the pasteboard or logs a `[clip]` line.
///
/// An actor on purpose: the assembler is on the main actor, where the event tap runs, and a pasteboard
/// read can block (a promised type waits for the source app, the macOS paste alert waits for the
/// user). Awaiting this actor keeps that wait off the main thread.
actor ClipboardContextSource {
    private let reader: ClipboardReading
    /// The `clipboardContextEnabled` opt-in, re-read on every predict. Absent means off.
    private let isOn: @Sendable () -> Bool

    init(reader: ClipboardReading, isOn: @escaping @Sendable () -> Bool) {
        self.reader = reader
        self.isOn = isOn
    }

    func text(for context: TypingContext) async -> String? {   // actor-isolated: runs off the main actor
        let snapshot = reader.snapshot(enabled: isOn())
        let verdict = ClipboardContextPolicy.verdict(
            snapshot: snapshot, prefix: context.textBeforeCaret, windowContext: context.windowContext)
        #if DEBUG
        acLog("%@", verdict.logLine(ageMs: snapshot.firstSeenAgeMs))
        #endif
        if case .inject(let text) = verdict { return text }
        return nil
    }
}

extension ClipboardContextSource {
    /// The production wiring: the real pasteboard and the defaults key, as the port
    /// `ContextAssembler` awaits after the per-app check.
    static func livePort() -> (TypingContext) async -> String? {
        let source = ClipboardContextSource(
            reader: PasteboardReader(),
            isOn: { UserDefaults.standard.bool(forKey: "clipboardContextEnabled") })
        return { context in await source.text(for: context) }
    }
}
