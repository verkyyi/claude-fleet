// viewAs.ts — 以他的视角看 (claude-fleet#3944): an admin opens a member's 我的
// read-only as /app/…?as=<principal>. The tab remembers whom it looks through
// (sessionStorage — this tab only, gone with it) and every read of the entry
// carries it as X-Fleet-View-As (an EventSource, which cannot set a header,
// as ?as=). The entry does the rest: it answers through the person's eyes,
// refuses every change (403) and writes the audit line; for anyone but an
// admin the word is ignored. Nothing asked ⇒ nothing here runs.
declare const __PROTO__: boolean;
const KEY = "fleet.console.view_as";
export const VIEW_AS_HEADER = "X-Fleet-View-As";

function read(): string {
  try {
    // the review build (an iframe's srcdoc) takes it from its scenario
    if (__PROTO__) return JSON.parse(window.name || "{}").role === "view" ? "p:linxiao" : "";
    const q = new URLSearchParams(location.search).get("as");
    if (q !== null) {
      if (q) sessionStorage.setItem(KEY, q);
      else sessionStorage.removeItem(KEY); // ?as= (empty) leaves the view
    }
    return sessionStorage.getItem(KEY) || "";
  } catch {
    return ""; // no storage, no view
  }
}

// viewAs is the principal this tab looks through; "" for the person's own page.
export const viewAs: string = typeof location === "undefined" ? "" : read();

// Every same-origin fetch carries the view — the pages' reads, the shell's,
// the conversation's — so no page has to remember it.
if (viewAs && typeof window !== "undefined" && window.fetch) {
  const orig = window.fetch.bind(window);
  window.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (new URL(url, location.href).origin !== location.origin) return orig(input, init);
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
    headers.set(VIEW_AS_HEADER, viewAs);
    return orig(input, { ...init, headers });
  };
}

// withAs(url): the view on an address that cannot carry a header (EventSource).
export const withAs = (url: string) =>
  viewAs ? `${url}${url.includes("?") ? "&" : "?"}as=${encodeURIComponent(viewAs)}` : url;

// leaveViewAs: back to the person's row on the admin side, the view forgotten.
export function leaveViewAs() {
  if (__PROTO__) return; // the review build has no admin side to go back to
  try { sessionStorage.removeItem(KEY); } catch { /* private mode */ }
  location.assign(`/admin/people/${encodeURIComponent(viewAs)}`);
}
