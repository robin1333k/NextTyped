import Foundation

/// **Reply-context**: the interlocutor's most-recent turn in a reply surface — Claude's last
/// message, the email being answered, the chat turn above — none of which is in the focused compose field.
/// It is a *context-input* source: always-on + disclosure, activity-scoped ephemeral, never
/// learned. The App's AX layer performs the targeted descent and hands the harvested turns here; the
/// **recognition** and **speaker separation** — the parts worth unit-testing — are pure and live in this file.
///
/// The load-bearing invariant is **fail-closed speaker separation**: a turn is emitted ONLY
/// when its speaker label positively matches an interlocutor pattern and does NOT match a user pattern, so
/// the user's own turn is *structurally* never fed back into the prompt. Re-feeding the user's own text
/// craters simulated acceptance below baseline (offline measurements), so the costs are asymmetric: feeding
/// the interlocutor when unsure is mild, feeding the user's own text is the documented crater — hence
/// "no match ⇒ emit nothing" (graceful = today's no-reply-context behaviour).

/// Who a transcript turn belongs to, as classified from its speaker-label heading.
public enum ReplySpeaker: Equatable, Sendable {
    case user
    case interlocutor
    case unknown
}

/// One harvested transcript turn: the speaker-label heading (an `AXHeading` string like
/// `"Claude responded:"` / `"You said:"`) and the turn's collected text, in document order.
public struct ReplyTurn: Equatable, Sendable {
    public let speakerLabel: String?
    public let text: String

    public init(speakerLabel: String?, text: String) {
        self.speakerLabel = speakerLabel
        self.text = text
    }
}

/// A per-surface recipe: the *code* that walks and segments the tree is generic; this *data*
/// is the surface-specific recognition. v1 ships exactly one recipe — the Anthropic-chat structure shared
/// by claude.ai and Claude Desktop. New surfaces (Slack, Discord, Mail) graduate as new descriptors, not a
/// rewrite. The brittle, product-controlled English speaker strings are isolated in this one editable table.
public struct ReplySurfaceDescriptor: Sendable {
    public let id: String

    /// Bundle IDs this recipe applies to — the applicability gate. Non-chat apps never pay
    /// the descent. Safari is generic (any page), but the targeted descent fails fast off-path on a
    /// non-transcript tree, so the only cost there is one cached miss per window.
    public let bundleIDs: Set<String>

    /// Speaker-label substrings (matched case-insensitively) that mark a turn as the **interlocutor**.
    /// Carries locale variants: EN is spike-confirmed (product-controlled, in-string); DE is defensive —
    /// a wrong DE guess is fail-closed (no match ⇒ no reply-context), never a wrong attribution
    /// (open item: whether claude.ai localises these labels is a runtime-verify item).
    public let interlocutorPatterns: [String]

    /// Speaker-label substrings that mark a turn as the **user**. Checked FIRST so anything that looks
    /// even partly like the user is never emitted as the interlocutor.
    public let userPatterns: [String]

    /// Head-cap for the emitted turn's text (a single interlocutor turn can be a large code block / essay;
    /// the measured reply slice is ~40–100 tokens). The value is tuning; the policy is "cap it".
    public let headCapChars: Int

    public init(
        id: String,
        bundleIDs: Set<String>,
        interlocutorPatterns: [String],
        userPatterns: [String],
        headCapChars: Int
    ) {
        self.id = id
        self.bundleIDs = bundleIDs
        self.interlocutorPatterns = interlocutorPatterns
        self.userPatterns = userPatterns
        self.headCapChars = headCapChars
    }

    /// Classify a turn's speaker-label heading. **User patterns win** (fail-closed): if the label matches
    /// any user pattern it is `.user` even if it also happens to match an interlocutor pattern, so a
    /// mislabelled or ambiguous heading can never be attributed to the interlocutor.
    public func classify(_ label: String?) -> ReplySpeaker {
        guard let label = label?.lowercased(), !label.isEmpty else { return .unknown }
        if userPatterns.contains(where: { label.contains($0.lowercased()) }) { return .user }
        if interlocutorPatterns.contains(where: { label.contains($0.lowercased()) }) { return .interlocutor }
        return .unknown
    }

    /// The most-recent interlocutor turn's text, trimmed and head-capped — or `nil` (fail-closed) if no
    /// turn is *positively* attributed to the interlocutor. Turns are in document order (pre-order DFS ==
    /// doc order), so "most-recent" is the LAST turn classified as `.interlocutor` — exactly what one is
    /// replying to.
    public func selectReplyContext(from turns: [ReplyTurn]) -> String? {
        guard let turn = turns.last(where: { classify($0.speakerLabel) == .interlocutor }) else {
            return nil
        }
        let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(headCapChars))
    }

    /// v1 recipe — the Anthropic-chat transcript (claude.ai in Safari + Claude Desktop / Electron).
    /// Each turn carries an `AXHeading` speaker prefix: `"You said:"` (user) / `"Claude responded:"`
    /// (interlocutor). DE variants are best-effort defensive guesses (see `interlocutorPatterns`).
    public static let anthropicChat = ReplySurfaceDescriptor(
        id: "anthropic-chat",
        bundleIDs: [
            "com.anthropic.claudefordesktop",   // Claude Desktop (Electron)
            "com.apple.Safari",                 // claude.ai in Safari
        ],
        interlocutorPatterns: [
            "Claude responded",                 // EN — spike-confirmed
            "Claude said",
            "Claude hat geantwortet",           // DE — defensive (runtime-verify, residual (a))
            "Claude antwortete",
        ],
        userPatterns: [
            "You said",                         // EN — spike-confirmed
            "Du sagtest",                       // DE — defensive
            "Du hast gesagt",
            "Sie sagten",
        ],
        headCapChars: 1200
    )
}
