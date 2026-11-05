import Foundation

/// The words the speech recognizer and the voice model must get right: Liam's project terms, the live agent names
/// and titles, and anything he adds to `~/.config/herdr-voice/keyterms.txt` (one per line).
public enum Vocabulary {
    public static let builtin: [String] = [
        "sheetmuse", "SheetMuse", "product manager", "PM", "Herdr", "herdr-voice", "worktree", "workspace", "pane", "panes", "tab",
        "TestFlight", "App Store Connect", "Xcode", "iOS", "Android", "RevenueCat", "PostHog", "Cloudflare", "Claude", "Codex",
        "Kokoro", "Prefect", "Triton", "MCP", "Clerk", "Spotify", "Apple Music", "setlist", "import queue", "ship gate",
        "release", "hotfix", "milestone", "pull request", "merge", "main", "demo", "prod", "dx sweep", "ledger", "digest",
    ]

    private static let lock = NSLock()
    private nonisolated(unsafe) static var live: [String] = []

    public static func file(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = env["HERDR_VOICE_KEYTERMS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/herdr-voice/keyterms.txt")
    }

    /// Live agent names first (most likely to be spoken), then the file, then the built-in list; no repeats, at most 80.
    public static func terms(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let fromFile = ((try? String(contentsOf: file(env), encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var seen = Set<String>(), out: [String] = []
        for term in lock.withLock({ live }) + fromFile + builtin {
            let t = String(term.prefix(40)), key = t.lowercased()
            if seen.insert(key).inserted { out.append(t) }
        }
        return Array(out.prefix(80))
    }

    /// Replaces the live names from the running agents. Runs the lookups off the caller's thread; never blocks it.
    public static func refresh(run: @escaping HerdrTools.Runner = HerdrTools.herdr) {
        guard HerdrTools.currentBackend == .hc else { return }
        DispatchQueue.global(qos: .utility).async {
            let names = HerdrTools.hcAgents(run).flatMap { a -> [String] in
                let spaced = a.target.replacingOccurrences(of: "-", with: " ")
                return [a.target, spaced, a.title].filter { !$0.isEmpty && !($0.count > 1 && $0.first == "t" && $0.dropFirst().allSatisfy { $0.isNumber || $0.isLetter } && $0.count <= 4) }
            }
            lock.withLock { live = names }
        }
    }

    /// Appended to the instructions so the model can repair what the recognizer got wrong.
    public static func promptSection(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        """
        Names and terms Liam uses. He speaks, so the transcript may mishear them: map near-sounds to these before acting.
        \(terms(env).joined(separator: ", ")).
        Common mishearings: "pain" or "pains" means pane or panes; "sheep muse", "sheet music" or "she muse" means sheetmuse; "pee em", "peem" or "PMs" means the PM (the product manager); "work tree" means worktree.
        """
    }
}
