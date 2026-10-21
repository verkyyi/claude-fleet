// TrialPoster — 生成海报: a 试用二维码 as one picture to send a friend
// (claude-fleet CHZ0). The poster is drawn in the browser (src/admin/poster.ts)
// and shown as a plain <img>, so a phone long-presses it to save or forward,
// and a computer takes the PNG with one button. 中文 / English is the poster's
// own choice, starting from the console's language.
import * as React from "react";
import { Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import type { TrialCode } from "../api";
import { lang, t } from "../i18n";
import { drawPoster, H, posterWords, themeFromPage, W, type PosterLang } from "../poster";

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((ok, no) => {
    const im = new Image();
    im.onload = () => ok(im);
    im.onerror = () => no(new Error("qr"));
    im.src = src;
  });
}

// the poster as a PNG data URL (an <img> a phone can save; a blob: URL is not
// always one in WeChat's browser)
export async function renderPoster(c: TrialCode, l: PosterLang, defaultTerms: string): Promise<string> {
  const th = themeFromPage();
  // the theme's faces, before the canvas measures with them
  await Promise.all([`800 96px ${th.display}`, `700 42px ${th.display}`, `400 31px ${th.ui}`, `500 31px ${th.ui}`, `700 38px ${th.ui}`, `700 28px ${th.mono}`]
    .map((f) => document.fonts.load(f).catch(() => [])));
  const qr = await loadImage(c.image);
  const cv = document.createElement("canvas");
  cv.width = W;
  cv.height = H;
  drawPoster(cv.getContext("2d")!, posterWords(c, l, defaultTerms), qr, th);
  return cv.toDataURL("image/png");
}

export function TrialPoster({ c, defaultTerms, trigger }: { c: TrialCode; defaultTerms: string; trigger: React.ReactNode }) {
  const [open, setOpen] = React.useState(false);
  const [pl, setPl] = React.useState<PosterLang>(lang === "zh" ? "zh" : "en");
  const [url, setUrl] = React.useState("");
  const [err, setErr] = React.useState(false);
  React.useEffect(() => {
    if (!open) return;
    let live = true;
    setUrl("");
    setErr(false);
    renderPoster(c, pl, defaultTerms).then((u) => live && setUrl(u), () => live && setErr(true));
    return () => { live = false; };
  }, [open, pl, c, defaultTerms]);
  const file = `${c.channel}-${pl === "zh" ? "海报" : "poster"}.png`;
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>{trigger}</DialogTrigger>
      <DialogContent className="max-h-[100dvh] overflow-y-auto sm:max-w-[460px]" data-testid="trial-poster">
        <DialogHeader>
          <DialogTitle className="font-display">{t("tc.p.title")}</DialogTitle>
          <DialogDescription>{t("tc.p.sub")}</DialogDescription>
        </DialogHeader>
        <ToggleGroup type="single" variant="outline" size="sm" value={pl} onValueChange={(v) => v && setPl(v as PosterLang)} className="justify-self-start">
          <ToggleGroupItem value="zh">中文</ToggleGroupItem>
          <ToggleGroupItem value="en">English</ToggleGroupItem>
        </ToggleGroup>
        <div className="mx-auto w-full max-w-[360px]">
          {url ? (
            <img src={url} alt={t("tc.p.alt", { name: c.channel })} className="aspect-[3/4] w-full rounded-lg border shadow-sm" />
          ) : err ? (
            <p className="text-sm text-destructive">{t("tc.p.err")}</p>
          ) : (
            <Skeleton className="aspect-[3/4] w-full rounded-lg" />
          )}
        </div>
        <p className="text-center text-xs text-muted-foreground">{t("tc.p.hint")}</p>
        <DialogFooter>
          <Button asChild disabled={!url}>
            <a href={url || undefined} download={file} aria-disabled={!url}>
              <Download />
              {t("tc.p.download")}
            </a>
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
