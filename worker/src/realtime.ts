// The voice's server side, behind the OpenAI-Realtime-shaped websocket herdr-voice speaks: Deepgram Flux hears you,
// Deepgram Aura-2 speaks, and Claude Haiku condenses long replies. There is no model in the conversation: a Claude Code
// session (see channel/) is the brain, and the app routes between it and this Worker.
export const KEYTERMS = ["sheetmuse", "claude", "claude code", "codex", "herdr", "worktree"];
const ONE_WORD = new Set(["yes", "yeah", "yep", "yup", "no", "nope", "okay", "ok", "sure", "stop", "thanks", "thank", "hello", "hi", "hey", "repeat", "again", "continue", "go", "done", "approve", "approved", "cancel", "wait", "please", "status", "overview", "summary", "update", "merge", "delete", "keep", "hold", "ship", "both", "neither", "first", "second", "third", "none", "all"]);
export const SPEAKERS = new Set(["amalthea", "andromeda", "apollo", "arcas", "aries", "asteria", "athena", "atlas", "aurora", "callista", "cora", "cordelia", "delia", "draco", "electra", "harmonia", "helena", "hera", "hermes", "hyperion", "iris", "janus", "juno", "jupiter", "luna", "mars", "minerva", "neptune", "odysseus", "ophelia", "orion", "orpheus", "pandora", "phoebe", "pluto", "saturn", "thalia", "theia", "vesta", "zeus"]);
const b64 = (u: Uint8Array) => { let s = ""; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const COMPACT_OVER = 320; // characters: up to about three short sentences are spoken as they are
// Turns a long reply into a short spoken update (Claude Haiku). On any failure, falls back to the first two sentences.
async function compact(text: string, env: any): Promise<string> {
  // A closing question to the listener is kept word for word; only the rest is shortened.
  const sentences = text.split(/(?<=[.!?])\s+/);
  const question = sentences.length > 1 && sentences[sentences.length - 1].endsWith("?") ? sentences[sentences.length - 1] : "";
  const body = question ? sentences.slice(0, -1).join(" ") : text;
  const fallback = sentences.slice(0, 2).join(" ").slice(0, COMPACT_OVER);
  try {
    const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST",
      headers: { "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: env.CLAUDE_MODEL ?? "claude-haiku-5-5", max_tokens: 140, thinking: { type: "disabled" },
        system: "You are the writer of the text below, telling the listener the point out loud, the way one colleague talks to another. Say what "
          + "happened or the answer first, then what it means for them, then what they need to do, if anything. Plain everyday words, short sentences, "
          + "at most 35 words. NEVER talk about the text itself: no 'this reply', 'the passage', 'the earlier message', 'I'll summarise', 'it covers', "
          + "no mention of speech or the screen. Just say the content. Use ONLY what the text says: add no advice, opinions or facts, and answer no question. "
          + "Leave out background, tool names, file names, lists and anything the listener cannot act on.",
        messages: [{ role: "user", content: body.slice(0, 6000) }] }) });
    if (!r.ok) return fallback;
    const j: any = await r.json();
    let out = (j.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join(" ").trim();
    if (j.stop_reason === "max_tokens") out = out.slice(0, Math.max(out.lastIndexOf("."), out.lastIndexOf("!")) + 1); // never end mid-word
    return out ? `${out}${question ? " " + question : ""}` : fallback;
  } catch { return fallback; }
}
const uid = (p: string) => p + crypto.randomUUID().replace(/-/g, "").slice(0, 16);

