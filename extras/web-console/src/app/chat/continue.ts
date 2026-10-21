// continue.ts — 「在终端里继续」 (task R9A2): the one command that picks a web
// conversation up in the home's shell. Pure, so it is checked as it is.
//   Claude Code:  cd '<cwd>' && fleet run claude --resume <session>
//   Codex:        cd '<cwd>' && fleet run codex resume <session>
// `fleet run` goes through the home's credential proxy like any session there.
// The words are never taken from the address: the terminal reads the session id
// and the directory from the home itself (GET /v1/chat/conversation), and refuses
// an id or a directory of any other shape.
export type ContinueProvider = "claude" | "codex";
export const continueProvider = (v: string | null): ContinueProvider | null => (v === "claude" || v === "codex" ? v : null);
const ID_RE = /^[A-Za-z0-9_-]{1,80}$/;

const quote = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

export function continueCommand(provider: ContinueProvider, session: string, cwd: string): string | null {
  if (!ID_RE.test(session) || !cwd.startsWith("/") || /[\0\r\n]/.test(cwd)) return null;
  const run = provider === "claude" ? `fleet run claude --resume ${session}` : `fleet run codex resume ${session}`;
  return `cd ${quote(cwd)} && ${run}`;
}

// where the chat page sends a person to continue a side in the terminal
export const continueLink = (provider: ContinueProvider) => `/terminal?continue=${provider}`;
