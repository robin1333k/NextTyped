import NextTypedCore
import Foundation

/// Thread-safe holder of the process-wide ``DiagnosticsTagTally``. ``acLog`` feeds it; the exporter reads it.
/// It stores a tag and a closed-vocabulary token per event, never a log line.
final class DiagnosticsTallyHub: @unchecked Sendable {
    static let shared = DiagnosticsTallyHub()
    private let lock = NSLock()
    private var tally = DiagnosticsTagTally()

    func record(line: String) {
        lock.lock(); defer { lock.unlock() }
        tally.record(line: line)
    }

    var entries: [DiagnosticsTagTally.Entry] {
        lock.lock(); defer { lock.unlock() }
        return tally.entries
    }
}
