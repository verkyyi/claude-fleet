import { useEffect, useState } from "react";
import { usePage } from "../Shell";
import { tr } from "@/shared/i18n";
import { Button } from "@/components/ui/button";

type Spread = { n?: number; median_secs: number | null; p90_secs: number | null };
type Probe = { component: string; at: number; state: string; ms: number };
type Event = { id: string; component: string; started: number; ended: number; note_zh: string; note_en: string };
type Data = {
  state: string; at: number; language: string; components: Record<string, Probe>; events: Event[];
  reply_24h: Spread; reply_7d: Spread;
  latency?: { mean_ms: number | null; max_ms: number | null; failure_rate: number | null; at: number };
  links?: { label: string; n: number; fails: number; mean_ms: number; max_ms: number; at: number }[];
  admin?: { daily: Record<string, Record<string, { reply: Spread }>>; agents: Record<string, { reply: Spread }>;
    probes: Probe[]; requests_1h_replica: number; errors_1h_replica: number; db_open_replica: number;
    db_in_use_replica: number; db_wait_count_replica: number; release: string; recent_releases: {sha: string; at: number}[] };
};
export default function HealthPage({ publicPage = false }: { publicPage?: boolean }) {
  const [data, setData] = useState<Data | null>(null);
  const [details, setDetails] = useState<Data | null>(null);
  const [signin, setSignin] = useState(false);
  const [detailError, setDetailError] = useState(false);
  const detail = publicPage ? details : data;
  const links = detail?.links || [];
  const [error, setError] = useState(false);
  const [notice, setNotice] = useState("");
  const t = (zh: string, en: string) => data ? (data.language === "en" ? en : zh) : tr(zh, en);
  usePage(t("服务健康", "Service health"));
  const read = async () => {
    try { const r = await fetch(publicPage ? "/v1/status" : "/v1/health", publicPage ? { credentials: "omit" } : { cache: "no-store" }); if (!r.ok) throw Error(); setData(await r.json()); setError(false); }
    catch { setError(true); }
  };
  const readDetails = async () => {
    try {
      const r = await fetch("/v1/health", { cache: "no-store" });
      if (r.status === 401 || r.status === 403) { setDetails(null); setSignin(true); return; }
      if (!r.ok) throw Error();
      setDetails(await r.json()); setSignin(false); setDetailError(false);
    } catch { setDetails(null); setDetailError(true); }
  };
  useEffect(() => {
    if (!publicPage || !details) return;
    const timer = setInterval(() => void readDetails(), 60000);
    return () => clearInterval(timer);
  }, [publicPage, !!details]);
  useEffect(() => {
    if (data) { document.documentElement.lang = data.language === "en" ? "en" : "zh-CN"; document.title = data.language === "en" ? "Service health" : "服务健康"; }
  }, [data?.language]);
  useEffect(() => { void read(); const timer = setInterval(() => void read(), 60000); return () => clearInterval(timer); }, []);
  const state = (s: string) => ({ ok: t("正常", "Operational"), degraded: t("降级", "Degraded"), outage: t("故障", "Outage"), failed: t("探测失败", "Probe failed"), unknown: t("数据已过期或暂无数据", "Stale or no data"), unconfigured: t("尚未接入探测", "Not monitored yet") }[s] || s);
  const names: Record<string, string> = { claudefleet: "ClaudeFleet", ccquota: "ccquota", tokenman: "tokenman.io", core: t("核心入口", "Core entry"), wechat: t("微信扫码登录", "WeChat sign-in"), workbench: t("微信服务连接", "WeChat service connection"), notify: t("运维通知", "Operations notifications"), releases: t("发布服务", "Release service") };
  const date = (v: number) => v ? new Date(v).toLocaleString(data?.language === "en" ? "en-US" : "zh-CN") : "—";
  const secs = (v: number | null) => v == null ? "—" : `${v.toFixed(1)} s`;
  const spread = (s: Spread) => <div className="mt-3 flex flex-wrap gap-x-8 gap-y-2 tabular-nums"><span>p50 <b>{secs(s.median_secs)}</b></span><span>p90 <b>{secs(s.p90_secs)}</b></span>{s.n !== undefined && <span className="text-muted-foreground">{t("样本", "Samples")} {s.n}</span>}</div>;
  const card = "rounded-2xl border bg-card p-5";
  return <main className="mx-auto w-full max-w-5xl space-y-6 p-4 pb-16 md:p-8" data-testid="health-page">
    <header><h1 className="text-3xl font-semibold">{t("服务健康", "Service health")}</h1><p className="mt-2 text-muted-foreground">{t("每分钟探测一次，让服务状态清楚可见。", "Checked every minute, so you can see how the service is doing.")}</p></header>
    {error && <p role="alert" className="rounded-xl border p-4">{t("暂时无法更新，请稍后重试。下面可能是旧数据。", "Unable to refresh. Data below may be out of date.")}</p>}
    {!data ? <p role="status">{t("正在读取…", "Loading…")}</p> : <>
      <section className={card} aria-label={t("整体状态", "Overall status")}><h2 className="text-2xl font-semibold">{error ? state("unknown") : state(data.state)}</h2><p className="mt-2 text-sm text-muted-foreground">{t("更新于", "Updated")} {date(data.at)} · {t("从服务端发起的探测，可能与你的网络体验不同。", "Server-side probes may differ from your own network experience.")}</p></section>
      <section className="grid gap-3 sm:grid-cols-2">{Object.values(data.components).map((p) => <article key={p.component} className={card}><h2 className="font-medium">{names[p.component]}</h2><p className={p.state === "ok" ? "mt-2 text-emerald-700 dark:text-emerald-400" : "mt-2 text-amber-700 dark:text-amber-400"}>{state(p.state)}</p><p className="mt-2 text-xs text-muted-foreground">{date(p.at)}{p.at > 0 ? ` · ${p.ms} ms` : ""}</p></article>)}</section>
      <section className={card}><h2 className="text-lg font-semibold">{t("新会话首次回复", "First reply in a new session")}</h2><p className="mt-1 text-sm text-muted-foreground">{t("从点击开始到网页显示第一段回答；只统计十分钟内完成且成功上报的对话。空会话、未等到回复就关闭的网页不计入。", "From pressing Start to the first reply shown on the page. Includes replies received and reported within ten minutes; empty sessions and pages closed before a reply are excluded.")}</p><div className="mt-5 grid gap-6 sm:grid-cols-2"><div><h3>{t("近 24 小时", "Last 24 hours")}</h3>{spread(data.reply_24h)}</div><div><h3>{t("近 7 天", "Last 7 days")}</h3>{spread(data.reply_7d)}</div></div></section>
      {data.latency && <section className={card}><h2 className="text-lg font-semibold">{t("整体连接延迟 · 近 24 小时", "Overall connection latency · last 24 hours")}</h2><p className="mt-2 text-sm text-muted-foreground">{t("服务端到家机器的整体往返延迟，不展示单台机器或数量。", "Overall round-trip latency from the service to homes. Individual machines and counts are not shown.")}</p><p className="mt-3">{t("平均", "Mean")} {data.latency.mean_ms == null ? "—" : `${Math.round(data.latency.mean_ms)} ms`} · {t("最高", "Maximum")} {data.latency.max_ms == null ? "—" : `${data.latency.max_ms} ms`} · {t("失败率", "Failure rate")} {data.latency.failure_rate == null ? "—" : `${(data.latency.failure_rate * 100).toFixed(1)}%`}</p><p className="mt-2 text-xs text-muted-foreground">{t("最新采样小时", "Latest sample hour")} {date(data.latency.at)}{data.at - data.latency.at > 2 * 3600000 ? ` · ${state("unknown")}` : ""}</p></section>}
      {publicPage && <section className={card}><h2 className="font-semibold">{t("登录后的额外信息", "Additional signed-in details")}</h2><p className="my-3 text-sm text-muted-foreground">{t("查看你的家连接；管理员还可查看运维明细。公开状态无需登录。", "View your home connection, plus operations details for administrators. Public status needs no sign-in.")}</p><Button onClick={() => void readDetails()}>{t("显示登录后的信息", "Show signed-in details")}</Button>{signin && <a className="ml-4 underline" href="/app/signin?next=/app/health">{t("登录查看", "Sign in to view")}</a>}{detailError && <p role="alert" className="mt-2">{t("暂时无法读取登录信息，请重试。", "Unable to load signed-in details. Please retry.")}</p>}</section>}
      {detail && <section className={card}><h2 className="text-lg font-semibold">{t("家机器连接 · 近 24 小时", "Home connection · last 24 hours")}</h2><p className="mt-1 text-sm text-muted-foreground">{t("服务端到家机器的往返延迟，按机器聚合。", "Round-trip latency from the service to your home, grouped by machine.")}</p>{links.length === 0 ? <p className="mt-3">{t("暂无连接数据", "No connection data yet")}</p> : links.map((x) => <div key={x.label} className="mt-4 space-y-1"><h3>{x.label === "home" ? t("你的家", "Your home") : x.label}</h3><p>{t("平均", "Mean")} {x.n > x.fails ? `${Math.round(x.mean_ms)} ms` : "—"} · {t("最高", "Maximum")} {x.n > x.fails ? `${x.max_ms} ms` : "—"} · {t("失败", "Failed")} {x.fails}/{x.n}</p><p className="text-xs text-muted-foreground">{t("最新采样小时", "Latest sample hour")} {date(x.at)}{data.at - x.at > 2 * 3600000 ? ` · ${state("unknown")}` : ""}</p></div>)}</section>}
      <section className={card}><h2 className="text-lg font-semibold">{t("近 7 天事件", "Incidents · last 7 days")}</h2><p className="mt-1 text-sm text-muted-foreground">{t("连续三次失败会生成事件，探测恢复后自动结束。", "Three consecutive failures open an incident; a successful probe resolves it.")}</p>{notice && <p role="status">{notice}</p>}{data.events.length === 0 && <p className="mt-4">{t("这段时间没有记录到事件。", "No incidents recorded in this period.")}</p>}{data.events.map((e) => <article key={e.id} className="mt-5 border-t pt-4"><h3 className="font-medium">{names[e.component]} · {e.ended ? t("已恢复", "Resolved") : t("处理中", "Ongoing")}</h3><p className="mt-1 text-xs text-muted-foreground">{date(e.started)} → {e.ended ? date(e.ended) : "—"}</p><p className="mt-2 whitespace-pre-wrap">{data.language === "en" ? e.note_en : e.note_zh}</p>{detail?.admin && <form className="mt-3 space-y-2" onSubmit={async (ev) => { ev.preventDefault(); const form = new FormData(ev.currentTarget); try { const r = await fetch("/v1/health", { method: "POST", headers: { "Content-Type": "application/json", "X-Fleet-Webchat": "1" }, body: JSON.stringify({ id: e.id, note_zh: form.get("zh"), note_en: form.get("en") }) }); if (!r.ok) throw Error(); setNotice(t("说明已保存。", "Explanation saved.")); await read(); } catch { setNotice(t("未保存。请只填写公开说明，不含地址或凭据。", "Not saved. Use public explanations without addresses or credentials.")); } }}><label className="block text-sm">中文<textarea name="zh" maxLength={1000} defaultValue={e.note_zh} className="mt-1 block w-full rounded border p-2" /></label><label className="block text-sm">English<textarea name="en" maxLength={1000} defaultValue={e.note_en} className="mt-1 block w-full rounded border p-2" /></label><Button type="submit">{t("保存公开说明", "Save public explanation")}</Button></form>}</article>)}</section>
      {detail?.admin && <section className={card}><h2 className="text-lg font-semibold">{t("管理数据", "Operations details")}</h2><p className="mt-3">{t("本副本近一小时请求", "Requests in the last hour on this replica")}: {detail.admin.requests_1h_replica} · 5xx: {detail.admin.errors_1h_replica}</p><p className="mt-2">{t("本副本数据库连接池：已开 / 使用中 / 累计等待", "Database pool on this replica: open / in use / cumulative waits")}: {detail.admin.db_open_replica} / {detail.admin.db_in_use_replica} / {detail.admin.db_wait_count_replica}</p><p className="mt-2 text-muted-foreground">{t("RDS CPU 与额度：尚未接入 CloudWatch。", "RDS CPU and quota: CloudWatch is not connected yet.")}</p><p className="mt-2 break-all">{t("当前发布", "Current release")}: {detail.admin.release || "—"}</p><ul className="mt-2 text-sm">{detail.admin.recent_releases.map((v) => <li key={v.sha}>{date(v.at)} · <code>{v.sha.slice(0,12)}</code></li>)}</ul><h3 className="mt-6 font-medium">{t("每日首次回复 · UTC", "Daily first replies · UTC")}</h3><div className="overflow-x-auto"><table className="mt-3 w-full text-left text-sm"><thead><tr><th>{t("日期", "Date")}</th><th>Agent</th><th>p50</th><th>p90</th><th>{t("样本", "Samples")}</th></tr></thead><tbody>{Object.entries(detail.admin.daily).sort().reverse().flatMap(([day, agents]) => Object.entries(agents).map(([agent, { reply: s }]) => <tr key={`${day}-${agent}`} className="border-t"><td className="py-3">{day}</td><td>{agent || "—"}</td><td>{secs(s.median_secs)}</td><td>{secs(s.p90_secs)}</td><td>{s.n}</td></tr>))}</tbody></table></div><details className="mt-5"><summary>{t("最近 15 分钟探测明细", "Probe details · last 15 minutes")}</summary><ul className="mt-3 space-y-2 text-sm">{detail.admin.probes.map((p) => <li key={`${p.component}-${p.at}`}>{date(p.at)} · {names[p.component]} · {state(p.state)} · {p.ms} ms</li>)}</ul></details></section>}
    </>}
  </main>;
}
