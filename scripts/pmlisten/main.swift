// pmlisten: one hands-free dictation turn with Wispr Flow, as a comparator on the mic.
// When you start talking it holds the Fn key (Wispr's push-to-talk); when you stop it lets go. Wispr then writes the
// text to its local history, which this reads (and, with --submit and Herdr in front, sends with Return).
// Needs Accessibility (to press Fn) and microphone access. Exit codes: 0 text captured, 4 nothing said.
import AVFoundation
import AppKit
import ApplicationServices
import Foundation

var hold = 0.9, wait = 10.0, submit = false, verbose = false
var db = NSHomeDirectory() + "/Library/Application Support/Wispr Flow/flow.sqlite"
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--hold": hold = Double(it.next() ?? "") ?? hold      // seconds of quiet that end the sentence
    case "--wait": wait = Double(it.next() ?? "") ?? wait      // give up if nobody speaks for this long
    case "--submit": submit = true
    case "--verbose": verbose = true
    case "--db": db = it.next() ?? db
    default: print("usage: pmlisten [--hold s] [--wait s] [--submit] [--verbose] [--db file]"); exit(2)
    }
}
guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
    print("allow this terminal in Accessibility, then run again"); exit(3)
}

func fn(down: Bool) {
    guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 63, keyDown: down) else { return }
    e.type = .flagsChanged
    e.flags = down ? .maskSecondaryFn : []
    e.post(tap: .cghidEventTap)
}
func sqlite(_ sql: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["file:\(db)?mode=ro", sql]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// Loudness comparator: speech is anything 10 dB above the recent quiet level (and above -62 dBFS).
final class Detector {
    private let lock = NSLock()
    private(set) var speaking = false
    private(set) var lastLoud = Date.distantPast
    private var ring = [Float](), loudRun = 0, _level: Float = -120, _floor: Float = -90
    var level: Float { lock.withLock { _level } }
    var floorDb: Float { lock.withLock { _floor } }
    var isSpeaking: Bool { lock.withLock { speaking } }
    var quietFor: TimeInterval { lock.withLock { Date().timeIntervalSince(lastLoud) } }
    func feed(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        var sum: Float = 0; for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        let db = 10 * log10(max(sum / Float(max(buf.frameLength, 1)), 1e-10))
        lock.withLock {
            _level = db
            _floor = ring.isEmpty ? -90 : ring.sorted()[ring.count / 5]
            let loud = db > max(_floor + 10, -62)
            if loud { loudRun += 1; lastLoud = Date(); if loudRun >= 2 { speaking = true } }
            else { loudRun = 0; if speaking, Date().timeIntervalSince(lastLoud) > 0.25 { speaking = false } }
            if !speaking { ring.append(db); if ring.count > 140 { ring.removeFirst() } }
        }
    }
}
let engine = AVAudioEngine(), detector = Detector(), t0 = Date()
func log(_ s: String) { print(String(format: "%5.2fs  ", Date().timeIntervalSince(t0)) + s); fflush(stdout) }
engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: engine.inputNode.outputFormat(forBus: 0)) { buf, _ in detector.feed(buf) }
engine.prepare()
do { try engine.start() } catch { print("engine failed: \(error)"); exit(6) }
Thread.sleep(forTimeInterval: 0.6)    // lets the quiet level settle
log("listening (say something)"); 

let rowsBefore = Int(sqlite("select count(*) from History")) ?? -1
let deadline = Date().addingTimeInterval(wait)
var keyDown = false, pressedAt = Date(), lastReport = Date()
var text = ""
mainLoop: while true {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    if verbose, Date().timeIntervalSince(lastReport) >= 1 { lastReport = Date(); log(String(format: "level %.0f dB, quiet level %.0f dB", detector.level, detector.floorDb)) }
    if !keyDown {
        if detector.isSpeaking { fn(down: true); keyDown = true; pressedAt = Date(); log("speech: holding Fn") }
        else if Date() > deadline { log("nothing said"); engine.stop(); exit(4) }
    } else if !detector.isSpeaking, detector.quietFor > hold {
        fn(down: false); keyDown = false; log("quiet: released Fn")
        if Date().timeIntervalSince(pressedAt) < 0.6 { continue }       // a blip, not a sentence; keep listening
        for _ in 0..<40 {                                                // up to 8 s for Wispr to write the text
            Thread.sleep(forTimeInterval: 0.2)
            if (Int(sqlite("select count(*) from History")) ?? -1) > rowsBefore {
                text = sqlite("select coalesce(nullif(formattedText,''), asrText, '') from History order by rowid desc limit 1")
                if !text.isEmpty { break mainLoop }
            }
        }
        log("Wispr wrote nothing; listening again")
    }
}
engine.stop()
log("TEXT: \(text)")
if submit {
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    if front.lowercased().contains("herdr") {
        Thread.sleep(forTimeInterval: 0.3)
        for d in [true, false] { CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 36, keyDown: d)?.post(tap: .cghidEventTap) }
        log("Return pressed in \(front)")
    } else { log("not pressing Return: front app is \(front)") }
}
exit(0)
