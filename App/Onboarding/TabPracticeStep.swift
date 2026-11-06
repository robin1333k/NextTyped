import AppKit
import NextTypedCore
import SwiftUI

/// Runtime half of the Tab practice step (issue `onboarding/148`): owns the pure-Core
/// `TabPracticeProgress`, the no-ghost timer and the persisted "finished" flag. The coordinator feeds
/// it what the real suggestion loop does; nothing here fakes a ghost.
@MainActor
final class TabPracticeModel: ObservableObject {
    /// UserDefaults key of the one-time guard. Set when the step is done, skipped, or its window closes.
    static let finishedKey = "onboarding.tabPracticeFinished"
    /// Seconds without any ghost before the fallback line appears.
    static let ghostTimeout: Duration = .seconds(10)

    @Published private(set) var progress = TabPracticeProgress()
    /// True while the practice field is on screen. Accepts elsewhere never count toward the step.
    private(set) var isActive = false
    /// True once the practice view appeared at least once. Closing the window before that (model still
    /// downloading) must not burn the one-time guard.
    private(set) var wasShown = false
    private var timeoutTask: Task<Void, Never>?

    static var alreadyFinished: Bool { UserDefaults.standard.bool(forKey: finishedKey) }

    static func markFinished() { UserDefaults.standard.set(true, forKey: finishedKey) }

    func activate() {
        guard !isActive, progress.phase == .practicing || progress.phase == .noGhost else { return }
        isActive = true
        wasShown = true
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.ghostTimeout)
            guard !Task.isCancelled else { return }
            self?.apply(.timeout)
        }
    }

    /// Window closed with Accessibility granted: finished if the view was shown, or if the model failed
    /// to load (the view can never show then, and the window must not reappear on every launch).
    func markFinishedOnClose(modelFailed: Bool) { if wasShown || modelFailed { Self.markFinished() } }

    func deactivate() {
        isActive = false
        timeoutTask?.cancel()
    }

    func noteGhost() { if isActive { apply(.ghostShown) } }

    /// Called with the key of an accept that inserted at least one word.
    func noteAccepted(_ key: AcceptanceKey) { if isActive { apply(.accepted(key)) } }

    func skip() { apply(.skip) }

    private func apply(_ event: TabPracticeProgress.Event) {
        progress.apply(event)
        #if DEBUG
        acLog("[onboarding]: tab-practice event=%@ phase=%@ word=%d all=%d", String(describing: event),
              String(describing: progress.phase), progress.wordAccepted ? 1 : 0, progress.allAccepted ? 1 : 0)
        #endif
        switch progress.phase {
        case .done, .skipped:
            Self.markFinished()
            timeoutTask?.cancel()
        case .practicing, .noGhost:
            break
        }
    }
}

/// The last onboarding step: a prefilled sentence start in a real text area, so the actual loop offers a
/// ghost and the user takes it with `Tab` and `⌥Tab`.
struct TabPracticeStepView: View {
    @ObservedObject var practice: TabPracticeModel
    @State private var text = "Thanks for your message. I would like to "

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if practice.progress.phase != .skipped {
                Divider()
                Text("Try it").font(.headline)
            }
            switch practice.progress.phase {
            case .done:
                Label("Done. \(keys.word) takes one word, \(keys.all) takes the rest.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .skipped:
                EmptyView()
            case .practicing, .noGhost:
                instructions
                TextEditor(text: $text)
                    .font(.body)
                    .frame(height: 72)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                    .accessibilityLabel("Practice field")
                if practice.progress.phase == .noGhost {
                    Text("No suggestion appeared. Open Settings → Setup to check the model and permissions.")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Skip") { practice.skip() }
                }
            }
        }
        .onAppear { practice.activate() }
        .onDisappear { practice.deactivate() }
    }

    /// The user's accept keys, so a rebound key is the one the step asks for.
    private var keys: (word: String, all: String) {
        let bindings = AppSettingsStore().interceptBindings
        return (bindings[.acceptWord].label, bindings[.acceptAll].label)
    }

    private var instructions: some View {
        let progress = practice.progress
        return VStack(alignment: .leading, spacing: 4) {
            Label("Press \(keys.word) to take one word of the gray suggestion.",
                  systemImage: progress.wordAccepted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(progress.wordAccepted ? Color.green : Color.primary)
            Label("Press \(keys.all) to take the rest.",
                  systemImage: progress.allAccepted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(progress.allAccepted ? Color.green : Color.primary)
            Text("Click into the field and type a few words if no suggestion shows yet.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
