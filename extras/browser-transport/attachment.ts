/** Shared Terminal/Webchat transport. No cookies, node tokens or grants are
 * exposed to callers. The same-origin hub admits every attachment and keeps
 * its renewable authority alive. Adapters keep their own request lifecycle. */
export const FRAME_MAX = 32 * 1024
export const BUFFER_MAX = 256 * 1024
const SIGNAL_MAX = 32 * 1024
const SDP_MAX = 24 * 1024
const LABEL = 'fleet.v1'

/** A door a terminal's payload may go through (XX79): the hub signs its tickets. */
export type TermDoor = { id: string; url: string; probe?: string; label?: string }
type Mode = 'direct' | 'relay' | 'door'
/** A door is taken only when it answers this much faster than the hub. */
const DOOR_MARGIN_MS = 30
/** How long a door's pipe may take to bring the terminal's ready. */
const DOOR_READY_MS = 3000

export type AttachmentState = {
  state: 'connecting' | 'ready' | 'closed'
  mode?: Mode
  /** the door's label while the payload goes through it */
  door?: string
  /** this connection's echo: key → next output, median ms (after a few keys) */
  echo?: number
  target?: string
  generation?: string
  connection?: string
  pair?: string
  terminal?: string
  terminalGeneration?: string
  controllerEpoch?: number
  error?: string
  status?: number
  message?: string
  trialLeft?: string
}
export type AttachmentOptions = {
  /** Same-origin route supplied by the independently authorized service adapter. */
  url: string
  generation?: string
  previous?: string
  preferRelay?: boolean
  /** Request adapters must never establish a successor for an uncertain write. */
  reconnect?: boolean
  signal?: AbortSignal
  onState: (state: AttachmentState) => void
  onData: (data: string | ArrayBuffer) => void
}
type Signal = { t: string; sdp?: string; stun?: string[]; generation?: string;
  status?: number; message?: string; trial_left?: string; term?: string; term_gen?: string; target?: string; conn?: string; mode?: Mode; pair?: string; error?: string
  doors?: TermDoor[]; door?: string; url?: string; ticket?: string; echo_p50?: number; echo_p95?: number; echo_n?: number }
type Attempt = {
  ws: WebSocket; pc?: RTCPeerConnection; dc?: RTCDataChannel; dws?: WebSocket
  timer?: ReturnType<typeof setTimeout>; offerSent: boolean; choice?: Mode
  choiceTimer?: ReturnType<typeof setTimeout>; doorTimer?: ReturnType<typeof setTimeout>
  doors: TermDoor[]; pick?: Promise<TermDoor | undefined>
  ready: boolean; ended: boolean
}

/** The fastest of a few same-size requests: the first pays for TLS. */
async function rtt(url: string, credentials: RequestCredentials): Promise<number> {
  let best = Infinity
  for (let i = 0; i < 3; i++) {
    const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), 1500)
    const t0 = performance.now()
    try {
      const r = await fetch(url, { cache: 'no-store', credentials, signal: ctl.signal })
      await r.arrayBuffer()
      if (r.ok) best = Math.min(best, performance.now() - t0)
    } catch { /* unreachable: stays Infinity */ } finally { clearTimeout(timer) }
  }
  return best
}

/** The door to take, or none: measured against the hub, never assumed. */
export async function pickDoor(doors: TermDoor[], hubProbe: string): Promise<TermDoor | undefined> {
  if (!doors.length) return undefined
  const [hub, ...each] = await Promise.all([rtt(hubProbe, 'same-origin'), ...doors.map(d => d.probe ? rtt(d.probe, 'omit') : Promise.resolve(Infinity))])
  let best: TermDoor | undefined, at = Infinity
  each.forEach((ms, i) => { if (ms < at) { at = ms; best = doors[i] } })
  return best && at + DOOR_MARGIN_MS <= hub ? best : undefined
}

/** Key → next output, the median and 95th percentile of the last 2000. */
class EchoMeter {
  private since?: number
  private samples: number[] = []
  key() { if (this.since === undefined) this.since = performance.now() }
  output() {
    if (this.since === undefined) return
    this.samples.push(performance.now() - this.since); this.since = undefined
    if (this.samples.length > 2000) this.samples.shift()
  }
  stats() {
    if (this.samples.length < 5) return undefined
    const s = [...this.samples].sort((a, b) => a - b)
    const at = (q: number) => Math.round(s[Math.min(s.length - 1, Math.floor(q * s.length))])
    return { p50: at(0.5), p95: at(0.95), n: s.length }
  }
}

export class BrowserAttachment {
  private attempt?: Attempt
  private stopped = false
  private relayed = false
  private generation?: string
  private target?: string
  private info: AttachmentState = { state: 'connecting' }
  private echo = new EchoMeter()
  private echoTimer?: ReturnType<typeof setInterval>
  private readonly url: URL
  private readonly abort = () => this.close()

