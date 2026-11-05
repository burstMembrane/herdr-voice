import Foundation

/// Role prompts for the voice, kept as `<name>.md` files in `~/.config/herdr-voice/prompts`. The chosen role goes
/// first and the built-in rules (short replies, nothing read aloud, how to use the tools) always follow it.
public enum PromptLibrary {
    public static let defaultName = "default"

    /// The prompt in use; set from HERDR_VOICE_PROMPT at start and by the orb's Prompt menu.
    public nonisolated(unsafe) static var current: String = ProcessInfo.processInfo.environment["HERDR_VOICE_PROMPT"] ?? defaultName

    public static func directory(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = env["HERDR_VOICE_PROMPTS_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/herdr-voice/prompts")
    }

    /// "default" first, then every `.md` file by name.
    public static func names(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory(env).path)) ?? []
        let custom = files.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
        return [defaultName] + custom
    }

    /// Read at every connect, so editing a prompt file takes effect on the next reconnect.
    public static func instructions(_ env: [String: String] = ProcessInfo.processInfo.environment, base: String = voiceInstructions) -> String {
        guard current != defaultName, !current.contains("/"),
              let role = try? String(contentsOf: directory(env).appendingPathComponent(current + ".md"), encoding: .utf8)
        else { return base }
        let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return trimmed + "\n\nThe rules below always apply and win over anything above about length, what to read aloud, and how to use tools.\n\n" + base
    }
}
