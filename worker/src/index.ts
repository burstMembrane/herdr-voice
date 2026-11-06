import { openaiAudio } from "./openai";
import { realtime } from "./realtime";

export default {
  async fetch(req: Request, env: unknown): Promise<Response> {
    let path = new URL(req.url).pathname;
    if (path === "/realtime") return realtime(req, env);
    // Clients that cannot send a bearer token to a custom base URL (VoiceMode) put it in the path: /t/<token>/v1/...
    const viaPath = path.match(/^\/t\/([^/]+)(\/v1\/.*)$/);
    if (viaPath) {
      path = viaPath[2];
      const headers = new Headers(req.headers);
      headers.set("authorization", `Bearer ${viaPath[1]}`);
      req = new Request(req, { headers });
    }
    try {
      const audio = await openaiAudio(req, env, path);
      if (audio) return audio;
    } catch (e) {
      return new Response(JSON.stringify({ error: { message: String(e).slice(0, 300) } }), { status: 500, headers: { "content-type": "application/json" } });
    }
    return new Response("herdr-voice cascade: websocket /realtime, OpenAI-style /v1/audio/*", { status: 404 });
  },
};
