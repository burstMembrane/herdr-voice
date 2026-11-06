# Scope: herdr-voice as the voice front end for Claude Code sessions

Written 6 Nov 2026 from the Claude Code docs (channels, channels-reference, MCP) and VoiceMode's own docs. Facts below are
from those pages; anything marked "unverified" has not been tried on this machine.

## Goal

Speak to a Claude Code session the way `converse` (VoiceMode) lets you, but with herdr-voice's front end: the orb, the
mic gate and echo cancellation, Cloudflare speech-to-text and text-to-speech, prompts, vocabulary and routing. No Herdr
panes, no `hc`, no screen scraping, and no second AI model standing between you and the session. The session is the brain.

## The finding: Claude Code channels are the right primitive

A channel (research preview) is an MCP server that Claude Code spawns over stdio. It declares the `claude/channel`
capability and pushes `notifications/claude/channel` events (a `content` string plus `meta` attributes) into the
running session, where they arrive as `<channel source="..." ...>text</channel>`. A two-way channel also exposes a normal
MCP tool (a "reply tool") that Claude calls to send something back.

What that gives us that `converse` and our hc approach do not:

- **Events queue while Claude is busy.** You can speak at any time; it is not limited to the moments when the session
  happens to be waiting in a tool call.
- **Speech is input, not a tool result.** The session does not have to remember to call a listen tool.
- **Permission relay.** Tool-approval prompts (Bash, Write, Edit) can be forwarded to the channel, so approving by voice is
  possible. Whichever answer arrives first (terminal or channel) wins. Needs Claude Code v2.1.234+ and the
  `claude/channel/permission` capability. This machine runs 2.1.318.
- **`instructions`** on the server are delivered to Claude as context, so the "reply in one or two spoken sentences"
  style lives there instead of in a separate relay model.

How `converse` differs: it is an ordinary tool the session must call; the recording happens inside the MCP server; a
side "control channel" socket handles pause/stop; a "conch" lets one agent speak at a time. It is turn based, and the
session drives it.

## Architecture

```
mic -> herdr-voice app (gate, AEC, orb) -> Worker STT -> transcript
                |  unix socket (~/.config/herdr-voice/app.sock, mode 0600, per-install token)
          voice-channel shim  (MCP stdio server, one per Claude Code session)
                |  notifications/claude/channel  <channel source="voice" session="pm">...</channel>
          Claude Code session  --calls--> speak(text) --> shim --> app --> Worker TTS --> speakers
```

1. **App (exists):** keep Orb, Audio, SpeechGate, Prompt and Voice menus, Vocabulary. Add a socket server and a session
   registry. Remove the relay brain path (the Claude Haiku cascade) for this mode.
2. **Shim (new, small):** an MCP stdio server started by Claude Code. Declares `claude/channel` (+ permission), exposes
   `speak`, connects to the app's socket, forwards transcripts as channel events, forwards `speak` calls to the app.
   TypeScript on Bun or Node (the SDK is `@modelcontextprotocol/sdk`).
3. **Worker (exists):** `/v1/audio/speech` (Aura-2) and `/v1/audio/transcriptions` (Nova-3) work today. Streaming speech
   to text with turn detection needs a lean `/stt` WebSocket passthrough to Flux (today Flux is only reachable inside
   the `/realtime` cascade).
4. **Routing (new):** the app knows which sessions are connected (name = cwd or title). One is the target (menu choice,
   last active, or a spoken "switch to ..."). Speech goes to the target's shim only. A session that is not the target and
   wants to speak queues behind a one-speaker rule (VoiceMode's conch idea) and shows on the orb instead.

## Requirements

Functional
- F1 Speech becomes a channel event in the target session within about 1 s of the end of an utterance.
- F2 `speak(text)` plays in the Cloudflare voice, shown on the orb; Esc or "stop" cuts it off.
- F3 Speaking while the session is busy works (events queue); speaking while the voice talks is a barge-in.
- F4 Vocabulary hints (project terms, live session names) reach speech-to-text, as now.
- F5 Permission prompts are read aloud with a short description and answered by voice ("yes" or "no"); ambiguous
  speech is never treated as approval; the terminal dialog stays live.
- F6 Several sessions can connect; target switching by menu and by voice; one speaker at a time.
- F7 Works in any Claude Code session, with or without Herdr.

Non-functional
- N1 No local models or services; audio capture and gate only. Speech and voice on Cloudflare.
- N2 Latency targets: end of speech to channel event under 1 s; session reply to first audio under 1 s after `speak`.
- N3 Security: the app's socket accepts only the local user (0600) with a token; the shim is the only sender into the
  session; transcripts are untrusted text (they can be mis-heard or spoken by someone else in the room), so nothing
  spoken may approve or run anything without an explicit confirmation step; secrets are never read aloud.
- N4 Failure behaviour: if the app is not running the shim stays quiet and `speak` returns an error; if the shim
  disconnects the app marks the session gone.

## Constraints and risks

- **Research preview.** Flags and the protocol may change. Custom channels are not on Anthropic's allowlist, so each
  session needs `--dangerously-load-development-channels server:<name>` (Claude Code shows a confirmation). The flags
  work but do not appear in `--help`.
- **Account and organisation policy (unverified here).** Claude.ai Team and Enterprise block channels until an Owner
  enables `channelsEnabled`; Console API key organisations allow them by default. Needs a claude.ai login or Console key.
- **Claude must call `speak`.** Its normal text output is not spoken. `instructions` must say so, and a Stop hook that
  speaks the final reply is a fallback.
- **No remote interrupt.** A channel cannot press Esc for you; it can only send a message. "Stop talking" stops the voice;
  stopping the session's work still needs the keyboard (or a message asking it to stop).
- **MCP limits.** A blocking tool call has time limits and long calls may be backgrounded; this design avoids blocking
  calls (speech is an event, `speak` returns at once).
- **Inbound is an injection surface.** Anyone who can speak near the mic can put text in front of Claude. The
  channels docs call an ungated channel a prompt-injection vector; here the gate is "only my mic, only my app".

## Plan

- P0 Validate on this machine with Anthropic's official fakechat demo channel: confirms version, login type and policy
  allow channels. Quick, and it decides whether the rest is possible.
- P1 One session end to end: shim, app socket, speech in as events, `speak` out, instructions text. Target is the PM.
- P2 Routing across sessions, one-speaker rule, "switch to ...", stop and barge-in, `/stt` streaming endpoint.
- P3 Voice permission relay.
- P4 Package as a Claude Code plugin; make the Herdr/hc tools an optional mode rather than the core; retire the relay
  brain, Wispr and Apple experiments.

## Decisions needed

1. Accept the research-preview dependency (and the `--dangerously-load-development-channels` flag on every session)?
2. Which account/org signs in to Claude Code (this decides whether channels are enabled)?
3. Keep the current Herdr/hc agent tools as an optional mode, or retire them?
