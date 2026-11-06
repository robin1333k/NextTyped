import Foundation

/// Publishes the current time once a minute while a Settings pane that shows remaining quiet minutes is
/// on screen. Started from the pane's `onAppear` and stopped from its `onDisappear`, the bounding
/// `InlinePredictionStatusModel` uses, so it never runs while nobody is looking and never touches the
/// typing path.
@MainActor
final class MinuteTicker: ObservableObject {
    @Published private(set) var now = Date()
    private var task: Task<Void, Never>?

    func start() {
        now = Date()
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.now = Date()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
