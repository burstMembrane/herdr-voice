import Foundation

/// Messages other terminals send to this one with `hc send` arrive as typed text: `<hc from="t1g">…</hc>`. The PM
/// replies to the voice this way, so this is the channel its answers (and anything it wants to tell Liam) come in on.
public final class TerminalInbox {
    private let queue = DispatchQueue(label: "herdr-voice.inbox", qos: .userInitiated)
    private var buffer = ""
    private let onMessage: (_ from: String, _ body: String) -> Void
    private nonisolated(unsafe) static var saved: termios?

    public init(onMessage: @escaping (_ from: String, _ body: String) -> Void) { self.onMessage = onMessage }

    /// Pulls every complete `<hc from="…">…</hc>` out of the text so far; whatever else was typed is dropped.
    func feed(_ chunk: String) {
        buffer += chunk
        let pattern = try! NSRegularExpression(pattern: #"<hc from="([^"]+)">(.*?)</hc>"#, options: [.dotMatchesLineSeparators])
        let ns = buffer as NSString
        for m in pattern.matches(in: buffer, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { onMessage(ns.substring(with: m.range(at: 1)), body) }
        }
        if let last = pattern.matches(in: buffer, range: NSRange(location: 0, length: ns.length)).last {
            buffer = ns.substring(from: last.range.location + last.range.length)
        }
        if !buffer.contains("<hc") { buffer = "" }
        if buffer.count > 40_000 { buffer = String(buffer.suffix(8_000)) }
    }

    /// Starts reading this process's terminal. Echo is turned off so pasted messages do not clutter the pane; it is
    /// turned back on when the process exits.
    public func start() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        var t = termios()
        if tcgetattr(STDIN_FILENO, &t) == 0 {
            Self.saved = t
            atexit { if var s = TerminalInbox.saved { s.c_lflag |= tcflag_t(ECHO); tcsetattr(STDIN_FILENO, TCSANOW, &s) } }
            t.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &t)
        }
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.feed(String(decoding: data, as: UTF8.self)) }
        }
    }
}
