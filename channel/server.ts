// herdr-voice channel: lets the voice app talk to THIS Claude Code session. Claude Code starts it over stdio (see README).
// What you say arrives as <channel source="herdr-voice" session="...">text</channel>; Claude answers by calling `speak`.
// The app's socket is ~/.config/herdr-voice/app.sock. Nothing here may print to stdout: stdout is the MCP transport.
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { connect, type Socket } from 'node:net'
import { existsSync, readFileSync } from 'node:fs'
import { basename } from 'node:path'

const home = process.env.HOME ?? ''
const SOCK = process.env.HERDR_VOICE_SOCK ?? `${home}/.config/herdr-voice/app.sock`
const SESSION = process.env.HERDR_VOICE_SESSION ?? basename(process.cwd())
const styleFile = `${home}/.config/herdr-voice/prompts/channel.md`
const style = existsSync(styleFile) ? readFileSync(styleFile, 'utf8').trim() : ''

const instructions = [
  'Messages from the voice app arrive as <channel source="herdr-voice" session="...">what the user said</channel>.',
  'The user is speaking to you out loud and hears you through a text-to-speech voice. Treat each message as their words,',
  'possibly with dictation slips (map near-sounding words to project terms). Do your work as usual.',
  'To answer out loud, call the `speak` tool with one or two short, plain spoken sentences (under 40 words, no code, no file paths,',
  'no markdown, no URLs). Speak when you have the answer or a decision to ask; stay silent for routine steps. Your normal text',
  'output is NOT spoken. If a message is clearly noise or a mishearing you cannot map to anything, ignore it.',
  style,
].filter(Boolean).join('\n')

const mcp = new Server(
  { name: 'herdr-voice', version: '0.1.0' },
  { capabilities: { experimental: { 'claude/channel': {} }, tools: {} }, instructions },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{
    name: 'speak',
    description: 'Say something out loud to the user through the voice app. One or two short plain sentences.',
    inputSchema: { type: 'object', properties: { text: { type: 'string', description: 'What to say' } }, required: ['text'] },
  }],
}))

let sock: Socket | null = null
mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (req.params.name !== 'speak') throw new Error(`unknown tool: ${req.params.name}`)
  const text = String((req.params.arguments as { text?: string })?.text ?? '').trim()
  if (!text) return { content: [{ type: 'text', text: 'nothing to say' }], isError: true }
  if (!sock || sock.destroyed) return { content: [{ type: 'text', text: 'the voice app is not running' }], isError: true }
  sock.write(JSON.stringify({ type: 'speak', text }) + '\n')
  return { content: [{ type: 'text', text: 'spoken' }] }
})

// Keep trying to reach the app: it may start after the session, or restart.
function link() {
  const s = connect(SOCK)
  let buf = ''
  s.on('connect', () => { sock = s; s.write(JSON.stringify({ type: 'hello', session: SESSION }) + '\n') })
  s.on('data', (d) => {
    buf += d.toString()
    let i: number
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1)
      try {
        const m = JSON.parse(line)
        if (m.type === 'transcript' && typeof m.text === 'string') {
          void mcp.notification({ method: 'notifications/claude/channel', params: { content: m.text, meta: { session: SESSION } } })
        }
      } catch { /* ignore a malformed line */ }
    }
  })
  const retry = () => { if (sock === s) sock = null; setTimeout(link, 2000) }
  s.on('close', retry)
  s.on('error', () => { /* close follows */ })
}

await mcp.connect(new StdioServerTransport())
link()
