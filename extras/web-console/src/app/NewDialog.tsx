// NewDialog.tsx — 新建 (moved out of 会话, GR5E C2): the person's words, an
// optional repo, the agent — one task through the write door. 会话's 新建 opens
// it (a task in a repo); the list's 新建 is the new-session screen (C3, /new).
import { useState, type FC } from "react";
import { Loader } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { sendJSON } from "@/shared/api";
import { tr } from "@/shared/i18n";
import type { Row } from "./work";

// the repos a task may land in: those the person's rows already name
export const reposOf = (rows: Row[] | null) =>
  [...new Set((rows || []).map((r) => r.task?.repo || r.live?.repo || "").filter((x) => /^[\w.-]+\/[\w.-]+$/.test(x)))].sort();

// 新建: the person's words, an optional repo, the agent — one task through the
// write door: worker_start with a coding agent, so the hub writes the record
// first. A repo makes it a task that lands its own PR; none, a session of no repo.
export const NewDialog: FC<{ open: boolean; onOpenChange: (o: boolean) => void; repos: string[]; onDone: (ok: boolean, text: string) => void }> = ({ open, onOpenChange, repos, onDone }) => {
  const [w, setW] = useState("");
  const [repo, setRepo] = useState("none");
  const [agent, setAgent] = useState("claude");
  const [busy, setBusy] = useState(false);
  const start = async () => {
    const words = w.trim();
    if (!words) return;
    setBusy(true);
    const title = words.split("\n").map((l) => l.trim()).find(Boolean)!.slice(0, 120);
    const idem = "web-" + (crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`).replace(/[^A-Za-z0-9-]/g, "");
    const args = repo === "none"
      ? { kind: "scratch", no_repo: true, body: words, coding_agent: agent, idempotency_key: idem }
      : { kind: "new", title, body: words, repo, coding_agent: agent, idempotency_key: idem };
    const r = await sendJSON<{ status?: string; result?: { error?: { message?: string } } }>("POST", "/v1/fleet/write", { tool: "worker_start", args_json: JSON.stringify(args) });
    setBusy(false);
    const why = !r.ok ? r.error || `HTTP ${r.status}` : r.data?.status === "failed" ? r.data.result?.error?.message || "failed" : "";
    if (why) { onDone(false, tr(`没能开始：${why}`, `Couldn't start it: ${why}`)); return; }
    setW("");
    onOpenChange(false);
    onDone(true, tr("已派出 —— 它带着编号出现在列表里，开好会话就开始做。", "Sent — it shows in the list with its code and starts once its session opens."));
  };
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{tr("新建", "New")}</DialogTitle>
          <DialogDescription>{tr("说一件要做的事。它会有一个编号，开一个会话去做，在这一页跟着看。", "Say what needs doing. It gets a code and a session of its own; follow it on this page.")}</DialogDescription>
        </DialogHeader>
        <div className="space-y-4">
          <Textarea value={w} onChange={(e) => setW(e.target.value)} rows={4} aria-label={tr("要做什么", "What to do")}
            placeholder={tr("比如：把 sales-w41.xlsx 做成看板，按区域分，发给团队", "e.g. Turn sales-w41.xlsx into a dashboard by region and send it to the team")} />
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1.5">
              <Label>{tr("在哪个仓库做", "Which repo")}</Label>
              <Select value={repo} onValueChange={setRepo}>
                <SelectTrigger className="w-full"><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="none">{tr("不用仓库", "No repo")}</SelectItem>
                  {repos.map((x) => <SelectItem key={x} value={x}>{x}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label>{tr("谁来做", "Who does it")}</Label>
              <ToggleGroup type="single" variant="outline" value={agent} onValueChange={(v) => v && setAgent(v)} className="w-full">
                <ToggleGroupItem value="claude" className="flex-1">Claude</ToggleGroupItem>
                <ToggleGroupItem value="codex" className="flex-1">Codex</ToggleGroupItem>
              </ToggleGroup>
            </div>
          </div>
          <p className="text-muted-foreground text-xs">
            {repo === "none" ? tr("不用仓库：开一个会话，做完回报给你。", "No repo: a session opens, and reports back when done.")
              : tr("选了仓库：在仓库里改，做完自己开 PR、门禁绿了就合并。", "With a repo: it changes the repo, opens a PR and merges it once checks pass.")}
          </p>
        </div>
        <DialogFooter><Button disabled={!w.trim() || busy} onClick={start} className="w-full sm:w-auto">
          {busy ? <Loader className="animate-spin" aria-hidden /> : null}{tr("开始", "Start")}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

