// The browser terminal's recovery rules (RMVE), kept free of the DOM so a
// plain node test reads them: how long to wait, and what an «ended» means.

/** The wait before attempt n+1 (RMVE): never given up on, full jitter, capped at 30 s (including service restarts). */
export function retryDelay(failures: number, _error?: string, rand = Math.random()): number {
  return Math.round(rand * Math.min(30000, 1000 * 2 ** Math.min(failures, 5)));
}
/** The wait before the door is tried again after it failed: 30 s doubling to 5 min. */
export function doorRetryDelay(fails: number): number { return Math.min(300000, 30000 * 2 ** Math.max(0, fails - 1)); }

/** What to do with an «ended» (RMVE). First, always, a plain reconnect: the
 * session last looked at ended (the node goes home), or a session's process
 * was replaced (the node says interrupted: connect the current one). Still
 * ended — a personal terminal: ONE renew of that generation (the shell or its
 * tmux really went), then stop; a session's terminal: leave for your own. */
export function endedStep(worker: string | null, gen: string, retried: string | undefined, renewed: Set<string>): "reconnect" | "renew" | "stop" | "leave" {
  if (worker !== null) return gen && retried !== gen ? "reconnect" : "leave";
  if (!gen) return "stop";
  if (retried !== gen) return "reconnect";
  if (!renewed.has(gen)) return "renew";
  return "stop";
}
