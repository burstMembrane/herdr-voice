import Foundation

/// Channel mode (HERDR_VOICE_MODE=channel): the voice is only ears and a mouth. Each Claude Code session runs a small
/// MCP "channel" (channel/server.ts) that connects here over a Unix socket. What you say is sent to the target session as
/// a channel event; when that session calls its `speak` tool the text arrives here and is spoken. JSON lines both ways:
///   shim -> app   {"type":"hello","session":"pm"}   {"type":"speak","text":"..."}
///   app  -> shim  {"type":"transcript","text":"..."}
final class ChannelHub {
    static let on = ProcessInfo.processInfo.environment["HERDR_VOICE_MODE"] == "channel"
    static let shared = ChannelHub()
    static let path = NSHomeDirectory() + "/.config/herdr-voice/app.sock"

    var onSpeak: ((String, String) -> Void)?        // (session, text), called on the main queue
    private let lock = NSLock()
    private var clients: [Int32: String] = [:]      // fd -> session name
    private(set) var target: Int32?

    var sessions: [String] { lock.withLock { clients.values.sorted() } }

    func start() {
        unlink(Self.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { strncpy($0, Self.path, 103) }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 8) == 0 else { log("✖ channel socket: could not listen on \(Self.path)"); return }
        chmod(Self.path, 0o600)                      // only you
        log("● channel mode: waiting for Claude Code sessions on \(Self.path)")
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                self.read(c)
            }
        }
    }

    private func read(_ fd: Int32) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { chunk.deallocate(); close(fd); self.drop(fd) }
            while true {
                let n = Darwin.read(fd, chunk, 4096)
                if n <= 0 { return }
                buffer.append(chunk, count: n)
                while let nl = buffer.firstIndex(of: 10) {
                    let line = buffer[..<nl]; buffer = Data(buffer[buffer.index(after: nl)...])
                    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { continue }
                    if type == "hello" {
                        let name = o["session"] as? String ?? "session"
                        self.lock.withLock { self.clients[fd] = name; self.target = fd }       // the newest session is the target
                        DispatchQueue.main.async { log("● channel: \(name) connected (now the target)") }
                    } else if type == "speak", let text = o["text"] as? String {
                        let name = self.lock.withLock { self.clients[fd] ?? "session" }
                        DispatchQueue.main.async { self.onSpeak?(name, text) }
                    }
                }
            }
        }
    }

    private func drop(_ fd: Int32) {
        let name = lock.withLock { () -> String? in
            let n = clients.removeValue(forKey: fd)
            if target == fd { target = clients.keys.sorted().last }
            return n
        }
        if let name { DispatchQueue.main.async { log("○ channel: \(name) disconnected") } }
    }

    /// Sends what you said to the target session. False when no session is connected.
    @discardableResult func transcript(_ text: String) -> Bool {
        guard let fd = lock.withLock({ target }) else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "transcript", "text": text]) else { return false }
        var line = data; line.append(10)
        return line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) } > 0
    }
}
