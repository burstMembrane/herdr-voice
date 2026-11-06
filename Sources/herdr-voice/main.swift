import AppKit
import HerdrVoiceCore

// ponytail: Swift 5 language mode with main-queue confinement instead of actors; move to Swift 6 strict
// concurrency if the session grows more shared state.

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
let provider = Provider.cloudflare

// One-shot commands.
if args.count > 1 {
    switch args[1] {
    case "setup": exit(setupKey(for: provider) ? 0 : 1)
    case "stop":
        if let pid = SingleInstance.holder() { kill(pid, SIGTERM); print("stopped herdr-voice (pid \(pid))") } else { print("herdr-voice isn't running") }
        exit(0)
    case "help", "--help", "-h":
        print("""
        herdr-voice          start the voice (the orb, mic and speakers); Claude Code sessions connect to it as channels
        herdr-voice stop     stop the running voice
        herdr-voice setup    store the Worker token in the Keychain
        Settings: HERDR_VOICE_CF_URL (Worker websocket), HERDR_VOICE_VOICE, HERDR_VOICE_ORB_PIN=0, HERDR_VOICE_GATE_DEBUG=1
        """)
        exit(0)
    default: break
    }
}

if let holder = SingleInstance.acquire() {
    FileHandle.standardError.write(Data("herdr-voice is already running\(holder > 0 ? " (pid \(holder))" : ""); stop it with herdr-voice stop.\n".utf8))
    exit(1)
}

// No token yet: in a terminal, ask for it right away; otherwise say how to add one.
if provider.apiKey(environment: env) == nil, isatty(STDIN_FILENO) == 1 {
    print("No Worker token yet.")
    if !setupKey(for: provider) { exit(2) }
}
guard let apiKey = provider.apiKey(environment: env) else {
    FileHandle.standardError.write(Data("no Worker token. Add one with: herdr-voice setup (or set \(provider.keyEnv))\n".utf8))
    exit(2)
}
log("🔑 \(provider.keyEnv) from the \(apiKey.source.rawValue)") // where it came from, never the value
if env["HERDR_VOICE_ECHO_CANCEL"] == "0" { log("echo cancellation off (HERDR_VOICE_ECHO_CANCEL=0): use headphones") }

// Whatever was in front when we were launched: normally the terminal.
let launchedFrom = NSWorkspace.shared.frontmostApplication
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// An accessory app can still be activated at launch; it then holds focus with no window to type into, so
// keystrokes stop reaching the terminal (and the pinned orb hides). Hand focus straight back.
DispatchQueue.main.async {
    guard NSApp.isActive, let previous = launchedFrom, previous.processIdentifier != getpid() else { return }
    NSApp.yieldActivation(to: previous)
    previous.activate()
}

let session = Voice(key: apiKey.value, voice: provider.voice(configured: env["HERDR_VOICE_VOICE"]))

// Claude Code sessions connect here (see channel/); what you say goes to the one you picked, its replies come back to be spoken.
ChannelHub.shared.onSpeak = { name, text in session.speakText(name, text) }
ChannelHub.shared.start()

/// The orb's menu: which session you are talking to, summarising on or off, and the voice.
func menuChoices() -> [Orb.MenuChoice] {
    var sessions = Orb.MenuChoice(title: "Talking to", checked: false, enabled: !ChannelHub.shared.sessions.isEmpty, separatorAfter: true) {}
    sessions.children = ChannelHub.shared.sessions.map { name in
        Orb.MenuChoice(title: name, checked: name == ChannelHub.shared.targetName, enabled: true) { ChannelHub.shared.select(name) }
    }
    let compact = Orb.MenuChoice(title: "Summarise long replies", checked: ChannelMode.compact, enabled: true) { session.setCompact(!ChannelMode.compact) }
    var voice = Orb.MenuChoice(title: "Voice", checked: false, enabled: true) {}
    voice.children = provider.voices.map { name in
        Orb.MenuChoice(title: name, checked: name == session.voice, enabled: true) { session.changeVoice(name) }
    }
    return [sessions, compact, voice]
}

let orb = Orb(onClick: { session.toggleMute() }, menuChoices: menuChoices, onQuit: {
    session.shutdown()
    // A moment for the WebSocket close frame to go out.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
})
Hotkey.registerMute { session.toggleMute() }

// Pin the orb to the terminal window it was started from; HERDR_VOICE_ORB_PIN=0 keeps it in the screen corner.
let windowTracker = WindowTracker()
if env["HERDR_VOICE_ORB_PIN"] != "0" {
    windowTracker.start { hasHost, frame in
        if hasHost { orb.follow(frame) } else { orb.showInScreenCorner() }
    }
}

// Esc is grabbed only while the voice is audible, switched on playback start/stop rather than polled.
session.audio.onSpeakingChanged = { speaking in
    session.setSpeaking(speaking)
    Hotkey.setStopKey(active: speaking) { session.stopSpeech(reason: "Esc") }
}

orb.run {
    let a = session.audio
    let mood = Activity.mood(loading: false, disconnected: session.status == .disconnected, dormant: session.dormant,
                             muted: session.muted, speaking: a.isSpeaking, agentsWorking: session.thinking, micQuiet: a.micLevel < 0.02)
    // Both directions at once: talking over the voice shows your push and its core together.
    return Orb.Frame(mood: mood, mic: session.muted ? 0 : a.micLevel, voice: a.isSpeaking ? a.outLevel : 0,
                     thinking: session.status != .disconnected && session.thinking)
}

do {
    try session.start()
} catch {
    log("✖ audio: \(error.localizedDescription) — allow microphone access for your terminal in System Settings")
    exit(1)
}
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
app.run()
