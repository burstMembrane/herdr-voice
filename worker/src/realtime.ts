// Cascade behind the OpenAI Realtime protocol: Flux (STT) -> Claude (brain, tools) -> Aura (TTS).
// herdr-voice's OpenAIRealtimeWire talks to this as if it were a realtime model.
export const KEYTERMS = ["pane", "panes", "PM", "product manager", "sheetmuse", "claude", "codex", "herdr", "worktree", "workspace", "pane", "forge"];
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
  const model = env.CLAUDE_MODEL ?? "claude-haiku-5-5";

  const pair = new WebSocketPair();
  const [client, server] = [pair[0], pair[1]];
  server.accept();
  const send = (o: unknown) => { try { server.send(JSON.stringify(o)); } catch { /* closed */ } };

  let instructions = "", tools: any[] = [], voice = "luna", keyterms: string[] = [], silentToolText = false, brainNone = false, compactOn = true;
  let messages: any[] = [];
  let pendingUser: any[] = []; // content blocks waiting for the next turn (tool results, agent reports)
  let gen = 0; // bumps on barge-in / cancel; stale work drops its output
  let queue: Promise<void> = Promise.resolve();

  let held = "", flushTimer: ReturnType<typeof setTimeout> | undefined;
  const armFlush = (ms: number) => {
    clearTimeout(flushTimer);
    flushTimer = setTimeout(() => {
      const text = held.trim(); held = "";
      if (text) send({ type: "conversation.item.input_audio_transcription.completed", transcript: text });
    }, ms);
  };

  // ---- STT: Flux over the AI binding's websocket ----
  // Flux closes itself after a stretch without audio (herdr-voice sends speech only), so it is opened on demand
  // and reopened on the next audio; that must never end the client's session.
  let fluxP: Promise<WebSocket> | null = null;
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
        // A single word that is not a plain answer is noise or a mishearing: do not let it start a turn.
        const words = text.toLowerCase().replace(/[^a-z' ]/g, " ").split(/\s+/).filter(Boolean);
        if ((silentToolText || brainNone) && words.length === 1 && !ONE_WORD.has(words[0])) { if (!brainNone) send({ type: "conversation.item.input_audio_transcription.completed", transcript: text }); return; }
        // Brain-less mode: hold what was said for a moment and join it with whatever you say next, so a pause in the
        // middle of a sentence does not hand the session half of it. (A lone noise word was filtered just above.)
        if (brainNone) { held = held ? `${held} ${text}` : text; armFlush(1100); return; }
        send({ type: "conversation.item.input_audio_transcription.completed", transcript: text });
        if (brainNone) return;
        pendingUser.push({ type: "text", text });
        enqueueTurn();
      }
    });
    const drop = () => { if (fluxP && cur === ws) fluxP = null; };
    ws.addEventListener("close", drop); ws.addEventListener("error", drop);
    cur = ws;
    return ws;
  })());
  let cur: WebSocket | null = null;

  // ---- TTS: Aura, streamed, kept sample-aligned ----
  async function speak(text: string, itemId: string, myGen: number) {
    if (!text.trim() || myGen !== gen) return;
    const r: any = await env.AI.run("@cf/deepgram/aura-2-en", { text, speaker: SPEAKERS.has(voice) ? voice : "luna", encoding: "linear16", container: "none", sample_rate: 24000 }, { returnRawResponse: true });
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

  // ---- Brain: Claude streaming with tool use ----
  function enqueueTurn() { queue = queue.then(() => turn().catch((e) => send({ type: "error", error: { message: String(e).slice(0, 300) } }))); }

  async function turn() {
    if (!pendingUser.length) return;
    // every tool_use in history needs a result in the next user message
    const last = messages[messages.length - 1];
    const owed = last?.role === "assistant" ? last.content.filter((b: any) => b.type === "tool_use").map((b: any) => b.id) : [];
    const have = new Set(pendingUser.filter((b) => b.type === "tool_result").map((b) => b.tool_use_id));
    const owedSet = new Set<string>(owed);
    const results = pendingUser.filter((b) => b.type === "tool_result" && owedSet.has(b.tool_use_id));
    // A tool result that arrives after its call was already answered (Liam spoke while it ran) is handed over as plain text.
    const late = pendingUser.filter((b) => b.type === "tool_result" && !owedSet.has(b.tool_use_id)).map((b) => ({ type: "text", text: String(b.content) }));
    const rest = [...pendingUser.filter((b) => b.type !== "tool_result"), ...late];
    for (const id of owed) if (!have.has(id)) results.push({ type: "tool_result", tool_use_id: id, content: "still waiting for the reply; say nothing about it yet" });
    messages.push({ role: "user", content: [...results, ...rest] });
    pendingUser = [];

    const answering = rest.some((b) => b.type === "text" && String(b.text).includes("your own written reply is ready"));
    const proactive = rest.some((b) => b.type === "text" && String(b.text).includes("finished a turn on its own"));
    const myGen = ++gen;
    const itemId = uid("item_");
    send({ type: "response.created" });
    const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST",
      headers: { "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model, max_tokens: 400, stream: true, thinking: { type: "disabled" },
        system: [{ type: "text", text: instructions, cache_control: { type: "ephemeral" } }],
        tools: tools.map((t, i) => (i === tools.length - 1 ? { ...t, cache_control: { type: "ephemeral" } } : t)), messages }) });
    if (!r.ok || !r.body) { send({ type: "error", error: { message: `claude ${r.status}: ${(await r.text()).slice(0, 200)}` } }); send({ type: "response.done" }); messages.pop(); return; }

    const rd = r.body.getReader(), dec = new TextDecoder();
    let buf = "", full = "", sentence = "", cur: any = null; const blocks: any[] = [];
    let released = !silentToolText, sawTool = false;
    let speakChain: Promise<void> = Promise.resolve();
    const flushSentence = (force: boolean) => {
      const m = sentence.match(/^([\s\S]*?[.!?])(\s+|$)/);
      if (m && (force || m[2] !== "" || sentence.endsWith("\n"))) { const s = m[1]; sentence = sentence.slice(m[0].length); speakChain = speakChain.then(() => speak(s, itemId, myGen)); flushSentence(force); }
      else if (force && sentence.trim()) { const s = sentence; sentence = ""; speakChain = speakChain.then(() => speak(s, itemId, myGen)); }
    };
    for (;;) {
      const { done, value } = await rd.read(); if (done) break;
      if (myGen !== gen) { rd.cancel(); break; }
      buf += dec.decode(value, { stream: true }); let i;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        const ev = buf.slice(0, i); buf = buf.slice(i + 2);
        const line = ev.split("\n").find((l) => l.startsWith("data: ")); if (!line) continue;
        const d = JSON.parse(line.slice(6));
        if (d.type === "content_block_start") { cur = { ...d.content_block, _json: "" }; blocks.push(cur); if (cur.type === "tool_use") { sawTool = true; if (!released) { sentence = ""; full = ""; } } }
        else if (d.type === "content_block_delta") {
          if (d.delta.type === "text_delta") {
            cur.text = (cur.text ?? "") + d.delta.text; full += d.delta.text; sentence += d.delta.text;
            // silent_tool_text: text said before a tool call is held back (and dropped if a tool call follows); a long text is a real answer
            if (silentToolText && !released && !sawTool && full.length >= 140) released = true;
            if (!silentToolText || released) { send({ type: "response.output_audio_transcript.delta", delta: d.delta.text }); flushSentence(false); }
          }
          else if (d.delta.type === "input_json_delta") cur._json += d.delta.partial_json;
        } else if (d.type === "content_block_stop" && cur?.type === "tool_use") {
          cur.input = cur._json ? JSON.parse(cur._json) : {};
          send({ type: "response.function_call_arguments.done", call_id: cur.id, name: cur.name, arguments: JSON.stringify(cur.input) });
        } else if (d.type === "error") send({ type: "error", error: { message: d.error?.message ?? "claude stream error" } });
      }
    }
    const skip = silentToolText && !sawTool && !answering && full.trim().replace(/[^A-Za-z]/g, "").toUpperCase() === "SKIP"; // proactive update that does not matter
    if (skip) { sentence = ""; full = ""; released = false; }
    if (!released && !sawTool && !skip) { released = true; send({ type: "response.output_audio_transcript.delta", delta: full }); }
    if (myGen === gen && !skip && (released || !sawTool)) flushSentence(true);
    await speakChain;
    const content = blocks.filter((b) => b.type === "text" ? b.text : b.type === "tool_use").map((b) => b.type === "text" ? { type: "text", text: b.text } : { type: "tool_use", id: b.id, name: b.name, input: b.input ?? {} });
    if (content.length) messages.push({ role: "assistant", content }); else messages.pop(); // nothing came back: forget the user turn too
    if (full.trim()) send({ type: "response.output_audio_transcript.done", transcript: full.trim() });
    send({ type: "response.done" });
  }

  // ---- Client messages (OpenAI Realtime subset herdr-voice sends) ----
  server.addEventListener("message", (m) => {
    if (typeof m.data !== "string") return;
    let d: any; try { d = JSON.parse(m.data); } catch { return; }
    switch (d.type) {
      case "session.update": {
        const s = d.session ?? {};
        instructions = s.instructions ?? instructions; voice = s.voice ?? voice;
        silentToolText = s.silent_tool_text === true;
        compactOn = s.compact !== false;
        brainNone = s.brain === "none";   // speech in / speech out only: a Claude Code session is the brain (see channel/)
        if (Array.isArray(s.keyterms)) keyterms = s.keyterms.filter((k: unknown) => typeof k === "string" && k.trim()).map((k: string) => k.trim().slice(0, 40)).slice(0, 80);
        tools = (s.tools ?? []).filter((t: any) => t.type === "function").map((t: any) => ({ name: t.name, description: t.description, input_schema: t.parameters }));
        send({ type: "session.updated" });
        break; }
      case "input_audio_buffer.append": { const audio = unb64(d.audio); openFlux().then((f) => f.send(audio)).catch((e) => send({ type: "error", error: { message: "stt: " + String(e).slice(0, 200) } })); break; }
      case "input_audio_buffer.clear": gen++; break;
      case "conversation.item.create": {
        const it = d.item ?? {};
        if (it.type === "function_call_output") pendingUser.push({ type: "tool_result", tool_use_id: it.call_id, content: String(it.output ?? "") });
        else if (it.type === "message") pendingUser.push({ type: "text", text: (it.content ?? []).map((c: any) => c.text ?? "").join(" ") });
        break; }
      case "response.create": if (!brainNone) enqueueTurn(); break;
      case "config": if (typeof d.compact === "boolean") compactOn = d.compact; break;
      case "speak": { // say this text in the voice (brain-less mode); a long text is condensed to a short spoken update first
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
      case "response.cancel": gen++; break;
      default: break; // conversation.item.truncate etc.: nothing to do
    }
  });
  const close = () => { gen++; try { cur?.close(); } catch { /* */ } try { server.close(); } catch { /* */ } };
  server.addEventListener("close", close); server.addEventListener("error", close);

  send({ type: "session.created" });
  return new Response(null, { status: 101, webSocket: client });
}