  constructor(private readonly options: AttachmentOptions) {
    this.url = new URL(options.url, location.href)
    if (this.url.origin !== location.origin || this.url.username || this.url.password || this.url.hash) {
      throw new Error('attachment signaling must be same-origin')
    }
    this.url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
    this.generation = options.generation
    options.signal?.addEventListener('abort', this.abort, { once: true })
    if (options.signal?.aborted) { this.close(); return }
    this.start(Boolean(options.preferRelay))
  }

  /** No outgoing queue: an uncertain write is never retained or replayed. */
  send(data: string | ArrayBuffer | Uint8Array): void {
    const a = this.attempt
    if (!a || !a.ready || a.ended || this.stopped) throw new Error('attachment is not ready')
    const size = typeof data === 'string' ? new TextEncoder().encode(data).byteLength : data.byteLength
    if (size > FRAME_MAX) throw new Error('attachment frame too large')
    const out = this.out(a)
    if (!out || out.bufferedAmount + size > BUFFER_MAX) throw new Error('attachment buffer full')
    if (typeof data !== 'string') this.echo.key()
    if (out instanceof WebSocket) {
      if (out.readyState !== WebSocket.OPEN) throw new Error('attachment closed')
      out.send(data as string | ArrayBuffer)
    } else {
      if (out.readyState !== 'open') throw new Error('attachment closed')
      if (typeof data === 'string') out.send(data)
      else out.send(data instanceof Uint8Array ? new Uint8Array(data).buffer : data)
    }
  }

  /** Wait only before enqueueing; never retry a send after it succeeds. */
  async write(data: string | Uint8Array): Promise<void> {
    const attempt = this.attempt
    const size = typeof data === 'string' ? new TextEncoder().encode(data).length : data.byteLength
    if (size > FRAME_MAX) throw new Error('attachment frame too large')
    const until = Date.now() + 5000
    for (;;) {
      if (!attempt || this.attempt !== attempt || !this.current(attempt) || !attempt.ready) throw new Error('attachment closed')
      const out = this.out(attempt)
      if (out && out.bufferedAmount + size <= BUFFER_MAX) { this.send(data); return }
      if (Date.now() >= until) throw new Error('attachment buffer full')
      await new Promise(resolve => setTimeout(resolve, 5))
    }
  }

  close(): void {
    if (this.stopped) return
    if (this.attempt) this.report(this.attempt)
    this.stopped = true
    this.options.signal?.removeEventListener('abort', this.abort)
    if (this.attempt) this.dispose(this.attempt)
    this.publish({ state: 'closed' })
  }

