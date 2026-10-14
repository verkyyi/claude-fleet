// Search — ⌘K on any admin page (claude-fleet#3942, EPIC #3923 R1): one box
// over people, machines, subscriptions and the recent releases, Enter opens
// the thing's own page. No read of its own: it asks the reads the pages
// already make, each on its own (one that does not answer leaves its group
// out, never the box), afresh at every open.
import * as React from "react";
import { CreditCard, Rocket, Search as SearchIcon, Server, User } from "lucide-react";
import { useNavigate } from "react-router";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { api, type ReleaseStats, type UsersList } from "./api";
import { t, type MsgKey } from "./i18n";
import type { NodesSnapshot } from "./machines/model";
import { NAV } from "./nav";
import { subscriptions, type Account, type AccountLimits, type PoolCredential } from "./pool";

type Hit = { to: string; label: string; sub?: string; words: string };
type Found = { people: Hit[]; machines: Hit[]; subs: Hit[]; releases: Hit[] };

const NONE: Found = { people: [], machines: [], subs: [], releases: [] };
const at = (base: string, id: string) => `${base}/${encodeURIComponent(id)}`;

async function readAll(): Promise<Found> {
  const val = <T,>(r: PromiseSettledResult<T>): T | null => (r.status === "fulfilled" ? r.value : null);
  const [us, nodes, lim, acc, cr, rel] = await Promise.allSettled([
    api<UsersList>("/v1/fleet/users"),
    api<NodesSnapshot>("/v1/nodes"),
    api<{ per_account?: AccountLimits[] }>("/v1/limits?account=all"),
    api<Account[]>("/v1/accounts"),
    api<{ credentials?: PoolCredential[]; paused?: string[] }>("/v1/fleet/credentials"),
    api<ReleaseStats>("/v1/fleet/release/stats?days=7"),
  ]);
  const people = (val(us)?.users || []).map((u) => {
    const id = u.principal || `gh:${u.github_id}`;
    return { to: at("/people", id), label: u.login, sub: id, words: [id, u.machine_login, ...u.logins.map((l) => l.login)].join(" ") };
  });
  const machines = (val(nodes)?.machines || []).map((m) => ({
    to: at("/machines", m.hostname),
    label: m.alias || m.hostname,
    sub: m.alias ? m.hostname : undefined,
    words: [m.hostname, m.alias].join(" "),
  }));
  const subs =
    val(lim) || val(cr)
      ? subscriptions({ limits: val(lim), accounts: val(acc), creds: val(cr) }).map((s) => ({
          to: at("/pool", s.id),
          label: s.label,
          sub: s.plan || undefined,
          words: [s.label, s.id, s.plan, s.cred?.account].join(" "),
        }))
      : [];
  const releases = (val(rel)?.runs || []).map((r) => {
    const subject = r.merges?.[0]?.subject || "";
    return { to: at("/release", r.run_id), label: r.sha.slice(0, 7), sub: subject, words: [r.sha, r.run_id, ...(r.merges || []).map((m) => m.subject || "")].join(" ") };
  });
  return { people, machines, subs, releases };
}

// rank: a name is a substring, never a fuzzy guess — "mini" is the machine
// called mac-mini, not every person whose letters happen to spell it. The
// name's start first, then the name, then anything else the thing is known by.
function rank(_value: string, search: string, keywords?: string[]): number {
  const q = search.trim().toLowerCase();
  if (!q) return 1;
  const [label = "", ...rest] = (keywords || []).map((k) => k.toLowerCase());
  if (label.startsWith(q)) return 1;
  if (label.includes(q)) return 0.8;
  return rest.some((k) => k.includes(q)) ? 0.4 : 0;
}

// useSearchKey opens the box on ⌘K / Ctrl+K anywhere on the page.
function useSearchKey(open: () => void) {
  React.useEffect(() => {
    const on = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "k") {
        e.preventDefault();
        open();
      }
    };
    window.addEventListener("keydown", on);
    return () => window.removeEventListener("keydown", on);
  }, [open]);
}

