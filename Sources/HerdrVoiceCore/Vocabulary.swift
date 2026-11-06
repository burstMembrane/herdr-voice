import Foundation

/// Words the speech recognizer should expect: project terms plus anything in ~/.config/herdr-voice/keyterms.txt (one per line).
public enum Vocabulary {
    public static let builtin: [String] = [
        "sheetmuse", "SheetMuse", "Herdr", "Claude", "Claude Code", "Codex", "worktree", "TestFlight", "Xcode", "RevenueCat",
        "PostHog", "Cloudflare", "pull request", "merge", "hotfix", "milestone", "setlist", "Apple Music", "Spotify",
    ]

    public static func file(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = env["HERDR_VOICE_KEYTERMS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/herdr-voice/keyterms.txt")
    }

    /// The file's terms first, then the built-in list; no repeats, at most 80.
    public static func terms(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let fromFile = ((try? String(contentsOf: file(env), encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var seen = Set<String>(), out: [String] = []
        for term in fromFile + builtin {
            let t = String(term.prefix(40))
            if seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return Array(out.prefix(80))
    }
}
