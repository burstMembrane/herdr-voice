# herdr-voice cascade Worker

Backs the **Claude (Cloudflare)** provider. It speaks the OpenAI Realtime protocol to herdr-voice and runs a cascade
behind it: Deepgram Flux speech-to-text, Claude with tool use, Deepgram Aura-2 text-to-speech, all but Claude on
Workers AI. herdr-voice sends its instructions, tools and voice in `session.update`, so nothing is configured here.

Measured 2026-11: about 2.2 s from end of speech to first audio with `claude-haiku-5-5` (prompt cache hit).
Workers AI usage is billed in neurons (Flux 700/min, Aura-2 2,727 per 1k characters); Claude is billed by Anthropic.

## Run it

```bash
cd worker
cp .dev.vars.example .dev.vars   # fill ANTHROPIC_API_KEY, and VOICE_TOKEN (e.g. openssl rand -hex 24)
npx wrangler dev --remote --port 8799   # Workers AI needs --remote
```

Then, with the same token:

```bash
HERDR_VOICE_CF_TOKEN=<VOICE_TOKEN> herdr-voice --provider cloudflare
```

`HERDR_VOICE_CF_URL` overrides the endpoint (default `ws://127.0.0.1:8799/realtime`). Pick the voice with
`HERDR_VOICE_VOICE` or the orb's right-click **Voice** menu (Aura-2 speakers; `draco` is the British male).

## Deploy

`npx wrangler secret put ANTHROPIC_API_KEY` and `... put VOICE_TOKEN`, then `npx wrangler deploy`, and set
`HERDR_VOICE_CF_URL=wss://<your-worker>.workers.dev/realtime`.

## Known limits

Barge-in only stops the reply being generated and spoken; truncation of already-played audio is not tracked.
One Worker invocation holds one session, so a dropped connection loses the conversation (herdr-voice resends a recap).
