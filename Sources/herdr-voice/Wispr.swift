import ApplicationServices
import Foundation

/// Wispr Flow as the speech-to-text engine: the gate's open/close hold and release its push-to-talk key (Fn), and the
/// text comes from Wispr's local history database (it has no API). Needs Accessibility to press Fn.
enum Wispr {
    static var enabled: Bool { Stt.current == .wispr }
    static let db = NSHomeDirectory() + "/Library/Application Support/Wispr Flow/flow.sqlite"

    static func start() {
        guard enabled else { return }
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            log("⚠ Wispr speech-to-text needs Accessibility (System Settings > Privacy & Security) for this terminal")
        }
    }

    static func fn(down: Bool) {
        guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 63, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = down ? .maskSecondaryFn : []
        e.post(tap: .cghidEventTap)
    }

    private static func query(_ sql: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["file:\(db)?mode=ro", sql]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rowCount() -> Int { Int(query("select count(*) from History")) ?? -1 }

    /// The text of the dictation Wispr saves after `rowsBefore`; nil if it writes nothing within `timeout`. Off the main queue.
    static func awaitText(after rowsBefore: Int, timeout: Double = 8) -> String? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.2)
            if rowCount() > rowsBefore {
                let text = query("select coalesce(nullif(formattedText,''), asrText, '') from History order by rowid desc limit 1")
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}
