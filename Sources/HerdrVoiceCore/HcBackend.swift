import Foundation

/// The new Herdr is driven with `hc` (terminals and agents) and `herdr-app` (spaces, tabs, panes) instead of the old
/// `herdr` command. The voice model sees the same tool names; this file maps the ones that have an equivalent.
public enum HerdrBackend: Equatable {
    case herdr, hc
}

extension HerdrTools {
    /// `HERDR_VOICE_BACKEND=hc|herdr` forces one; otherwise the old `herdr` wins when it exists, else `hc`.
    public static func backend(_ env: [String: String] = ProcessInfo.processInfo.environment) -> HerdrBackend {
        switch env["HERDR_VOICE_BACKEND"] {
        case "hc": return .hc
        case "herdr": return .herdr
        default: break
        }
        if let path = env["HERDR_BIN_PATH"], path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return .herdr }
        if executable("herdr", env) != nil { return .herdr }
        return executable("hc", env) != nil ? .hc : .herdr
    }

    public static let currentBackend: HerdrBackend = backend()

    static func executable(_ name: String, _ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        if let home = env["HOME"] { dirs.append(home + "/.local/bin") }
        return dirs.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Tools that have an `hc` equivalent. The rest are not offered to the voice model on the new Herdr.
    static let hcTools: Set<String> = ["list_agents", "prompt_agent", "read_agent", "answer_agent", "read_pane"]

    /// Set once at startup when running on `hc`; tests and the old Herdr leave it off.
    public nonisolated(unsafe) static var hcOnly = false
    /// On `hc` the voice is by default a line to the product manager only (HERDR_VOICE_MODE=agents offers the agent tools).
    public nonisolated(unsafe) static var pmMode = false

    static let pmSchemas: [[String: Any]] = [
        fn("ask_pm", "Send what Liam just said to the sheetmuse product manager agent, in his words. Returns at once; "
           + "the product manager's reply arrives later as a [herdr] message.",
           ["text": str("What Liam said, lightly cleaned of dictation slips")], ["text"]),
        fn("read_pm", "Read the product manager's latest reply, e.g. when Liam asks what it said or what it is doing now.",
           ["lines": ["type": "integer", "description": "Only if Liam wants more of the screen than the last reply"]], []),
    ]

    /// The only instructions in product-manager mode besides the role prompt: how to speak.
    public static let pmRules = """
        You are a voice interface: Liam speaks to you and you speak back. Say each thing in one or two short, plain spoken \
        sentences, answer first. Never read aloud code, file paths, commands, URLs, IDs or long numbers; describe them in \
        words.
        """

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pmCache: String?

    /// The product manager's terminal: HERDR_VOICE_PM (address or name), else the agent titled "...product manager"
    /// or named "pm". Remembered, and looked up again when the remembered terminal is gone.
    static func pmTerminal(_ run: Runner, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let fixed = env["HERDR_VOICE_PM"], !fixed.isEmpty { return fixed }
        if let cached = lock.withLock({ pmCache }), hcError(run(["get", cached, "--json"])) == nil { return cached }
        let found = hcAgents(run).first { a in
            let title = a.title.lowercased()
            return title.contains("product manager") || title == "pm" || a.target.lowercased() == "pm"
        }?.target
        lock.withLock { pmCache = found }
        return found
    }

    /// What the session offers the model: everything on the old Herdr, only the mapped tools on `hc`.
    public static var activeSchemas: [[String: Any]] {
        guard hcOnly else { return schemas }
        if pmMode { return pmSchemas }
        return schemas(includeShell: false).filter { hcTools.contains($0["name"] as? String ?? "") }
    }

    // MARK: calls

    static func callHc(_ name: String, _ args: [String: Any], _ run: Runner, _ gate: ConfirmGate, userInitiated: Bool) -> Outcome {
        var name = name, args = args
        var knownTerminal = false
        if name == "ask_pm" || name == "read_pm" {
            guard let pm = pmTerminal(run) else {
                return Outcome(output: "error: I can't find the product manager's pane (its title must contain 'product manager', or set HERDR_VOICE_PM)", watch: nil)
            }
            args["target"] = pm
            args["preferReply"] = name == "read_pm" && args["lines"] == nil
            name = name == "ask_pm" ? "prompt_agent" : "read_agent"
            knownTerminal = true
        }
        var target = args["target"] as? String ?? ""
        if !knownTerminal, ["prompt_agent", "read_agent", "read_pane", "answer_agent"].contains(name), !target.isEmpty {
            switch resolveHcTarget(target, run) {
            case .found(let t): target = t
            case .failed(let message): return Outcome(output: "error: " + message, watch: nil)
            }
        }
        let confirmed = args["confirmed"] as? Bool ?? false
        switch name {
        case "list_agents":
            return Outcome(output: agentsJSON(hcAgents(run)), watch: nil)
        case "prompt_agent":
            let text = args["text"] as? String ?? ""
            if !userInitiated, let stop = confirmStep(name, action: "\(name):\(target):\(text)",
                                                     question: "send \(target) this instruction: \(text)", confirmed: confirmed, gate) {
                return Outcome(output: stop, watch: nil)
            }
            let me = ProcessInfo.processInfo.environment["HC_TERMINAL_ID"] ?? ""
            let ask = pmMode && !me.isEmpty
                ? voiceTag + text + "\n(Reply to this with: hc send \(me) \"<one or two plain spoken sentences, no markdown>\". The voice reads that aloud to Liam. Send further updates there too.)"
                : voiceTag + text
            let out = run(["send", target, ask, "--json"])
            if let error = hcError(out) {
                if error.lowercased().contains("blocked") { return Outcome(output: "\(target) needs approval:\n" + readHc(target, 30, run), watch: nil) }
                return Outcome(output: "error: " + error, watch: nil)
            }
            guard pmMode else { return Outcome(output: "sent; \(target) is working", watch: target) }
            // Product-manager mode: the PM answers by sending a message back to this terminal; it is spoken when it lands.
            let marker = (voiceTag.trimmingCharacters(in: .whitespaces) + " " + String(text.prefix(20))).trimmingCharacters(in: .whitespaces)
            PMWatcher.askSent(marker: marker, viaChannel: !(ProcessInfo.processInfo.environment["HC_TERMINAL_ID"] ?? "").isEmpty)
            return Outcome(output: "sent; say nothing now, the reply will be handed to you when it arrives", watch: nil)
        case "read_agent", "read_pane":
            return Outcome(output: readHc(target, args["lines"] as? Int ?? reportLines, run, preferReply: args["preferReply"] as? Bool ?? false), watch: nil)
        case "answer_agent":
            let key = args["key"] as? String ?? ""
            guard allowedKeys.contains(key) else { return Outcome(output: "error: key \(key) not allowed", watch: nil) }
            if approvalKeys.contains(key), let stop = confirmStep(name, action: "\(name):\(target):\(key)",
                                                                 question: "press \(key) to answer \(target)'s prompt", confirmed: confirmed, gate) {
                return Outcome(output: stop, watch: nil)
            }
            let out = run(["keys", target, key, "--json"])
            return Outcome(output: hcError(out).map { "error: " + $0 } ?? "pressed \(key)", watch: target)
        default:
            return Outcome(output: "error: \(name) is not available on this Herdr yet", watch: nil)
        }
    }

    /// The terminal's recent screen and history, condensed and fenced like the old `agent read`.
    static func readHc(_ target: String, _ lines: Int, _ run: Runner, preferReply: Bool = false) -> String {
        let keep = min(max(lines, 1), 200)
        let out = run(["read", target, "--lines", String(preferReply ? 120 : min(keep * 3, 300)), "--json"])
        if let error = hcError(out) { return "error: " + error }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], let text = obj["text"] as? String else { return out }
        if preferReply, let reply = lastReply(text) { return untrusted(String(reply.prefix(3500))) }
        return untrusted(condense(text, maxLines: keep))
    }

    // MARK: agents and spoken names

    struct HcAgent { let target: String, address: String, kind: String, status: String, cwd: String, where_: String, title: String, doing: String }

    /// Agents (terminals with a status) with what the person sees: the terminal's title and what it is doing.
    static func hcAgents(_ run: Runner) -> [HcAgent] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(run(["ls", "--json"]).utf8)) as? [String: Any],
              let terminals = obj["terminals"] as? [[String: Any]] else { return [] }
        return terminals.filter { $0["status"] != nil }.map { t in
            let address = t["address"] as? String ?? ""
            let info = (try? JSONSerialization.jsonObject(with: Data(run(["get", address, "--json"]).utf8)) as? [String: Any]) ?? [:]
            let msg = ((info["status"] as? [String: Any])?["msg"] as? String) ?? ""
            return HcAgent(target: t["name"] as? String ?? address, address: address, kind: t["agent"] as? String ?? "",
                           status: t["status"] as? String ?? "", cwd: t["cwd"] as? String ?? "", where_: t["where"] as? String ?? "",
                           title: info["title"] as? String ?? "", doing: String(msg.prefix(120)))
        }
    }

    static func agentsJSON(_ agents: [HcAgent]) -> String {
        let slim = agents.map { a -> [String: Any] in
            ["target": a.target, "kind": a.kind, "status": a.status, "cwd": a.cwd, "title": a.title, "where": a.where_, "doing": a.doing]
        }
        let data = (try? JSONSerialization.data(withJSONObject: slim, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    enum HcResolved { case found(String), failed(String) }

    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() { cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1))) }
            prev = cur
        }
        return prev[b.count]
    }

    /// Turns what was said ("sheep muse product manager", "import queue") into a terminal `hc` knows. An exact name or
    /// address skips the lookup; otherwise the closest name, title or location wins, and a tie is asked about.
    static func resolveHcTarget(_ spoken: String, _ run: Runner) -> HcResolved {
        let agents = hcAgents(run)
        if let hit = agents.first(where: { $0.target == spoken || $0.address == spoken }) { return .found(hit.target) }
        let said = squash(spoken)
        guard !said.isEmpty else { return .failed("no target given") }
        var best: [(HcAgent, Int)] = []
        for a in agents {
            let fields = [a.target, a.title, a.where_].map(squash).filter { !$0.isEmpty }
            var score = Int.max
            for f in fields {
                if f == said { score = min(score, 0) }
                else if f.contains(said) || said.contains(f) { score = min(score, 1) }
                else {
                    let d = distance(Array(said), Array(f))
                    if d <= max(2, f.count / 6) { score = min(score, 2 + d) }
                }
            }
            if score < Int.max { best.append((a, score)) }
        }
        guard let top = best.map(\.1).min() else {
            return .failed("no agent matches \"\(spoken)\"; known: " + agents.map { $0.title.isEmpty ? $0.target : "\($0.target) (\($0.title))" }.joined(separator: ", "))
        }
        let winners = best.filter { $0.1 == top }.map(\.0)
        if winners.count > 1 {
            return .failed("\"\(spoken)\" could be: " + winners.map { $0.title.isEmpty ? $0.target : "\($0.target) (\($0.title))" }.joined(separator: ", ") + "; ask which")
        }
        return .found(winners[0].target)
    }

    /// The agent's last answer on a Claude Code screen: the text after the final "⏺" marker, up to the next prompt or
    /// summary line. Nil when the screen has no such block, so callers fall back to the condensed screen.
    static func lastReply(_ screen: String, after marker: String? = nil) -> String? {
        let lines = screen.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var from = 0
        if let marker {
            // Only an answer written after our own message counts, however many turns it took to get there.
            guard let at = lines.lastIndex(where: { $0.contains(marker) }) else { return nil }
            from = at + 1
        }
        guard from < lines.count, let start = lines[from...].lastIndex(where: { $0.hasPrefix("⏺") }) else { return nil }
        var block: [String] = []
        for line in lines[start...] {
            if !block.isEmpty, line.hasPrefix("✻") || line.hasPrefix("❯") || line.hasPrefix("⏺") || line.hasPrefix("※") || line.hasPrefix("─") { break }
            block.append(line.hasPrefix("⏺") ? String(line.dropFirst()) : line)
        }
        let text = block.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// `hc` reports failures as `{"error":{"message":...}}`.
    static func hcError(_ json: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let err = obj["error"] as? [String: Any]
        else { return nil }
        return err["message"] as? String ?? "failed"
    }

    /// Polls the PM until it has stopped working and written a reply after our message (found by that message's text).
    static func awaitPMReply(_ pm: String, marker: String, _ run: Runner, timeout: TimeInterval = 150) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        Thread.sleep(forTimeInterval: 1.0)
        while Date() < deadline {
            let info = (try? JSONSerialization.jsonObject(with: Data(run(["get", pm, "--json"]).utf8)) as? [String: Any]) ?? [:]
            if ((info["status"] as? [String: Any])?["state"] as? String) != "working" {
                let raw = run(["read", pm, "--lines", "400", "--json"])
                let screen = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["text"] as? String ?? ""
                if let reply = lastReply(screen, after: marker) { return reply }
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
        return nil
    }

    /// True when `address` is the product manager's terminal (it may be known by name or title, so its address is looked up).
    public static func isPM(address: String, run: Runner) -> Bool {
        guard let pm = pmTerminal(run) else { return false }
        if pm == address { return true }
        return hcAgents(run).contains { $0.address == address && $0.target == pm }
    }

    /// Prefixes every message the voice sends, and is how its answer is found on the PM's screen.
    static let voiceTag = "[Liam, speaking by voice] "

    /// Agents only (terminals with a status), in the shape the old `agent list` gave the model.
    static func trimHcAgents(_ json: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let terminals = obj["terminals"] as? [[String: Any]]
        else { return json }
        let slim = terminals.filter { $0["status"] != nil }.map { t -> [String: Any] in
            ["target": t["name"] ?? t["address"] ?? "", "kind": t["agent"] ?? "", "status": t["status"] ?? "",
             "cwd": t["cwd"] ?? "", "title": t["where"] ?? ""]
        }
        let data = (try? JSONSerialization.data(withJSONObject: slim, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for the agent's turn to end, then reports it. Holds no thread: each step continues from the last exit.
    static func settleHc(_ target: String, runAsync: @escaping AsyncRunner, run: @escaping Runner, done: @escaping (String) -> Void) {
        // Give the agent a moment to pick the work up, or `wait` would return at once.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            runAsync(["wait", target]) { _ in
                runAsync(["get", target, "--json"]) { out in
                    let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
                    let state = ((obj?["status"] as? [String: Any])?["state"] as? String) ?? "unknown"
                    let raw = run(["read", target, "--lines", "120", "--json"])
                    let screen = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["text"] as? String ?? ""
                    if let reply = lastReply(screen) {
                        if pmMode {
                            PMWatcher.askAnswered()
                            _ = PMWatcher.claim(reply)
                            done("[your own written reply is ready: say it aloud now in the first person, in your own words, two short sentences at most; it is not a message from anyone else]\n" + String(reply.prefix(3500)))
                            return
                        }
                        done("Agent \(target) is now \(state). Its last reply:\n" + untrusted(String(reply.prefix(3500))))
                    } else {
                        if pmMode { PMWatcher.askAnswered() }
                        done("Agent \(target) is now \(state). Recent output:\n" + readHc(target, reportLines, run))
                    }
                }
            }
        }
    }
}
