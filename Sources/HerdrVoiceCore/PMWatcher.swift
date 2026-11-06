import Foundation

/// Product-manager mode: notices when the PM's session finishes a turn by itself (a monitor event, an agent report)
/// and hands its reply to the voice, so Liam does not have to keep asking. Replies to the voice's own questions are
/// reported by the settle path instead; `claim` makes sure each reply is spoken once.
public final class PMWatcher {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastClaimed = ""
    private nonisolated(unsafe) static var outstanding = 0
    private nonisolated(unsafe) static var askedAt = Date.distantPast
    private nonisolated(unsafe) static var marker = ""
    private nonisolated(unsafe) static var viaChannel = false
    private nonisolated(unsafe) static var quietUntil = Date.distantPast

    /// True for the first caller with this reply text; later callers get false.
    static func claim(_ reply: String) -> Bool {
        lock.withLock {
            if reply == lastClaimed { return false }
            lastClaimed = reply
            return true
        }
    }
    /// The voice sent the PM a message; the first settled PM turn at or after `minTurn` is the answer.
    static func askSent(marker m: String = "", viaChannel channel: Bool = false) {
        lock.withLock { outstanding += 1; marker = m; askedAt = Date(); viaChannel = channel }
    }

    /// A reply arrived on the terminal: true when it answers something the voice asked. Unprompted screen updates stay
    /// quiet for a little afterwards so the same turn is not spoken twice.
    public static func messageArrived() -> Bool {
        lock.withLock {
            let answered = outstanding > 0 && Date().timeIntervalSince(askedAt) < 900
            outstanding = 0
            quietUntil = Date().addingTimeInterval(25)
            return answered
        }
    }
    static func askAnswered() { lock.withLock { outstanding = 0 } }
    /// An ask counts for 15 minutes; after that a silent PM no longer blocks unprompted updates.
    private static var asking: Bool { lock.withLock { outstanding > 0 && Date().timeIntervalSince(askedAt) < 900 } }
    /// Look at the PM's screen for the answer: always when there is no terminal channel, else once 45 s pass without a reply.
    private static var scraping: Bool { lock.withLock { outstanding > 0 && Date().timeIntervalSince(askedAt) < 900 && (!viaChannel || Date().timeIntervalSince(askedAt) > 45) } }
    private static var waitingForMessage: Bool { lock.withLock { outstanding > 0 && viaChannel && Date().timeIntervalSince(askedAt) <= 45 } }
    private static var quiet: Bool { lock.withLock { Date() < quietUntil } }
    private static var askMarker: String { lock.withLock { marker } }

    private let queue = DispatchQueue(label: "herdr-voice.pm-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastTurn: Int?
    private var pendingTurn: Int?
    private let run: HerdrTools.Runner
    private let onUpdate: (String) -> Void

    public init(run: @escaping HerdrTools.Runner = HerdrTools.herdr, onUpdate: @escaping (String) -> Void) {
        self.run = run
        self.onUpdate = onUpdate
    }

    public func start(every seconds: Double = 2) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    public func stop() { timer?.cancel(); timer = nil }

    func tick() {
        guard let pm = HerdrTools.pmTerminal(run),
              let obj = try? JSONSerialization.jsonObject(with: Data(run(["get", pm, "--json"]).utf8)) as? [String: Any],
              let turn = obj["turn"] as? Int else { return }
        let state = ((obj["status"] as? [String: Any])?["state"] as? String) ?? ""
        guard let seen = lastTurn else { lastTurn = turn; return } // what happened before we started is not news
        guard state != "working" else { return }
        if Self.scraping {
            // The voice asked something: its answer is the PM's reply written after our message, whatever the turn count.
            let raw = run(["read", pm, "--lines", "400", "--json"])
            let screen = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["text"] as? String ?? ""
            guard let reply = HerdrTools.lastReply(screen, after: Self.askMarker.isEmpty ? HerdrTools.voiceTag.trimmingCharacters(in: .whitespaces) : Self.askMarker) else { return }
            lastTurn = turn
            pendingTurn = nil
            Self.askAnswered()
            guard Self.claim(reply) else { return }
            onUpdate("[your own written reply is ready: say it aloud now in the first person, in your own words, two short sentences at most, under 40 words; it is not a message from anyone else]\n" + String(reply.prefix(3500)))
            return
        }
        guard !Self.waitingForMessage, !Self.quiet else { lastTurn = turn; return }
        guard turn > seen else { return }
        // Unprompted: two quiet looks in a row on the same turn, so a burst of turns is reported once, at its end.
        guard pendingTurn == turn else { pendingTurn = turn; return }
        lastTurn = turn
        pendingTurn = nil
        let raw = run(["read", pm, "--lines", "120", "--json"])
        let screen = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["text"] as? String ?? ""
        guard let reply = HerdrTools.lastReply(screen), Self.claim(reply) else { return }
        onUpdate("[your written mind finished a turn on its own and nobody asked: tell Liam in the first person, in two short sentences at most, only if it matters to him (a decision he must make, something finished, something failed or is blocked); otherwise reply with exactly SKIP and nothing else]\n" + String(reply.prefix(3500)))
    }
}
