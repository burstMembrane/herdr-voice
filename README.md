# herdr-voice (channel fork)

A voice front end for [Claude Code](https://code.claude.com) sessions: talk to a session, hear it answer.

This fork keeps the front end of [brogrammerMW/herdr-voice](https://github.com/brogrammerMW/herdr-voice) (the orb, microphone
gate with echo cancellation, playback, hotkeys, reconnecting) and routes it to Claude Code through a
[channel](https://code.claude.com/docs/en/channels). There is no AI model in the middle: your speech becomes a channel
event in the session, and the session's final reply is spoken. See `docs/scope-claude-code-voice-frontend.md`.

```
mic -> app (gate, orb) -> Worker (Deepgram Flux speech to text) -> app --socket--> channel shim --> Claude Code session
speakers <- app <- Worker (Aura-2 voice; long replies condensed by Claude Haiku) <- app <-socket-- stop hook / speak tool
```

## Parts

- `Sources/` the macOS app (`herdr-voice`): orb, mic gate, playback, session routing (`ChannelHub`), menu.
- `channel/` the Claude Code side: `server.ts` (MCP channel shim, one per session) and `speak-reply.sh` (Stop hook that
  speaks a voice turn's final reply).
- `worker/` the Cloudflare Worker: speech to text, text to speech, condensing long replies. Needs `ANTHROPIC_API_KEY` and
  `VOICE_TOKEN` secrets (see `worker/README.md`).

## Run it

1. Deploy the Worker (`worker/README.md`) and store its token: Keychain service `HERDR_VOICE_CF_TOKEN`.
2. `swift build -c release`, then `HERDR_VOICE_MODE=channel HERDR_VOICE_CF_URL=wss://<worker>/realtime .build/release/herdr-voice --here`.
3. In the project of the session that should talk, add `channel/server.ts` as an MCP server in `.mcp.json`
   (`bun /path/to/channel/server.ts`), register `speak-reply.sh` as a Stop hook, and start Claude Code with
   `--dangerously-load-development-channels server:herdr-voice` (channels are a research preview).
4. Right-click the orb: pick the session you are talking to, switch summarising of long replies, pick the voice.

Mic input level matters: if the orb does not react to your voice, raise the input gain.