export async function realtime(req: Request, env: any): Promise<Response> {
  if (req.headers.get("upgrade") !== "websocket") return new Response("websocket only", { status: 426 });
  const auth = req.headers.get("authorization") ?? "";
  if (!env.VOICE_TOKEN || auth !== `Bearer ${env.VOICE_TOKEN}`) return new Response("unauthorized", { status: 401 });

  const pair = new WebSocketPair();
  const [client, server] = [pair[0], pair[1]];
  server.accept();
  const send = (o: unknown) => { try { server.send(JSON.stringify(o)); } catch { /* closed */ } };

  let voice = "hyperion", keyterms: string[] = [], compactOn = true;
  let gen = 0; // bumps on barge-in / cancel; stale work drops its output
  let queue: Promise<void> = Promise.resolve();

  // What was said is held for a moment and joined with whatever you say next, so a pause in the middle of a sentence
  // does not hand the session half of it.
  let held = "", flushTimer: ReturnType<typeof setTimeout> | undefined;
  const armFlush = (ms: number) => {
    clearTimeout(flushTimer);
    flushTimer = setTimeout(() => {
      const text = held.trim(); held = "";
      if (text) send({ type: "conversation.item.input_audio_transcription.completed", transcript: text });
    }, ms);
  };

  // Speech to text: Flux closes itself after a stretch without audio (the app sends speech only), so it is opened on
  // demand and reopened on the next audio; that must never end the client's session.
  let fluxP: Promise<WebSocket> | null = null, cur: WebSocket | null = null;
  const openFlux = (): Promise<WebSocket> => (fluxP ??= (async () => {
    const resp: any = await env.AI.run("@cf/deepgram/flux", { encoding: "linear16", sample_rate: "24000", eager_eot_threshold: "0.5", eot_timeout_ms: "2500", keyterm: [...new Set([...keyterms, ...KEYTERMS])].slice(0, 100) }, { websocket: true });
    const ws: WebSocket = resp.webSocket;
    ws.accept();
    ws.addEventListener("message", (m) => {
      let d: any; try { d = JSON.parse(String(m.data)); } catch { return; }
      if (d.event === "StartOfTurn") { gen++; send({ type: "input_audio_buffer.speech_started" }); if (held) armFlush(4000); }
      if (d.event === "EndOfTurn") {
        send({ type: "input_audio_buffer.speech_stopped" });
        const text = String(d.transcript ?? "").trim();
        if (!text) return;
        // A single word that is not a plain answer is noise or a mishearing: it never reaches the session.
        const words = text.toLowerCase().replace(/[^a-z' ]/g, " ").split(/\s+/).filter(Boolean);
        if (words.length === 1 && !ONE_WORD.has(words[0])) return;
        held = held ? `${held} ${text}` : text;
        armFlush(1100);
      }
    });
    const drop = () => { if (fluxP && cur === ws) fluxP = null; };
    ws.addEventListener("close", drop); ws.addEventListener("error", drop);
    cur = ws;
    return ws;
  })());

  // Text to speech: Aura, streamed, kept sample-aligned.
  async function speak(text: string, itemId: string, myGen: number) {
    if (!text.trim() || myGen !== gen) return;
    const r: any = await env.AI.run("@cf/deepgram/aura-2-en", { text, speaker: SPEAKERS.has(voice) ? voice : "hyperion", encoding: "linear16", container: "none", sample_rate: 24000 }, { returnRawResponse: true });
    const rd = r.body.getReader(); let carry: Uint8Array | null = null;
    for (;;) {
      const { done, value } = await rd.read(); if (done) break;
      if (myGen !== gen) { rd.cancel(); return; }
      let chunk: Uint8Array = value;
      if (carry) { const j = new Uint8Array(carry.length + chunk.length); j.set(carry); j.set(chunk, carry.length); chunk = j; carry = null; }
      if (chunk.length % 2) { carry = chunk.slice(chunk.length - 1); chunk = chunk.slice(0, chunk.length - 1); }
      if (chunk.length) send({ type: "response.output_audio.delta", item_id: itemId, delta: b64(chunk) });
    }
  }

  server.addEventListener("message", (m) => {
    if (typeof m.data !== "string") return;
    let d: any; try { d = JSON.parse(m.data); } catch { return; }
    switch (d.type) {
      case "session.update": {
        const s = d.session ?? {};
        voice = s.voice ?? voice;
        compactOn = s.compact !== false;
        if (Array.isArray(s.keyterms)) keyterms = s.keyterms.filter((k: unknown) => typeof k === "string" && k.trim()).map((k: string) => k.trim().slice(0, 40)).slice(0, 80);
        send({ type: "session.updated" });
        break; }
      case "config": if (typeof d.compact === "boolean") compactOn = d.compact; break;
      case "input_audio_buffer.append": { const audio = unb64(d.audio); openFlux().then((f) => f.send(audio)).catch((e) => send({ type: "error", error: { message: "stt: " + String(e).slice(0, 200) } })); break; }
      case "input_audio_buffer.clear": gen++; break;
      case "response.cancel": gen++; break;
      case "speak": { // say this text; a long text is condensed to a short spoken update first
        const text = String(d.text ?? "").slice(0, 8000).trim();
        if (!text) break;
        const myGen = ++gen, itemId = uid("item_");
        send({ type: "response.created" });
        queue = queue.then(async () => {
          const spoken = compactOn && text.length > COMPACT_OVER ? await compact(text, env) : text;
          if (myGen === gen) await speak(spoken, itemId, myGen);
          send({ type: "response.output_audio_transcript.done", transcript: spoken }); send({ type: "response.done" });
        }).catch(() => {});
        break; }
      default: break; // everything else in the Realtime protocol is not used
    }
  });
  const close = () => { gen++; clearTimeout(flushTimer); try { cur?.close(); } catch { /* */ } try { server.close(); } catch { /* */ } };
  server.addEventListener("close", close); server.addEventListener("error", close);

  send({ type: "session.created" });
  return new Response(null, { status: 101, webSocket: client });
}