  private publish(update: Partial<AttachmentState>) {
    this.info = { ...this.info, ...update }
    this.options.onState({ ...this.info })
  }
  private out(a: Attempt) { return a.choice === 'direct' ? a.dc : a.choice === 'door' ? a.dws : a.ws }
  /** The echo numbers go to the hub's audit row: never a byte typed. */
  private report(a: Attempt) {
    const st = this.echo.stats()
    if (!st || !a.choice || a.ended || a.ws.readyState !== WebSocket.OPEN) return
    a.ws.send(JSON.stringify({ t: 'stats', echo_p50: st.p50, echo_p95: st.p95, echo_n: st.n }))
  }
  private current(a: Attempt) { return !this.stopped && !a.ended && this.attempt === a }
  private signal(a: Attempt, msg: Signal) {
    if (this.current(a) && a.ws.readyState === WebSocket.OPEN) a.ws.send(JSON.stringify(msg))
  }
  private dispose(a: Attempt) {
    a.ended = true
    a.ready = false
    clearTimeout(a.timer)
    clearTimeout(a.choiceTimer)
    clearTimeout(a.doorTimer)
    clearInterval(this.echoTimer)
    a.dws?.close()
    a.dc?.close()
    a.pc?.close()
    a.ws.close()
  }
  private end(a: Attempt, error?: string, fatal = false) {
    if (!this.current(a)) return
    const canFallback = this.options.reconnect !== false && !fatal && !this.relayed && (a.offerSent || a.choice === 'door') && Boolean(this.generation)
    this.dispose(a)
    if (canFallback) {
      this.relayed = true
      this.start(true)
    } else {
      this.stopped = true
      this.options.signal?.removeEventListener('abort', this.abort)
      this.publish({ state: 'closed', error })
    }
  }
  private start(relay: boolean) {
    const url = new URL(this.url)
    if (this.generation) url.searchParams.set('generation', this.generation)
    if (this.info.connection || this.options.previous) url.searchParams.set('previous', this.info.connection || this.options.previous!)
    const ws = new WebSocket(url)
    ws.binaryType = 'arraybuffer'
    const a: Attempt = { ws, offerSent: false, ready: false, ended: false, doors: [] }
    this.attempt = a
    this.publish({ state: 'connecting', mode: undefined, door: undefined, echo: undefined, pair: undefined, connection: undefined, error: undefined })
    // Covers a failed upgrade, ICE, target startup and a lost ready handshake.
    a.timer = setTimeout(() => this.end(a, 'attachment_timeout'), 20000)
    ws.onclose = () => this.end(a, 'connection_closed')
    ws.onerror = () => this.end(a, 'connection_failed')
    ws.onmessage = event => {
      if (!this.current(a)) return
      if (event.data instanceof ArrayBuffer) { this.data(a, event.data); return }
      if (typeof event.data !== 'string' || new TextEncoder().encode(event.data).length > SIGNAL_MAX) {
        this.end(a, 'oversized_signal', true); return
      }
      let msg: Signal
      try { msg = JSON.parse(event.data) } catch { this.end(a, 'invalid_signal', true); return }
      void this.message(a, msg, event.data, relay).catch(() => {
        if (this.current(a) && !a.offerSent && !a.choice) {
          this.signal(a, { t: 'relay' }); this.fallback(a)
        } else this.end(a, 'negotiation_failed')
      })
    }
  }
  private async message(a: Attempt, msg: Signal, raw: string, relay: boolean) {
    switch (msg.t) {
      case 'config': {
        if (!msg.generation || !msg.target || (this.generation && this.generation !== msg.generation) ||
          (this.target && this.target !== msg.target)) { this.end(a, 'interrupted', true); return }
        this.generation = msg.generation; this.target = msg.target
        this.publish({ generation: this.generation, target: this.target, trialLeft: msg.trial_left })
        // a forced relay (after a door or direct failed) takes no door
        a.doors = relay ? [] : (msg.doors ?? []).filter(d => /^wss:\/\/[^/?#@\s]+\/v1\/door\/pipe$/.test(d.url) && (!d.probe || /^https:\/\/[^/?#@\s]+\/healthz$/.test(d.probe)))
        if (a.doors.length) a.pick = pickDoor(a.doors, new URL('/healthz', location.href).href)
        if (relay || typeof RTCPeerConnection === 'undefined') {
          this.signal(a, { t: 'relay' }); this.fallback(a); return
        }
        const stun = msg.stun ?? []
        if (stun.length > 4 || stun.some(u => !/^stun:[^@/?#\s]+$/.test(u))) {
          this.end(a, 'invalid_stun', true); return
        }
        const pc = new RTCPeerConnection({ iceServers: stun.map(u => ({ urls: u })) })
        a.pc = pc
        const dc = pc.createDataChannel(LABEL, { ordered: true, protocol: LABEL })
        a.dc = dc; dc.binaryType = 'arraybuffer'
        dc.onopen = () => this.choose(a, 'direct')
        dc.onmessage = e => { if (a.choice === 'direct') this.data(a, e.data) }
        dc.onerror = dc.onclose = () => { if (a.choice === 'direct') this.end(a, 'direct_closed') }
        pc.onconnectionstatechange = () => {
          if (['failed', 'disconnected', 'closed'].includes(pc.connectionState) && a.choice === 'direct') this.end(a, 'direct_failed')
        }
        // The node receives a bounded complete SDP, not arbitrary trickle data.
        const offer = await pc.createOffer()
        if (!this.current(a) || a.choice) return
        await pc.setLocalDescription(offer)
        await new Promise<void>(resolve => {
          const done = () => { clearTimeout(timer); pc.removeEventListener('icegatheringstatechange', changed); resolve() }
          const changed = () => { if (pc.iceGatheringState === 'complete') done() }
          const timer = setTimeout(done, 2000)
          pc.addEventListener('icegatheringstatechange', changed)
          changed()
        })
        if (!this.current(a) || a.choice) return
        const sdp = pc.localDescription?.sdp
        if (!sdp || new TextEncoder().encode(sdp).length > SDP_MAX || (sdp.match(/^a=candidate:/gm)?.length ?? 0) > 32) {
          this.signal(a, { t: 'relay' }); this.fallback(a); return
        }
        a.offerSent = true
        this.signal(a, { t: 'offer', sdp })
        // Timeout only chooses; it does not send or queue any service input.
        // With a door in hand, a direct path that has not opened soon (a LAN
        // one opens in well under a second) is not waited for.
        a.choiceTimer = setTimeout(() => { if (this.current(a) && !a.choice) this.fallback(a) }, a.doors.length ? 2500 : 7000)
        return
      }
      case 'hello':
        if (msg.generation !== this.generation || msg.target !== this.target) { this.end(a, 'interrupted', true); return }
        this.publish({ connection: msg.conn }); return
      case 'answer':
        if (a.choice === 'relay') return
        if (!msg.sdp || msg.error) { this.fallback(a); return }
        if (new TextEncoder().encode(msg.sdp).length > SDP_MAX) { this.end(a, 'oversized_sdp', true); return }
        await a.pc?.setRemoteDescription({ type: 'answer', sdp: msg.sdp }); return
      case 'selecting': {
        if (msg.mode !== 'direct' && msg.mode !== 'relay' && msg.mode !== 'door') { this.end(a, 'invalid_selection', true); return }
        const door = msg.mode === 'door' ? a.doors.find(d => d.id === msg.door && d.url === msg.url) : undefined
        if (msg.mode === 'door' && (!door || !msg.ticket || a.choice !== 'door')) { this.end(a, 'invalid_selection', true); return }
        a.choice = msg.mode
        clearTimeout(a.choiceTimer)
        if (msg.mode !== 'direct') { a.dc?.close(); a.pc?.close() }
        if (door) this.joinDoor(a, door, msg.ticket!)
        this.publish({ mode: msg.mode, door: door ? door.label || door.id : undefined }); return
      }
      case 'selected':
        if (msg.mode !== a.choice) { this.end(a, 'invalid_selection', true); return }
        this.publish({ pair: msg.pair }); return
      case 'error': this.publish({ status: msg.status, message: msg.message, ...(msg.term_gen ? { terminal: msg.term, terminalGeneration: msg.term_gen } : {}) }); this.end(a, msg.error ?? 'refused', msg.error !== 'door_unavailable'); return
      default: this.data(a, raw)
    }
  }
  private choose(a: Attempt, mode: Mode, door?: TermDoor) {
    if (!this.current(a) || a.choice) return
    a.choice = mode
    if (mode !== 'direct') { a.dc?.close(); a.pc?.close() }
    this.signal(a, mode === 'door' ? { t: 'select', mode, door: door!.id } : { t: 'select', mode })
  }
  /** Not direct: the door the probe picked, else the hub. */
  private fallback(a: Attempt) {
    if (!this.current(a) || a.choice) return
    if (!a.pick) { this.choose(a, 'relay'); return }
    const late = new Promise<undefined>(resolve => setTimeout(() => resolve(undefined), 1500))
    void Promise.race([a.pick, late]).then(door => {
      if (!this.current(a) || a.choice) return
      if (door) this.choose(a, 'door', door); else this.choose(a, 'relay')
    })
  }
  /** The browser's half of the pipe; the terminal's ready must come through it soon. */
  private joinDoor(a: Attempt, door: TermDoor, ticket: string) {
    const dws = new WebSocket(`${door.url}?t=${encodeURIComponent(ticket)}`)
    dws.binaryType = 'arraybuffer'
    a.dws = dws
    a.doorTimer = setTimeout(() => { if (!a.ready) this.end(a, 'door_failed') }, DOOR_READY_MS)
    dws.onmessage = e => { if (this.current(a) && a.choice === 'door') this.data(a, e.data) }
    dws.onerror = dws.onclose = () => { if (this.current(a)) this.end(a, 'door_failed') }
  }
  private data(a: Attempt, data: string | ArrayBuffer) {
    if (!this.current(a)) return
    if (typeof data !== 'string' && !(data instanceof ArrayBuffer)) { this.end(a, 'invalid_frame', true); return }
    const n = typeof data === 'string' ? new TextEncoder().encode(data).byteLength : data.byteLength
    if (n > FRAME_MAX) { this.end(a, 'oversized_frame', true); return }
    if (!a.ready) {
      let ready = false, meta: { term?: string; gen?: string; epoch?: number } = {}
      try { if (typeof data === 'string') { meta = JSON.parse(data); ready = JSON.parse(data).t === 'ready' } } catch { /* rejected below */ }
      if (!ready || !a.choice) { this.end(a, 'data_before_ready', true); return }
      a.ready = true; clearTimeout(a.timer); clearTimeout(a.doorTimer)
      this.publish({ state: 'ready', mode: a.choice, terminal: meta.term, terminalGeneration: meta.gen, controllerEpoch: meta.epoch })
      clearInterval(this.echoTimer)
      let tick = 0
      this.echoTimer = setInterval(() => {
        if (!this.current(a)) return
        if (++tick % 3 === 0) this.report(a)
        const st = this.echo.stats()
        if (st && st.p50 !== this.info.echo) this.publish({ echo: st.p50 })
      }, 5000)
      return
    }
    if (typeof data !== 'string') this.echo.output()
    this.options.onData(data)
  }
}

export function connectAttachment(options: AttachmentOptions) { return new BrowserAttachment(options) }

/** Keep one decoder per logical stream; byte frames may split a UTF-8 scalar. */
export function utf8Stream() {
  const decoder = new TextDecoder('utf-8')
  return (bytes: ArrayBuffer | Uint8Array) => decoder.decode(bytes, { stream: true })
}
