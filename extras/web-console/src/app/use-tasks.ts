import { useEffect, useState } from "react";
import { getJSON } from "@/shared/api";
import { taskRead, type TaskRead, type TasksResponse } from "./task-state";

// One demand-driven read, and the existing read-only retry. Keep this page's
// last answer in memory on a failed refresh; no disk cache, timer or new start.
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
  return { ...s, loading, reload: () => setN((x) => x + 1) };
}
