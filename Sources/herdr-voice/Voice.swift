import Foundation
import HerdrVoiceCore
import os

func log(_ line: String) {
    print(line)
    fflush(stdout)
}

/// The voice session: streams your speech to the Worker (speech to text), plays what the Worker says, hands what you said
/// to the Claude Code session (ChannelHub), and keeps the connection alive. All state is touched on the main queue except
/// `sendRaw`, which URLSessionWebSocketTask allows from any thread, and the mic path, which uses `micShared`.
final class Voice {
    enum Status { case connecting, live, disconnected }

    let provider = Provider.cloudflare
    private let key: String
    private(set) var voice: String
    let audio = Audio()
    private var socket: URLSessionWebSocketTask?
    private var wire: Wire
    private(set) var status = Status.disconnected { didSet { syncSendGate() } }
    private(set) var muted = false {
        didSet {
            syncSendGate()
            let m = muted
            micShared.withLock { $0.muted = m }
        }
    }
    /// Closed on purpose because nobody was talking; any speech reopens it.
    private(set) var dormant = false
    /// Since you spoke, waiting for the session to answer (drives the orb's "thinking").
    private var waitingSince: Date?
    var thinking: Bool { waitingSince.map { Date().timeIntervalSince($0) < 90 } ?? false }
    /// After a stop, audio still in flight for the cancelled reply is dropped until the next reply starts.
    private var droppingAudio = false

    // Reconnecting: networks drop, a Mac that slept can leave a dead socket behind, and the server closes idle sessions.
    private var connection = 0
    private var established = false { didSet { syncSendGate() } }
    private var attempts = 0
    private var closeReason: Reconnect.Reason?
    private var hadSession = false
    private var retryPending = false
    private var keepalive: DispatchSourceTimer?
    private var pongPending = false
    private var quietTimer: DispatchSourceTimer?

    // Speech-gated streaming: only speech is sent, and a quiet session is closed and reopened when you next speak.
    static let quietClose: TimeInterval = 180
    /// How recent the mic's own loud onset must be for the server's "speech started" to cut the voice off.
    static let bargeInWindow: TimeInterval = 1.5
    private var gate = SpeechGate<String>(
        overrideThreshold: ProcessInfo.processInfo.environment["HERDR_VOICE_GATE_THRESHOLD"].flatMap(Float.init))
    private let gateDebug = ProcessInfo.processInfo.environment["HERDR_VOICE_GATE_DEBUG"] == "1"
    private var meterPeak: Float = 0
    private var meterChunks = 0
    private struct MicShared {
        var muted = false
        var mayStream = false
        /// The server has heard speech start and not yet end: keep streaming so it sees the turn finish.
        var midTurn = false
        var lastSpeech = Date()
        var speaking = false
        /// Speech captured while the session was closed or reopening, sent once it's up (at most 10 s).
        var held = HeldMicAudio()
        var wire: Wire?
        /// The last time the mic heard a speech-loud chunk (above the gate's opening level).
        var lastLoud = Date.distantPast
    }
    private let micShared = OSAllocatedUnfairLock(initialState: MicShared())

    init(key: String, voice: String) {
        self.key = key
        self.voice = voice
        self.wire = Provider.cloudflare.makeWire()
        audio.onMic = { [weak self] b64, level in self?.micChunk(b64, level: level) }
    }

    func start() throws {
        try audio.start()
        connect()
        startQuietTimer()
    }

    // MARK: mic

    /// On the mic queue, every 20 ms.
    private func micChunk(_ b64: String, level: Float) {
        let (muted, midTurn) = micShared.withLock { ($0.muted, $0.midTurn) }
        if muted {
            gate.reset()
            return
        }
        let wasOpen = gate.isOpen
        if level > gate.openThreshold { micShared.withLock { $0.lastLoud = Date() } }
        let chunks = gate.process(b64, level: level, holdOpen: midTurn)
        let opened = gate.isOpen && !wasOpen
        let closed = wasOpen && !gate.isOpen
        if gateDebug { debugMeter(level: level, opened: opened, closed: closed) }
        guard !chunks.isEmpty else { return }
        let stream = { [weak self] (wire: Wire) in
            guard let self else { return }
            self.micShared.withLock { $0.lastSpeech = Date() }
            chunks.forEach { wire.encode(.appendAudio($0)).forEach(self.sendRaw) }
            if closed { wire.encode(.audioPaused).forEach(self.sendRaw) }   // the stream paused
        }
        if let wire = micShared.withLock({ $0.mayStream ? $0.wire : nil }) {
            stream(wire)
            return
        }
        // No session right now (closed while quiet, or reconnecting): retain at most ten seconds.
        let ready = micShared.withLock { state -> Wire? in
            if state.mayStream { return state.wire }
            state.held.appendCloud(chunks, opened: opened, closed: closed)
            state.lastSpeech = Date()
            return nil
        }
        if let wire = ready { stream(wire); return }
        DispatchQueue.main.async { self.wake() }
    }

