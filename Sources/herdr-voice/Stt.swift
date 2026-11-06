import Foundation

/// Which engine turns your voice into text. Switched from the orb's Speech-to-text menu.
///  cloudflare: mic audio streams to the Worker (Deepgram Flux), which also drives turn-taking.
///  wispr:      the speech gate holds Wispr Flow's Fn key; its saved text is used (see Wispr.swift).
///  apple:      the AppleSTT helper app transcribes on-device and appends sentences to a file that is read here.
enum Stt: String, CaseIterable {
    case cloudflare, wispr, apple
    nonisolated(unsafe) static var current = Stt(rawValue: ProcessInfo.processInfo.environment["HERDR_VOICE_STT"] ?? "") ?? .cloudflare
    var title: String { self == .cloudflare ? "Cloudflare (Flux)" : self == .wispr ? "Wispr Flow" : "Apple on-device" }
}

enum AppleStt {
    static let app = NSHomeDirectory() + "/.local/share/herdr-voice/AppleSTT.app"
    static let out = NSHomeDirectory() + "/.config/herdr-voice/apple-stt.out"
    private static var timer: DispatchSourceTimer?
    private static var offset: UInt64 = 0

    /// Launches the helper and calls `onText` (main queue) for every sentence it writes from now on.
    static func start(onText: @escaping (String) -> Void) {
        stop()
        offset = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? UInt64) ?? 0   // old lines are not news
        run("/usr/bin/open", ["-n", "-g", "-a", app])
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now() + 0.5, repeating: 0.25)
        t.setEventHandler {
            guard let h = FileHandle(forReadingAtPath: out) else { return }
            defer { try? h.close() }
            try? h.seek(toOffset: offset)
            let data = h.readDataToEndOfFile()
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8), s.hasSuffix("\n") else { return }
            offset += UInt64(data.count)
            for line in s.split(separator: "\n") {
                let text = line.split(separator: "\t", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { DispatchQueue.main.async { onText(text) } }
            }
        }
        t.resume(); timer = t
    }

    static func stop() {
        timer?.cancel(); timer = nil
        run("/usr/bin/pkill", ["-x", "AppleSTT"])
    }

    private static func run(_ exe: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        try? p.run()
    }
}
