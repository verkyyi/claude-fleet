// me.tsx — 我的 (GR5E C1): 用量 · 设备 · 设置 · 账号, four tabs at /me/<tab>,
// each the very page it was on its own before, drawn under the tabs (the strip
// as wide as the page under it). The avatar is the way in (the computer's
// menu, the phone's top bar); a tab this page does not know goes to 账号. A
// tab is a place, not a step: switching replaces the address, so 返回 leaves
// 我的 for the screen before it.
import { Suspense } from "react";
import { Navigate, useNavigate, useParams } from "react-router";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { ME_TABS } from "../routes";

export default function MePage() {
  const { tab = "" } = useParams();
  const nav = useNavigate();
  const cur = ME_TABS.find((t) => t.id === tab);
  if (!cur) return <Navigate to="/me/account" replace />;
  const Page = cur.page;
  return (
    <Tabs value={cur.id} onValueChange={(v) => nav(`/me/${v}`, { replace: true })} className="gap-0">
      <div className={cn("mx-auto w-full px-4 pt-4 md:px-6 md:pt-6", cur.wide ? "max-w-3xl" : "max-w-2xl")}>
        <TabsList className="grid w-full grid-cols-4 max-sm:group-data-[orientation=horizontal]/tabs:h-[50px] sm:inline-flex sm:w-auto" aria-label={tr("我的", "Me")}>
          {ME_TABS.map((t) => <TabsTrigger key={t.id} value={t.id} className="px-2 max-sm:h-11"><t.icon />{t.label}</TabsTrigger>)}
        </TabsList>
      </div>
      <TabsContent value={cur.id}>
        <Suspense fallback={null}><Page /></Suspense>
      </TabsContent>
    </Tabs>
  );
}
