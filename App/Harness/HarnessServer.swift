#if DEBUG
import Foundation

/// The DEBUG-only query channel of the runtime harness: a UNIX-domain socket
/// speaking line-delimited JSON — one request object per line in, one reply object per line out.
/// Compiled only into DEBUG builds and started only when `NEXTTYPED_HARNESS_SOCKET` is set, so a
/// normal launch (and every release build) has no listener at all.
///
/// The server owns nothing but the socket: every request is handed to `handler` on the caller's
/// choice of actor (the coordinator answers on the main actor) and the returned JSON is written back.
/// Requests are processed sequentially per connection; the socket file is created 0600.
final class HarnessServer: @unchecked Sendable {
    typealias Handler = @Sendable (String) async -> String   // JSON in, JSON out

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.robinklotz.NextTyped.harness", qos: .userInitiated)
    private var listenFD: Int32 = -1

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { acLog("[harness]: socket() failed errno=%d", errno); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            acLog("[harness]: socket path too long"); close(fd); return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { acLog("[harness]: bind() failed errno=%d", errno); close(fd); return }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else { acLog("[harness]: listen() failed errno=%d", errno); close(fd); return }
        listenFD = fd
        acLog("[harness]: listening at %@", path)
        queue.async { [self] in acceptLoop() }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { break }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let reply = awaitReply(String(decoding: line, as: UTF8.self))
                var out = Data(reply.utf8)
                out.append(0x0A)
                _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            }
        }
    }

    /// Bridge the async handler into the blocking per-connection thread.
    private func awaitReply(_ request: String) -> String {
        let box = ReplyBox()
        let sema = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task.detached {
            let r = await handler(request)
            box.set(r)
            sema.signal()
        }
        sema.wait()
        return box.get()
    }

    private final class ReplyBox: @unchecked Sendable {
        private var value = "{}"
        private let lock = NSLock()
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
    }
}
#endif
