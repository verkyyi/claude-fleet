export type Migration = { ok: boolean; migrated?: boolean; fid?: string; codex_fid?: string; why?: string; readOnly?: boolean };

// Cache completed migrations, coalesce concurrent readers, retry failures. Read
// identity metadata before any write so a read-only bookmark can still resolve.
export function legacyReader(me: () => Promise<{ read_only?: boolean; view_as?: unknown } | null>,
  read: typeof fetch, viewing: boolean) {
  let request: Promise<Migration> | null = null;
  return function migrateLegacy(): Promise<Migration> {
    if (!request) request = (async (): Promise<Migration> => {
      const who = await me();
      if (!who || who.view_as || viewing) return { ok: false, readOnly: true };
      const status = await read("/v1/chat/migration");
      const before = await status.json() as Migration & { code?: string };
      if (before.code === "no_home") return { ok: true };
      if (!status.ok) return { ok: false, why: "unavailable" };
      if (before.migrated) return { ...before, readOnly: !!who.read_only };
      if (who.read_only) return { ok: false, readOnly: true };
      const r = await read("/v1/chat/migrate", { method: "POST", headers: { "X-Fleet-Webchat": "1" } });
      if (!r.ok) return { ok: false, why: "unavailable" };
      return await r.json() as Migration;
    })().catch((): Migration => ({ ok: false, why: "unavailable" })).then((r) => {
      if (!r.ok || r.readOnly) request = null;
      return r;
    });
    return request;
  };
}
