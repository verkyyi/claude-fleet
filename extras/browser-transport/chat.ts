import { BrowserAttachment, BUFFER_MAX, type AttachmentState } from './attachment'

export class UncertainChatRequest extends Error {
  constructor() { super('连接中断，消息可能已送达。请查看恢复后的对话，再决定是否重试。') }
}

/** One independently admitted request. No HTTP retry, outgoing replay queue,
 * or successor attachment exists after this call begins. Local/old-node HTTP
 * selection belongs to the caller, before any attachment is opened.
 *
 * A chat request goes over the hub relay unless the caller asks for direct
 * (preferRelay: false): its payload is a few KB of text, and the peer-to-peer
 * attempt cost 2–11 s per request before it fell back anyway — a macOS home
 * offers more ICE candidates than the 32 an answer may carry, and no STUN is
 * configured for a browser in China to reach a home abroad (task V9DJ). */
export function chatRequest(target: string, body = '', options: {
  signal?: AbortSignal; preferRelay?: boolean; requestId?: string
  onState?: (state: AttachmentState) => void
} = {}): Promise<Response> {
  if (!['conversation', 'turn', 'stop', 'answer'].includes(target)) return Promise.reject(new Error('invalid chat route'))
  const bytes = new TextEncoder().encode(body)
  if (bytes.length > 1024 * 1024 || (target === 'conversation' && bytes.length)) return Promise.reject(new Error('chat body too large'))
  const request = options.requestId ?? crypto.randomUUID().replaceAll('-', '')
  const url = `/v1/chat/connect?target=${target}&request=${encodeURIComponent(request)}&bytes=${bytes.length}`
  return new Promise((resolve, reject) => {
    let connection: BrowserAttachment
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined
    let submitted = false, headers = false, ended = false
    let trialLeft = ''
    let continued: (() => void) | undefined
    let cancelChunk: ((error: Error) => void) | undefined
    const fail = (error: Error) => {
      if (ended) return
      ended = true
      cancelChunk?.(error)
      if (headers) controller?.error(error); else reject(error)
      connection?.close()
    }
    const stream = new ReadableStream<Uint8Array>({
      start(c) { controller = c },
      cancel() { ended = true; connection?.close() },
    }, { highWaterMark: BUFFER_MAX, size: chunk => chunk.byteLength })
    connection = new BrowserAttachment({ url, signal: options.signal,
      reconnect: false, preferRelay: options.preferRelay ?? true,
      onState(state) {
        options.onState?.(state)
        if (state.trialLeft) trialLeft = state.trialLeft
        if (state.state === 'closed' && !ended) {
          if (!submitted && state.status && state.status >= 400 && state.status <= 599) {
            ended = true
            resolve(new Response(JSON.stringify({ code: state.error, error: state.message }), { status: state.status, headers: { 'Content-Type': 'application/json' } }))
          } else fail(new UncertainChatRequest())
        }
        if (state.state !== 'ready' || submitted) return
        submitted = true
        void (async () => {
          for (let i = 0; i < bytes.length; i += 16 * 1024) {
            // One chunk in flight bounds the receiver even when its per-login
            // rate budget is shared with another tab or a long response.
            const acknowledged = new Promise<void>((resolve, reject) => {
              const timer = setTimeout(() => reject(new UncertainChatRequest()), 15000)
              continued = () => { clearTimeout(timer); continued = undefined; cancelChunk = undefined; resolve() }
              cancelChunk = error => { clearTimeout(timer); continued = undefined; cancelChunk = undefined; reject(error) }
            })
            // Install a rejection handler before awaiting the socket write.
            const sending = connection.write(bytes.slice(i, i + 16 * 1024))
            await Promise.all([sending, acknowledged])
          }
          await connection.write(JSON.stringify({ t: 'request_end' }))
        })().catch(() => fail(new UncertainChatRequest()))
      },
      onData(data) {
        if (ended) return
        if (data instanceof ArrayBuffer) {
          if (!headers || (controller?.desiredSize ?? 0) < data.byteLength) { fail(new UncertainChatRequest()); return }
          controller!.enqueue(new Uint8Array(data)); return
        }
        try {
          const frame = JSON.parse(data)
          if (frame.t === 'continue' && !headers && continued) { continued(); return }
          if (frame.t === 'headers' && !headers && Number.isInteger(frame.status) && frame.status >= 200 && frame.status <= 599) {
            const response = new Response([204, 205, 304].includes(frame.status) ? null : stream, { status: frame.status, headers: { 'Content-Type': frame.content_type || 'application/octet-stream', ...(trialLeft ? { 'X-Fleet-Trial-Left': trialLeft } : {}) } })
            headers = true
            resolve(response)
          } else if (frame.t === 'end' && headers) {
            ended = true; controller!.close()
            // Let the node observe completion before tearing down the peer.
            connection.send(JSON.stringify({ t: 'received' }))
            setTimeout(() => connection.close(), 50)
          } else fail(new UncertainChatRequest())
        } catch { fail(new UncertainChatRequest()) }
      },
    })
  })
}

/** Select old-node/local HTTP before submission; never retry after dispatch. */
export async function fetchChat(url: string, init: RequestInit = {}, hosted = true): Promise<Response> {
  if (!hosted) return fetch(url, init)
  const home = await fetch('/v1/chat/home', { signal: init.signal })
  if (!home.ok) return home
  const info = await home.json()
  if (!info.direct) return fetch(url, init)
  return chatRequest(url.slice('/v1/chat/'.length), typeof init.body === 'string' ? init.body : '', { signal: init.signal ?? undefined })
}