    private func debugMeter(level: Float, opened: Bool, closed: Bool) {
        let floor = gate.noiseFloor, open = gate.openThreshold
        if opened || closed {
            let line = String(format: "🎚  gate %@  level %.4f  floor %.4f  open at %.4f", opened ? "OPEN " : "close", level, floor, open)
            DispatchQueue.main.async { log(line) }
        }
        meterPeak = max(meterPeak, level)
        meterChunks += 1
        guard meterChunks >= 250 else { return }   // every 5 s
        let line = String(format: "🎚  floor %.4f  open at %.4f  peak %.4f (last 5 s)", floor, open, meterPeak)
        meterPeak = 0
        meterChunks = 0
        DispatchQueue.main.async { log(line) }
    }

    /// Speech while there's no session. Reopens a session closed on purpose (quiet), or tries once more after giving up.
    /// Never while a retry is already scheduled: sound during an outage must not defeat the backoff.
    private func wake() {
        guard status == .disconnected, !muted, !retryPending else { return }
        if dormant {
            dormant = false
            attempts = 0
            log("🎙  heard you; reopening the session")
        }
        connect()
    }

    private func activateHeldAudio() {
        micShared.withLock { s in
            let held = s.held.drain()
            held.chunks.forEach { wire.encode(.appendAudio($0)).forEach(sendRaw) }
            if held.closed { wire.encode(.audioPaused).forEach(sendRaw) }
            // Enabling live streaming under the same lock keeps new mic packets behind this backlog.
            s.mayStream = !s.muted && status == .live
        }
    }

    private func syncSendGate() {
        let allowed = !muted && status == .live && established
        micShared.withLock { $0.mayStream = allowed }
    }

