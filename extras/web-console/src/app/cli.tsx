// cli.tsx — the command line, one way in (会话合一 Y01K): a session opens in
// the person's own terminal (iTerm2 recommended) with `fleet open <编号>`, a new
// one with `fleet claude` / `fleet codex`, and a computer without fleet takes
// the install line first. The new-session screen's 终端, a session's 详情 and
// its 「⋯ 更多」 all draw them from here; the web terminal is only the backup.
import { useEffect, useState, type FC } from "react";
import { Check, Copy } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useCopyToClipboard } from "@/hooks/use-copy-to-clipboard";
import { cn } from "@/lib/utils";
import { getJSON } from "@/shared/api";
import { tr } from "@/shared/i18n";

// the install line the entry hands out (/v1/fleet/connect, 设备's), else its own /install
let installRead: Promise<string> | null = null;
const fallbackInstall = () => `curl -fsSL ${location.host}/install | sh`;
export function useInstallLine(): string {
  const [line, setLine] = useState(fallbackInstall);
  useEffect(() => {
    let live = true;
    installRead ??= getJSON<{ install_command?: string; install_ready?: boolean }>("/v1/fleet/connect")
      .then((c) => (c?.install_command && c.install_ready !== false ? c.install_command : fallbackInstall()));
    void installRead.then((l) => { if (live) setLine(l); });
    return () => { live = false; };
  }, []);
  return line;
}

// write to the clipboard: the browser's own, else a hidden box (an http page, an old WebView)
export async function copyText(text: string): Promise<boolean> {
  try { await navigator.clipboard.writeText(text); return true; } catch { /* the box below */ }
  try {
    const box = document.createElement("textarea");
    box.value = text; box.setAttribute("readonly", ""); box.style.position = "fixed"; box.style.opacity = "0";
    document.body.appendChild(box); box.select();
    const ok = document.execCommand("copy");
    box.remove();
    return ok;
  } catch { return false; }
}

// 「在终端里打开」: one tap copies the line, one line on top says where it goes
export async function copyOpen(line: string) {
  if (await copyText(line)) toast(tr(`已复制 ${line} · 粘贴到 iTerm2`, `Copied ${line} · paste into iTerm2`), { duration: 3000, id: "copied-open" });
  else toast(tr(`复制不了，请手动输入：${line}`, `Couldn't copy — type it: ${line}`), { duration: 5000, id: "copied-open" });
}

// one command and its 复制
export const CopyLine: FC<{ text: string; className?: string }> = ({ text, className }) => {
  const { isCopied, copyToClipboard } = useCopyToClipboard();
  const [fell, setFell] = useState(false);
  return (
    <div className={cn("bg-muted/60 flex min-w-0 items-center gap-1 rounded-lg border ps-3 pe-1", className)} data-testid="cli-line">
      <code className="min-w-0 flex-1 overflow-x-auto py-2 font-mono text-[13px] whitespace-nowrap select-all">{text}</code>
      <Button size="sm" variant="ghost" className="h-8 shrink-0 px-2" aria-label={tr("复制", "Copy")}
        onClick={() => { if (navigator.clipboard) copyToClipboard(text); else void copyText(text).then(setFell); }}>
        {isCopied || fell ? <Check className="text-ok" /> : <Copy />}{isCopied || fell ? tr("已复制", "Copied") : tr("复制", "Copy")}
      </Button>
    </div>
  );
};
