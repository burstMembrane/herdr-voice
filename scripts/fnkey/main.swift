// fnkey: presses the Fn key (Wispr Flow's push-to-talk) from a script.
//   fnkey hold <seconds>   press Fn, hold, release (push-to-talk for that long)
//   fnkey tap | double     one Fn tap (ends hands-free) | double-tap (starts hands-free)
//   fnkey toggle           Fn+Space tap (not Wispr's hands-free gesture; kept for experiments)
// Needs Accessibility permission for the app that runs it (System Settings > Privacy & Security > Accessibility).
import ApplicationServices
import Foundation

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
    FileHandle.standardError.write(Data("fnkey: allow this terminal in System Settings > Privacy & Security > Accessibility, then run again\n".utf8))
    exit(3)
}
func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, modifier: Bool) {
    guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: down) else { return }
    if modifier { e.type = .flagsChanged }
    e.flags = flags
    e.post(tap: .cghidEventTap)
}
let fn: CGKeyCode = 63, space: CGKeyCode = 49
let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "hold":
    let secs = args.count > 2 ? Double(args[2]) ?? 1 : 1
    post(fn, down: true, flags: .maskSecondaryFn, modifier: true)
    Thread.sleep(forTimeInterval: secs)
    post(fn, down: false, flags: [], modifier: true)
case "tap":
    post(fn, down: true, flags: .maskSecondaryFn, modifier: true); Thread.sleep(forTimeInterval: 0.06); post(fn, down: false, flags: [], modifier: true)
case "double":
    for _ in 0..<2 { post(fn, down: true, flags: .maskSecondaryFn, modifier: true); Thread.sleep(forTimeInterval: 0.06); post(fn, down: false, flags: [], modifier: true); Thread.sleep(forTimeInterval: 0.12) }
case "toggle":
    post(fn, down: true, flags: .maskSecondaryFn, modifier: true)
    Thread.sleep(forTimeInterval: 0.08)
    post(space, down: true, flags: .maskSecondaryFn, modifier: false)
    post(space, down: false, flags: .maskSecondaryFn, modifier: false)
    Thread.sleep(forTimeInterval: 0.08)
    post(fn, down: false, flags: [], modifier: true)
default:
    print("usage: fnkey hold <seconds> | toggle"); exit(2)
}