    /// Every 5 s: close a session nobody has talked to for `quietClose`, if nothing is speaking.
    private func startQuietTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.status == .live, self.established else { return }
            let quietFor = Date().timeIntervalSince(self.micShared.withLock { $0.lastSpeech })
            guard quietFor > Self.quietClose, !self.audio.isSpeaking, !self.thinking else { return }
            self.goDormant("no speech for \(Int(Self.quietClose / 60)) min")
        }
        timer.resume()
        quietTimer = timer
    }

    private func goDormant(_ why: String) {
        dormant = true
        if let s = socket {
            socket = nil
            s.cancel(with: .normalClosure, reason: nil)
        }
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        micShared.withLock { $0.midTurn = false }
        log("💤 \(why); session closed until you speak")
    }

    // MARK: connection

    func connect() {
        retryPending = false
        dormant = false
        micShared.withLock { $0.midTurn = false }
        connection += 1
        established = false
        closeReason = nil
        status = .connecting
        wire = provider.makeWire()
        let newWire = wire
        micShared.withLock { $0.wire = newWire }
        let task = URLSession.shared.webSocketTask(with: provider.request(key: key))
        socket = task
        task.resume()
        send(.setup(instructions: "", voice: voice, resumeHandle: nil))
        status = .live
        log(hadSession || attempts > 0 ? "↻ reconnecting"
            : "● connecting - speak any time, \(Hotkey.label) mutes, Esc stops speech")
        receive(task)
        startKeepalive(task)
    }

    /// The first server event on a socket: the session is really up.
    private func sessionEstablished() {
        log(hadSession ? "↻ reconnected" : "● connected")
        activateHeldAudio()   // speech held while the session reopened goes first
        established = true
        attempts = 0
        hadSession = true
    }

    private func connectionLost(_ task: URLSessionWebSocketTask, reason: Reconnect.Reason, detail: String) {
        guard task === socket else { return }
        socket = nil
        task.cancel(with: .goingAway, reason: nil)
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        waitingSince = nil
        if !established { attempts += 1 }
        // The server closed a quiet session: nothing to reconnect for until someone speaks.
        if reason == .sessionEnded && !muted {
            dormant = true
            log("💤 \(detail); reopens when you speak")
            return
        }
        scheduleRetry(reason: reason, detail: detail)
    }

    private func scheduleRetry(reason: Reconnect.Reason, detail: String) {
        guard let delay = Reconnect.delay(reason: reason, attempt: attempts, muted: muted) else {
            log(muted ? "… \(detail); reconnects when you unmute"
                      : "✖ \(detail); gave up after \(attempts) tries, press \(Hotkey.label) to reconnect")
            return
        }
        log(delay == 0 ? "↻ \(detail)" : "↻ \(detail); reconnecting in \(Int(delay)) s")
        let id = connection
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connection == id, self.status == .disconnected else { return }
            self.connect()
        }
    }

    /// Pings every 20 s. A failed ping, or no pong by the next one, means the socket is dead (sleep, network change)
    /// even though no error surfaced, so reconnect instead of waiting forever.
    private func startKeepalive(_ task: URLSessionWebSocketTask) {
        keepalive?.cancel()
        pongPending = false
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(2))
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else { return }
            if self.pongPending { return self.connectionLost(task, reason: .dropped, detail: "no reply to keepalive") }
            self.pongPending = true
            task.sendPing { error in
                DispatchQueue.main.async {
                    self.pongPending = false
                    if let error { self.connectionLost(task, reason: .dropped, detail: "keepalive failed: \(error.localizedDescription)") }
                }
            }
        }
        timer.resume()
        keepalive = timer
    }

    /// Replaces the connection (a new voice, say); the session carries on.
    private func renewConnection() {
        guard status == .live, let old = socket else { return }
        socket = nil   // its close must not count as a failure
        old.cancel(with: .normalClosure, reason: nil)
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        connect()
    }

    func shutdown() {
        log("👋 herdr-voice closed")
        guard let s = socket else { return }
        socket = nil
        s.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: controls

    func toggleMute() {
        if status == .disconnected {
            // Offline while muted means we were waiting for you: unmute and reconnect in one press.
            if muted {
                muted = false
                audio.setMuted(false)
                log("🎙  listening")
            }
            attempts = 0
            dormant = true   // no need to hold a session open before you say something
            log("🎙  listening; the session opens when you speak")
            return
        }
        muted.toggle()
        audio.setMuted(muted)
        if muted { send(.clearInput) }
        log(muted ? "🔇 muted" : "🎙  listening")
    }

    /// Stops the voice mid-sentence (Esc or a spoken "stop"): cancels the reply and drops queued audio.
    func stopSpeech(reason: String) {
        guard audio.isSpeaking else { return }
        send(.cancelReply)
        droppingAudio = true
        _ = audio.interrupt()
        log("⏹  stopped (\(reason))")
    }

    func changeVoice(_ newVoice: String) {
        guard newVoice != voice else { return }
        voice = newVoice
        log("♪ voice → \(newVoice)")
        renewConnection()
    }

    /// Turns the condensing of long replies on or off for the open connection.
    func setCompact(_ on: Bool) {
        ChannelMode.compact = on
        log("✎ summarise long replies: \(on ? "on" : "off")")
        sendRaw(["type": "config", "compact": on])
    }

    /// Called when the voice starts or stops being audible (mic side uses it to ignore the voice).
    func setSpeaking(_ on: Bool) {
        micShared.withLock { $0.speaking = on }
    }

    /// A Claude Code session asked the voice to say something.
    func speakText(_ session: String, _ text: String) {
        guard status == .live, established else { log("✖ \(session) wants to speak but the voice is not connected"); return }
        waitingSince = nil
        log("voice ← \(session)")
        sendRaw(["type": "speak", "text": text])
    }

    // MARK: server events

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    let text: String? = switch message {
                    case .string(let t): t
                    case .data(let d): WireFrame.text(d)
                    @unknown default: nil
                    }
                    if let text {
                        if !self.established { self.sessionEstablished() }
                        self.wire.decode(text).forEach(self.handle)
                    }
                    self.receive(task)
                case .failure(let err):
                    let reason = self.closeReason ?? .dropped
                    self.connectionLost(task, reason: reason,
                                        detail: reason == .sessionEnded ? "the server ended the session (idle or time limit)"
                                                                      : "disconnected: \(err.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .audioDelta(let item, let b64):
            if !droppingAudio { audio.play(base64: b64, item: item) }
        case .responseCreated:
            micShared.withLock { $0.midTurn = false }
            droppingAudio = false
        case .assistantTranscript(let t), .assistantTranscriptItem(_, let t):
            log("voice: \(t)")
        case .userTranscript(let t):
            log("you:   \(t.trimmingCharacters(in: .whitespacesAndNewlines))")
            if StopCommand.matches(t) { stopSpeech(reason: "you said stop"); return }
            if ChannelHub.shared.transcript(t) { waitingSince = Date() }
            else { log("✖ no Claude Code session is connected; nobody heard that") }
        case .speechStopped:
            micShared.withLock { $0.midTurn = false }
        case .speechStarted:
            micShared.withLock { $0.midTurn = true }
            // Barge-in: talking over the voice cuts its audio. The server also hears the voice's own echo and noise as
            // speech, so only cut when this mic heard a loud onset too.
            if micShared.withLock({ Date().timeIntervalSince($0.lastLoud) < Self.bargeInWindow }) { _ = audio.interrupt() }
        case .error(let msg):
            // A server ending the session (idle, time limit) is routine: note it and let the close renew it.
            if Reconnect.isSessionEnd(msg) { closeReason = .sessionEnded } else { log("✖ \(msg)") }
        case .sessionReady, .assistantTranscriptTruncated, .assistantTranscriptDelta, .responseDone, .functionCall,
             .localFunctionCall, .resumptionHandle, .sessionEnding, .ignored:
            break
        }
    }

    private func send(_ command: WireCommand) {
        wire.encode(command).forEach(sendRaw)
    }

    private func sendRaw(_ obj: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let id = connection
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async {
                // Failures on a socket that never came up, or has since been replaced, are already reported by the
                // reconnect logic; only a live session's send errors are news.
                guard let self, self.connection == id, self.established else { return }
                log("✖ send: \(err.localizedDescription)")
            }
        }
    }
}
