# herdr-voice Worker

The voice's server side, on Cloudflare Workers AI. The app connects to `/realtime` (an OpenAI-Realtime-shaped websocket):

- **Hears you:** mic audio goes to Deepgram Flux (turn detection, your vocabulary as keyterms). A pause inside a sentence is
  merged (1.1 s window) and a lone noise word is dropped, so the session gets whole sentences.
- **Speaks:** `{"type":"speak","text":...}` is spoken with Deepgram Aura-2. A reply over about 320 characters is first
  condensed by Claude Haiku into a short plain-spoken update (a closing question is repeated word for word). The app can
  switch condensing off (`{"type":"config","compact":false}`).
- There is no AI model in the conversation: a Claude Code session is the brain (see `../channel/`).
- `/v1/audio/speech` and `/v1/audio/transcriptions` are OpenAI-compatible speech endpoints (Aura-2, Nova-3) for tools such as VoiceMode.

## Run it

```bash
cd worker
cp .dev.vars.example .dev.vars   # fill ANTHROPIC_API_KEY (condensing) and VOICE_TOKEN (e.g. openssl rand -hex 24)
npx wrangler dev --remote --port 8799   # Workers AI needs --remote
```

Deploy with `npx wrangler secret put ANTHROPIC_API_KEY`, `... put VOICE_TOKEN`, then `npx wrangler deploy`. Set
`HERDR_VOICE_CF_URL=wss://<your-worker>/realtime` for the app and store the token with `herdr-voice setup`.

A deploy does not change a connection that is already open: restart the app to pick up a new Worker version.

Cost: Workers AI bills in neurons (Flux 700 per minute of speech, Aura-2 about 2,700 per 1,000 characters); condensing is a
small Claude call per long reply.
