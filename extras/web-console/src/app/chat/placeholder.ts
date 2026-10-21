// placeholder.ts — the composer's empty-box words (T841): every case in both
// languages, the plain one too — an English page once still said 「说点什么…」.
import { tr } from "../../shared/i18n.ts"; // .ts: the test runs this file as it is

export const SAY_SOMETHING = () => tr("说点什么…", "Say something…");

export function composerPlaceholder(owner: { busy?: boolean } | null | undefined, budget: unknown): string {
  if (owner) return owner.busy ? tr("终端里正在回答，这里只读", "The terminal is answering; read-only here") : tr("点「在这里继续」接过来再说", "Tap “Continue here” to take it over");
  if (budget) return tr("额度恢复后可以继续", "You can go on once the limit frees up");
  return SAY_SOMETHING();
}