const isMac = typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

const OpenSearch = React.createContext<() => void>(() => {});

// SearchButton is the box's visible door (a phone has no ⌘K).
export function SearchButton({ className = "" }: { className?: string }) {
  const show = React.useContext(OpenSearch);
  return (
    <button
      type="button"
      onClick={show}
      className={`flex w-full items-center gap-2 rounded-md border border-sidebar-border bg-background px-2.5 py-1.5 text-left text-sm text-muted-foreground hover:bg-sidebar-accent ${className}`}
    >
      <SearchIcon className="size-4 shrink-0" />
      <span className="flex-1 truncate">{t("search.title")}</span>
      <kbd className="hidden rounded border px-1.5 font-mono text-[11px] md:inline">{isMac ? "⌘K" : "Ctrl K"}</kbd>
    </button>
  );
}

// Search owns the one box and the key, around the shell; every SearchButton
// inside it opens the same box.
export function Search({ children }: { children: React.ReactNode }) {
  const nav = useNavigate();
  const [open, setOpen] = React.useState(false);
  const [found, setFound] = React.useState<Found | null>(null);
  const show = React.useCallback(() => setOpen(true), []);
  useSearchKey(show);

  React.useEffect(() => {
    if (!open) return;
    let live = true;
    readAll().then(
      (f) => live && setFound(f),
      () => live && setFound(NONE),
    );
    return () => {
      live = false;
    };
  }, [open]);

  const go = (to: string) => {
    setOpen(false);
    nav(to);
  };
  const pages = NAV.flatMap((g) => g.items).filter((it) => it.to);
  const groups: [MsgKey, Hit[], typeof User][] = found
    ? [
        ["search.g.people", found.people, User],
        ["search.g.machines", found.machines, Server],
        ["search.g.subs", found.subs, CreditCard],
        ["search.g.releases", found.releases, Rocket],
      ]
    : [];

  return (
    <OpenSearch.Provider value={show}>
      {children}
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="overflow-hidden p-0" showCloseButton={false}>
          <DialogTitle className="sr-only">{t("search.title")}</DialogTitle>
          <DialogDescription className="sr-only">{t("search.hint")}</DialogDescription>
          <Command filter={rank} className="[&_[cmdk-group-heading]]:px-2 [&_[cmdk-group-heading]]:font-medium [&_[cmdk-group-heading]]:text-muted-foreground [&_[cmdk-group]]:px-2 [&_[cmdk-item]]:px-2 [&_[cmdk-item]]:py-2.5">
            <CommandInput placeholder={t("search.placeholder")} />
            <CommandList>
              <CommandEmpty>{t("search.empty")}</CommandEmpty>
              {!found && <div className="px-4 py-2 text-xs text-muted-foreground">{t("search.loading")}</div>}
              {groups.map(([key, hits, Icon]) =>
                hits.length ? (
                  <CommandGroup key={key} heading={t(key)}>
                    {hits.map((h) => (
                      <CommandItem key={h.to} value={h.to} keywords={[h.label, h.words]} onSelect={() => go(h.to)}>
                        <Icon />
                        <span className="truncate font-medium">{h.label}</span>
                        {h.sub && <span className="ml-auto truncate pl-2 text-xs text-muted-foreground">{h.sub}</span>}
                      </CommandItem>
                    ))}
                  </CommandGroup>
                ) : null,
              )}
              <CommandGroup heading={t("search.g.pages")}>
                {pages.map((it) => {
                  const Icon = it.icon;
                  return (
                    <CommandItem key={it.key} value={`page:${it.to}`} keywords={[t(it.key), it.to!]} onSelect={() => go(it.to!)}>
                      <Icon />
                      <span>{t(it.key)}</span>
                    </CommandItem>
                  );
                })}
              </CommandGroup>
            </CommandList>
          </Command>
        </DialogContent>
      </Dialog>
    </OpenSearch.Provider>
  );
}
