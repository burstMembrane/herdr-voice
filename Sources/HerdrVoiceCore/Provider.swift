import Foundation

/// The speech service the app talks to: the Cloudflare Worker in worker/ (speech to text, text to speech).
public enum Provider: String, CaseIterable {
    case cloudflare

    public var url: URL { URL(string: ProcessInfo.processInfo.environment["HERDR_VOICE_CF_URL"] ?? "ws://127.0.0.1:8799/realtime")! }
    public var menuTitle: String { "Cloudflare" }
    /// Aura-2 voices offered in the orb's Voice menu.
    public var voices: [String] { ["draco", "hyperion", "apollo", "zeus", "saturn", "atlas", "orion", "pluto", "luna", "asteria"] }
    public var defaultVoice: String { "hyperion" }
    public var keyEnv: String { "HERDR_VOICE_CF_TOKEN" }
    public var keyPage: String { "" }
    public var keyPrefix: String { "" }
    public var requiresAPIKey: Bool { true }

    /// HERDR_VOICE_VOICE names the voice to start with.
    public func voice(configured: String?) -> String {
        if let configured, !configured.isEmpty { return configured }
        return defaultVoice
    }

    public func request(key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func makeWire() -> Wire { OpenAIRealtimeWire() }

    public enum KeySource: String {
        case keychain = "Keychain"
        case environment = "environment"
    }

    /// The token: the macOS Keychain first (service `keyEnv`), then the environment variable. Never logged.
    public func apiKey(environment: [String: String],
                       keychain: (String) -> String? = { Keychain.password(service: $0) }) -> (value: String, source: KeySource)? {
        if let value = keychain(keyEnv), !value.isEmpty { return (value, .keychain) }
        if let value = environment[keyEnv]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return (value, .environment) }
        return nil
    }

    /// The first message on a connection. The Worker speaks only: no AI model, no tools (a Claude Code session is the brain).
    public func sessionUpdate(voice: String) -> [String: Any] {
        ["type": "session.update", "session": [
            "voice": voice,
            "brain": "none",
            "compact": ChannelMode.compact,
            "keyterms": Vocabulary.terms(),
        ] as [String: Any]]
    }
}

/// Channel settings.
public enum ChannelMode {
    /// Condense long replies into a short spoken update (on by default; switch it in the orb menu).
    public nonisolated(unsafe) static var compact: Bool = UserDefaults.standard.object(forKey: "compact") as? Bool ?? true {
        didSet { UserDefaults.standard.set(compact, forKey: "compact") }
    }
}

/// Reads generic passwords from the login Keychain.
///
/// Goes through /usr/bin/security rather than SecItem: an item added with `security add-generic-password` trusts
/// that tool, so reading it this way never prompts. SecItem from this unsigned binary would prompt again after
/// every rebuild, since each build has a different code signature. The secret only travels over a private pipe:
/// the command line carries just the service name, and stderr ("item not found") is discarded.
public enum Keychain {
    /// A pasted key, tidied: surrounding whitespace and quotes dropped. Nil unless what's left is only the
    /// characters API keys use, which also keeps it safe inside the quoted `security` command below.
    public static func cleanKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { return nil }
        return key
    }

    /// The `security -i` command line that saves (or replaces) `value`. Sent over a pipe, never as an argument,
    /// so the key doesn't show up in the process list or shell history. `value` must come from `cleanKey`.
    static func storeCommand(service: String, account: String, value: String) -> String {
        "add-generic-password -U -a \"\(account)\" -s \(service) -l \"herdr-voice \(service)\" -w \"\(value)\"\n"
    }

    /// Saves a key cleaned by `cleanKey` in the login Keychain, where `password(service:)` finds it.
    public static func store(service: String, value: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        input.fileHandleForWriting.write(Data(storeCommand(service: service, account: NSUserName(), value: value).utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0 && password(service: service) == value
    }

    public static func password(service: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }
}
