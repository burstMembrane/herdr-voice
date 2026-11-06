// PM Voice: a menu-bar app for the hands-free voice loop. It owns the microphone and Accessibility permissions that a
// Claude Code hook cannot inherit. When the hook touches ~/.config/herdr-voice/listen-now it runs one turn: a loudness
// comparator holds Wispr Flow's push-to-talk key (Fn) while you speak and lets go when you stop, then reads Wispr's text
// from its local history and (optionally) presses Return in Herdr. Log: ~/.config/herdr-voice/pmvoice.log
import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

let configDir = NSHomeDirectory() + "/.config/herdr-voice"
let wisprDB = NSHomeDirectory() + "/Library/Application Support/Wispr Flow/flow.sqlite"

func logLine(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let path = configDir + "/pmvoice.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}
func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], modifier: Bool = false) {
    guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { return }
    if modifier { e.type = .flagsChanged }
    e.flags = flags
    e.post(tap: .cghidEventTap)
}
func sqlite(_ sql: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["file:\(wisprDB)?mode=ro", sql]
    let pipe = Pipe(); p.standardOutput = pipe
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Loudness comparator: speech is anything 10 dB above the recent quiet level (and above -62 dBFS).
final class Detector: @unchecked Sendable {
    private let lock = NSLock()
    private var ring = [Float](), loudRun = 0, _speaking = false, _lastLoud = Date.distantPast, _level: Float = -120
    var speaking: Bool { lock.withLock { _speaking } }
    var quietFor: TimeInterval { lock.withLock { Date().timeIntervalSince(_lastLoud) } }
    var level: Float { lock.withLock { _level } }
    func feed(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        var sum: Float = 0; for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        let db = 10 * log10(max(sum / Float(max(buf.frameLength, 1)), 1e-10))
        lock.withLock {
            _level = db
            let floor = ring.isEmpty ? -90 : ring.sorted()[ring.count / 5]
            if db > max(floor + 10, -62) { loudRun += 1; _lastLoud = Date(); if loudRun >= 2 { _speaking = true } }
            else { loudRun = 0; if _speaking, Date().timeIntervalSince(_lastLoud) > 0.25 { _speaking = false } }
            if !_speaking { ring.append(db); if ring.count > 140 { ring.removeFirst() } }
        }
    }
}

@MainActor final class Voice: ObservableObject {
    @Published var status = "Idle"
    @Published var last = ""
    @Published var loopOn: Bool { didSet { UserDefaults.standard.set(loopOn, forKey: "loopOn") } }
    @Published var submit: Bool { didSet { UserDefaults.standard.set(submit, forKey: "submit") } }
    @Published var phase = "idle"       // idle | listening | speaking | waiting
    private var running = false
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        UserDefaults.standard.register(defaults: ["loopOn": true, "submit": true])
        loopOn = UserDefaults.standard.bool(forKey: "loopOn")
        submit = UserDefaults.standard.bool(forKey: "submit")
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        AVCaptureDevice.requestAccess(for: .audio) { ok in logLine("microphone access: \(ok)") }
        watchTrigger()
        logLine("PM Voice started")
    }

    var icon: String { phase == "speaking" ? "mic.circle.fill" : phase == "listening" ? "mic.fill" : phase == "waiting" ? "ellipsis.circle" : loopOn ? "mic" : "mic.slash" }

    /// Reacts to the hook touching listen-now.
    private func watchTrigger() {
        let fd = open(configDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.checkTrigger() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
        checkTrigger()
    }
    private func checkTrigger() {
        let path = configDir + "/listen-now"
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(atPath: path)
        Task { await turn() }
    }

    func turn(wait: Double = 12, hold: Double = 0.9) async {
        guard loopOn, !running else { logLine("turn skipped (loop \(loopOn ? "on" : "off"), running \(running))"); return }
        running = true; defer { running = false; phase = "idle"; status = "Idle" }
        let engine = AVAudioEngine(), detector = Detector()
        engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: engine.inputNode.outputFormat(forBus: 0)) { buf, _ in detector.feed(buf) }
        engine.prepare()
        do { try engine.start() } catch { status = "Mic unavailable"; logLine("engine failed: \(error)"); return }
        defer { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        try? await Task.sleep(nanoseconds: 600_000_000)
        phase = "listening"; status = "Listening"; logLine("listening")
        let rowsBefore = Int(await Task.detached { sqlite("select count(*) from History") }.value) ?? -1
        let deadline = Date().addingTimeInterval(wait)
        var keyDown = false, pressedAt = Date()
        var peak: Float = -120
        while true {
            try? await Task.sleep(nanoseconds: 20_000_000)
            peak = max(peak, detector.level)
            if !keyDown {
                if detector.speaking { post(63, down: true, flags: .maskSecondaryFn, modifier: true); keyDown = true; pressedAt = Date(); phase = "speaking"; status = "Hearing you"; logLine("speech: holding Fn") }
                else if Date() > deadline { logLine(String(format: "nothing said (loudest %.0f dB)", peak)); return }
            } else if !detector.speaking, detector.quietFor > hold {
                post(63, down: false, modifier: true); keyDown = false; logLine("quiet: released Fn")
                if Date().timeIntervalSince(pressedAt) < 0.6 { phase = "listening"; status = "Listening"; continue }   // a blip
                phase = "waiting"; status = "Waiting for Wispr"
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if (Int(await Task.detached { sqlite("select count(*) from History") }.value) ?? -1) > rowsBefore {
                        let text = await Task.detached { sqlite("select coalesce(nullif(formattedText,''), asrText, '') from History order by rowid desc limit 1") }.value
                        if !text.isEmpty { await finish(text); return }
                    }
                }
                logLine("Wispr wrote nothing"); return
            }
        }
    }

    private func finish(_ text: String) async {
        last = text; logLine("TEXT: \(text)")
        guard submit else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == "dev.herdr.app" || (front?.localizedName ?? "").lowercased().contains("herdr") {
            try? await Task.sleep(nanoseconds: 300_000_000)
            post(36, down: true); post(36, down: false); logLine("Return pressed")
        } else { logLine("Return not pressed: front app is \(front?.localizedName ?? "?")") }
    }
}

@main struct PMVoiceApp: App {
    @StateObject private var voice = Voice()
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    var body: some Scene {
        MenuBarExtra { menu } label: { Image(systemName: voice.icon) }
    }
    @ViewBuilder var menu: some View {
        Text(voice.status)
        if !voice.last.isEmpty { Text("Last: \(String(voice.last.prefix(60)))") }
        Divider()
        Toggle("Voice loop", isOn: $voice.loopOn)
        Toggle("Press Return after dictating", isOn: $voice.submit)
        Button("Listen now") { Task { await voice.turn() } }
        Toggle("Open at login", isOn: Binding(get: { atLogin }, set: { on in
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; atLogin = on } catch { logLine("login item: \(error)") }
        }))
        Divider()
        Button("Quit PM Voice") { NSApp.terminate(nil) }
    }
}
