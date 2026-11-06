// OpenAI-compatible speech endpoints on Workers AI, so tools that speak that API (VoiceMode, many others) can use
// Deepgram Aura-2 for text-to-speech and Deepgram Nova-3 for speech-to-text.
import { KEYTERMS, SPEAKERS } from "./realtime";

const unauthorized = () => new Response(JSON.stringify({ error: { message: "unauthorized" } }), { status: 401, headers: { "content-type": "application/json" } });
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

const FORMATS: Record<string, { encoding: string; container: string; type: string; extra?: Record<string, unknown> }> = {
  pcm: { encoding: "linear16", container: "none", type: "audio/pcm", extra: { sample_rate: 24000 } },
  wav: { encoding: "linear16", container: "wav", type: "audio/wav", extra: { sample_rate: 24000 } },
  mp3: { encoding: "mp3", container: "none", type: "audio/mpeg" },
  opus: { encoding: "opus", container: "ogg", type: "audio/ogg" },
  aac: { encoding: "aac", container: "none", type: "audio/aac" },
  flac: { encoding: "flac", container: "none", type: "audio/flac" },
};

export async function openaiAudio(req: Request, env: any, path: string): Promise<Response | null> {
  if (!path.startsWith("/v1/")) return null;
  if (req.headers.get("authorization") !== `Bearer ${env.VOICE_TOKEN}` || !env.VOICE_TOKEN) return unauthorized();

  if (path === "/v1/models") return json({ object: "list", data: ["aura-2", "nova-3"].map((id) => ({ id, object: "model", owned_by: "deepgram" })) });

  if (path === "/v1/audio/speech" && req.method === "POST") {
    const b: any = await req.json();
    const text = String(b.input ?? "").slice(0, 4000);
    if (!text) return json({ error: { message: "input is required" } }, 400);
    // Unknown voice names (OpenAI's nova, alloy, ...) fall back to the configured default.
    const voice = SPEAKERS.has(String(b.voice)) ? String(b.voice) : (env.DEFAULT_VOICE ?? "hyperion");
    const f = FORMATS[String(b.response_format ?? "mp3")] ?? FORMATS.mp3;
    const r: any = await env.AI.run("@cf/deepgram/aura-2-en", { text, speaker: voice, encoding: f.encoding, container: f.container, ...(f.extra ?? {}) }, { returnRawResponse: true });
    return new Response(r.body, { headers: { "content-type": f.type } });
  }

  if (path === "/v1/audio/transcriptions" && req.method === "POST") {
    const form = await req.formData();
    const file = form.get("file");
    if (!(file instanceof File)) return json({ error: { message: "file is required" } }, 400);
    const keyterms = String(form.get("prompt") ?? "").split(/[,\n]/).map((s) => s.trim()).filter(Boolean);
    const terms = [...new Set([...keyterms, ...KEYTERMS])].slice(0, 100); // our own vocabulary always applies
    const out: any = await env.AI.run("@cf/deepgram/nova-3", { audio: { body: file.stream(), contentType: file.type || "audio/wav" }, keyterm: terms, punctuate: true, smart_format: true });
    const text = out?.results?.channels?.[0]?.alternatives?.[0]?.transcript ?? out?.text ?? "";
    return json({ text });
  }
  return json({ error: { message: "not found" } }, 404);
}
