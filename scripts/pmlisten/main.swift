// pmlisten: one hands-free dictation turn with Wispr Flow, using macOS's built-in speech activity detection.
//   1. start the OS speech detector, 2. tap Wispr's hands-free toggle (Fn+Space) so it is already listening,
//   3. wait for speech to start and then end (plus a short hold), 4. tap the toggle again to finish,
//   5. read the new dictation from Wispr's local history, 6. with --submit and Herdr in front, press Return.
// Needs Accessibility permission (to press keys) and microphone access. Exit codes: 0 text captured, 4 nothing said.
import AVFoundation
import AppKit
import ApplicationServices
import Foundation

var hold = 1.0, wait = 8.0, submit = false, maxSpeech = 120.0
var db = NSHomeDirectory() + "/Library/Application Support/Wispr Flow/flow.sqlite"
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--hold": hold = Double(it.next() ?? "") ?? hold
    case "--wait": wait = Double(it.next() ?? "") ?? wait
    case "--submit": submit = true
    case "--db": db = it.next() ?? db
    default: print("usage: pmlisten [--hold s] [--wait s] [--submit] [--db file]"); exit(2)
    }
}
guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
    print("allow this terminal in Accessibility, then run again"); exit(3)
}

func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], modifier: Bool = false) {
    guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { return }
    if modifier { e.type = .flagsChanged }
    e.flags = flags
    e.post(tap: .cghidEventTap)
}
func toggleWispr() {   // Fn+Space, Wispr's hands-free toggle
    key(63, down: true, flags: .maskSecondaryFn, modifier: true); Thread.sleep(forTimeInterval: 0.08)
    key(49, down: true, flags: .maskSecondaryFn); key(49, down: false, flags: .maskSecondaryFn)
    Thread.sleep(forTimeInterval: 0.08); key(63, down: false, modifier: true)
}
func escape() { key(53, down: true); key(53, down: false) }
func historyCount() -> Int {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["file:\(db)?mode=ro", "select count(*) from History"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    return Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
}
func latestText() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["file:\(db)?mode=ro", "select coalesce(nullif(formattedText,''), asrText, '') from History order by rowid desc limit 1"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let engine = AVAudioEngine()
let input = engine.inputNode
do { try input.setVoiceProcessingEnabled(true) } catch { print("voice processing unavailable: \(error)"); exit(5) }
input.isVoiceProcessingInputMuted = true
if #available(macOS 14.0, *) { input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min) }

enum Phase { case waiting, speaking, quiet }
var phase = Phase.waiting
var speechEnded = Date.distantFuture
let t0 = Date()
func log(_ s: String) { print(String(format: "%5.2fs  ", Date().timeIntervalSince(t0)) + s); fflush(stdout) }
_ = input.setMutedSpeechActivityEventListener { event in
    if event == .started { phase = .speaking; log("speech started") }
    else { phase = .quiet; speechEnded = Date(); log("speech ended") }
}
engine.prepare()
do { try engine.start() } catch { print("engine failed: \(error)"); exit(6) }
Thread.sleep(forTimeInterval: 0.4)

let rowsBefore = historyCount()
toggleWispr(); log("Wispr listening (toggle sent)")
let armed = Date()
var stopped = false
while !stopped {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    if phase == .waiting, Date().timeIntervalSince(armed) > wait { log("nothing said; cancelling"); escape(); engine.stop(); exit(4) }
    if phase == .quiet, Date().timeIntervalSince(speechEnded) > hold { stopped = true }
    if Date().timeIntervalSince(armed) > maxSpeech { stopped = true }
}
toggleWispr(); log("stop sent; waiting for Wispr's text")
engine.stop()
var text = ""
for _ in 0..<40 {                       // up to 8 s for Wispr to finish and save
    Thread.sleep(forTimeInterval: 0.2)
    if historyCount() > rowsBefore { text = latestText(); if !text.isEmpty { break } }
}
if text.isEmpty { log("no text from Wispr"); exit(4) }
log("TEXT: \(text)")
if submit {
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    if front.lowercased().contains("herdr") { Thread.sleep(forTimeInterval: 0.3); key(36, down: true); key(36, down: false); log("Return pressed in \(front)") }
    else { log("not pressing Return: front app is \(front)") }
}
exit(0)
