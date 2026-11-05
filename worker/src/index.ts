import { realtime } from "./realtime";

export default {
  async fetch(req: Request, env: unknown): Promise<Response> {
    if (new URL(req.url).pathname === "/realtime") return realtime(req, env);
    return new Response("herdr-voice cascade: connect a websocket to /realtime", { status: 404 });
  },
};
