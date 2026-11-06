/// Runs one async job at a time and lets later callers join it, so two quick model picks (or a pick and
/// a predict) share one load instead of starting two.
///
/// `forget()` cancels the job in flight and drops it from the slot. The next `run` then starts a new job.
/// Callers already awaiting the old job still get its (cancelled) result, and their own generation check
/// discards it.
public actor SingleFlight<Value: Sendable> {
    private var current: (id: Int, task: Task<Value, Never>)?
    private var nextID = 0

    public init() {}

    public var isRunning: Bool { current != nil }

    public func run(_ work: @escaping @Sendable () async -> Value) async -> Value {
        if let current { return await current.task.value }
        nextID += 1
        let id = nextID
        let task = Task { await work() }
        current = (id, task)
        let value = await task.value
        if current?.id == id { current = nil }
        return value
    }

    public func forget() {
        current?.task.cancel()
        current = nil
    }
}
