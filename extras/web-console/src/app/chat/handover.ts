// handover.ts — 接管 / 交回 (task VV8F, EPIC GR5E C6): a terminal session's
// conversation taken over by the web and given back, by its worker id. Only one
// side ever talks: who holds it is T2K6's record, carried on the 只读 stream's
// state (holder) — "webchat" = this page writes, the terminal rests on its end
// page; anything else = the terminal holds it and this page reads along.
//
// POST /v1/chat/takeover|giveback?worker=<id> (the hub's chat_take.go → the
// home's /api/takeover|giveback): 200 {ok, agent, session[, already]}, else
// {code, error} — terminal_busy / web_busy (wait for the turn), taking (another
// place is handing it over), not_home, old_agent / old_service.

export type How = "takeover" | "giveback";
export type HoverResult = { ok: true; agent: string; session: string } | { ok: false; code: string; error: string };

export async function handover(worker: string, how: How, f: typeof fetch = fetch): Promise<HoverResult> {
  const r = await f(`/v1/chat/${how}?worker=${encodeURIComponent(worker)}`, {
    method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: "{}",
    cache: "no-store",
  }).catch(() => null);
  const j = r ? await r.json().catch(() => ({})) : {};
  if (r?.ok) return { ok: true, agent: String(j.agent || ""), session: String(j.session || "") };
  return { ok: false, code: String(j.code || (r ? `http_${r.status}` : "offline")), error: String(j.error || "") };
}

// what the page shows: read (the terminal holds it) · wait (…and it is answering:
// 接管 waits for this turn) · held (this page writes). A handover this page just
// made is believed until the stream says the same, or for SURE_MS at most.
export type Stage = "read" | "wait" | "held";
export type Said = { holder?: string; busy?: boolean } | null;
export type Mine = { held: boolean; at: number } | null;
export const SURE_MS = 6000;

export function stageOf(said: Said, mine: Mine, now: number): Stage {
  const streamHeld = said?.holder === "webchat";
  const held = mine && mine.held !== streamHeld && now - mine.at < SURE_MS ? mine.held : streamHeld;
  if (held) return "held";
  return said?.busy ? "wait" : "read";
}
