import { useCallback, useEffect, useState } from "react";
import { getJSON } from "@/shared/api";
import { taskRead, type Task, type TaskRead, type TasksResponse } from "./task-state";

// One read, the existing read-only retry, and `accept` for a body the push
// channel brought (the stream's tasks topic, T769) — the same taskRead rules.
// Keep this page's last answer in memory on a failed refresh; the disk's copy
// is the session list's (list-local.ts), handed in by `seed`.
export function useTasks() {
  const [s, set] = useState<TaskRead>({ data: null, failed: false });
  const [n, setN] = useState(0);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let live = true;
    setLoading(true);
    getJSON<TasksResponse>("/v1/fleet/tasks").then((data) => {
      if (!live) return;
      set((previous) => taskRead(previous, data, new Date().toISOString()));
      setLoading(false);
    });
    return () => { live = false; };
  }, [n]);
  const accept = useCallback((body: unknown) =>
    set((previous) => taskRead(previous, body as TasksResponse, new Date().toISOString())), []);
  // what this browser kept (task T47B): drawn until the hub answers, never over it
  const seed = useCallback((data: TasksResponse) => set((previous) => (previous.data ? previous : { data, failed: false })), []);
  return { ...s, loading, reload: useCallback(() => setN((x) => x + 1), []), accept, seed };
}

// A typed code goes to the hub's one resolver (EPIC T644 C1, convention 4: a
// code, the task's ID or the old T<n>; unfinished first, then the whole
// history; never a guess): one task, the candidates when it names several (409),
// or none. The page never matches a prefix itself.
export type TaskCandidate = { id: string; short: string; task?: string; title: string; state: string };
export type TaskFind =
  | { kind: "one"; task: Task } | { kind: "many"; candidates: TaskCandidate[] }
  | { kind: "none" } | { kind: "failed" };
export async function findTask(q: string): Promise<TaskFind> {
  const ref = q.trim().replace(/^#/, "");
  if (!ref) return { kind: "none" };
  const r = await fetch(`/v1/fleet/tasks/${encodeURIComponent(ref)}`, { headers: { Accept: "application/json" } }).catch(() => null);
  if (r?.status === 401) { location.assign("/app/signin"); return { kind: "failed" }; }
  if (!r) return { kind: "failed" };
  const body = await r.json().catch(() => null);
  if (r.ok && body && typeof body.title === "string") return { kind: "one", task: body as Task };
  if (r.status === 409 && Array.isArray(body?.candidates)) return { kind: "many", candidates: body.candidates };
  return r.status === 404 ? { kind: "none" } : { kind: "failed" };
}
