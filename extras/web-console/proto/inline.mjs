// inline.mjs — fold the review build (dist-proto, `vite build --mode proto`)
// into ONE html file for doc-preview (EPIC #3923 rule 14): the app's script,
// styles, fonts and icon inlined, then framed twice — dark and light — under a
// bar that picks the page, who is looking, the state and the width. Writes
// proto/out/prototype.html. Never packed into the hub.
import fs from "node:fs";
import path from "node:path";

const dir = path.resolve(import.meta.dirname, "../dist-proto");
const out = path.resolve(import.meta.dirname, "out");
const MIME = { ".woff2": "font/woff2", ".svg": "image/svg+xml", ".png": "image/png" };
const dataURL = (f) => `data:${MIME[path.extname(f)]};base64,${fs.readFileSync(path.join(dir, f)).toString("base64")}`;

let html = fs.readFileSync(path.join(dir, "index.html"), "utf8");
html = html.replace(/<link rel="stylesheet"[^>]*href="\.\/([^"]+)"[^>]*>/g, (_, f) => {
  const css = fs.readFileSync(path.join(dir, f), "utf8").replace(/url\(\.\/([^)]+)\)/g, (_, a) => `url(${dataURL(path.join("assets", a))})`);
  return `<style>${css}</style>`;
});
html = html.replace(/<script type="module" crossorigin src="\.\/([^"]+)"><\/script>/g, (_, f) =>
  `<script type="module">${fs.readFileSync(path.join(dir, f), "utf8").replace(/<\/script/g, "<\\/script")}</script>`);
html = html.replace(/href="\.\/(assets\/[^"]+\.svg)"/g, (_, f) => `href="${dataURL(f)}"`);
if (/(src|href)="\.\//.test(html)) throw new Error("inline.mjs: an asset was left behind");

const page = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>原型 · /app「我的」一侧（EPIC #3923）</title>
<style>
  body{margin:0;background:#11101c;color:#e9e4f0;font:14px/1.5 system-ui,"PingFang SC",sans-serif}
  header{padding:16px 20px 8px}
  h1{font-size:18px;margin:0 0 4px} p{margin:0;color:#a59fb5;font-size:13px}
  .bar{display:flex;flex-wrap:wrap;gap:10px 18px;padding:10px 20px;align-items:center}
  .grp{display:flex;gap:6px;align-items:center} .grp span{color:#a59fb5;font-size:12px;margin-right:2px}
  button{background:#232136;color:#e9e4f0;border:1px solid #3a3752;border-radius:8px;padding:5px 10px;font:inherit;font-size:13px;cursor:pointer}
  button[aria-pressed=true]{background:#d9765a;border-color:#d9765a;color:#19182a;font-weight:600}
  .frames{display:flex;flex-wrap:wrap;gap:24px;padding:12px 20px 40px;justify-content:center}
  figure{margin:0} figcaption{color:#a59fb5;font-size:12px;margin:0 0 6px}
  iframe{border:1px solid #3a3752;border-radius:18px;background:#fff;display:block}
</style></head><body>
<header><h1>/app ·「我的」一侧 —— 原型（EPIC #3923：C3 骨架与对话 · C5 任务 · C6 用量 · C7 设备 · C8 设置 · C21 我自己的订阅 · C4 会话 · #3996 对话时菜单收起）</h1>
<p>就是上线时的构建：共享主题包 + shadcn/ui 现成组件；接口是入口的真实字段，人和数字是演示的。左深右浅。点底栏 / 侧栏能切页。手机上「对话」页底栏收起，点顶栏右上「菜单」唤出、输入或滑动时再收起；电脑侧栏左上按钮可收成窄条（刷新后保持）。「会话」页点卡片可回收 / 接回，演示数据会跟着动。</p></header>
<div class="bar" id="bar"></div>
<div class="frames" id="frames"></div>
<script>
// each frame pins its scheme: the system's dark rule always on (dark) or never (light)
const APP = { dark: ${JSON.stringify(html.replaceAll("@media (prefers-color-scheme: dark)", "@media all").replaceAll("@media (prefers-color-scheme:dark)", "@media all")).replace(/<\//g, "<\\/")},
  light: ${JSON.stringify(html.replaceAll("@media (prefers-color-scheme: dark)", "@media not all").replaceAll("@media (prefers-color-scheme:dark)", "@media not all")).replace(/<\//g, "<\\/")} };
const S = { page: ${JSON.stringify(process.env.PROTO_PAGE || "/")}, role: "user", state: "normal", sub: "none", trial: "", width: 390, lang: "zh" };
const OPTS = {
  page: [["/", "对话"], ["/sessions", "会话"], ["/tasks", "任务"], ["/tasks?tab=tickets", "单子"], ["/tasks/tickets/linxiao/reports/42", "一张单子"], ["/usage", "用量"], ["/devices?tab=pc", "设备·电脑"], ["/devices?tab=phone", "设备·手机"], ["/devices?tab=keys", "设备·公钥"], ["/devices?tab=home", "设备·我的机器"], ["/me", "我的"], ["/settings", "设置"]],
  role: [["user", "成员 林晓"], ["admin", "管理员 周宁"]],
  state: [["normal", "平常"], ["ask", "有会话在问你"], ["empty", "新来的（空）"], ["no_home", "还没有家"], ["over", "额度用完"], ["loading", "加载中"], ["error", "出错"], ["unlimited", "不限额"], ["entry_off", "直连没开"]],
  sub: [["none", "空（没接）"], ["login", "登录中"], ["connected", "已接上"], ["paused", "已暂停"], ["reauth", "要重新登录"], ["error", "读不到"]],
  trial: [["", "不是试用"], ["running", "试用中"], ["last", "条数用完"], ["capped", "用完了"]],
  width: [[390, "手机 390"], [1280, "电脑 1280"]],
  lang: [["zh", "中文"], ["en", "English"]],
};
const LABEL = { page: "页面", role: "谁在看", state: "情形", sub: "我自己的订阅（用量页）", trial: "试用（对话页）", width: "宽度", lang: "语言" };
function draw() {
  const bar = document.getElementById("bar"); bar.innerHTML = "";
  for (const k of Object.keys(OPTS)) {
    const g = document.createElement("div"); g.className = "grp";
    g.innerHTML = "<span>" + LABEL[k] + "</span>";
    for (const [v, l] of OPTS[k]) {
      const b = document.createElement("button"); b.textContent = l; b.setAttribute("aria-pressed", String(S[k] === v));
      b.onclick = () => { S[k] = v; draw(); }; g.appendChild(b);
    }
    bar.appendChild(g);
  }
  const fr = document.getElementById("frames"); fr.innerHTML = "";
  for (const scheme of ["dark", "light"]) {
    const f = document.createElement("figure");
    f.innerHTML = "<figcaption>" + (scheme === "dark" ? "深色" : "浅色") + " · " + S.width + "×" + (S.width === 390 ? 844 : 800) + "</figcaption>";
    const i = document.createElement("iframe");
    i.width = S.width; i.height = S.width === 390 ? 844 : 800; i.style.colorScheme = scheme;
    i.name = JSON.stringify({ role: S.role, state: S.state, sub: S.sub, page: S.page, ...(S.trial ? { trial: S.trial } : {}) });
    // a srcdoc frame keeps no cookie: the language rides on navigator.language there too;
    // its scheme rides on matchMedia, which the console's data-theme reads (#3931)
    i.srcdoc = APP[scheme].replace("<head>", "<head><script>document.cookie='cf_lang=" + S.lang + "';Object.defineProperty(navigator,'language',{value:'" + (S.lang === "zh" ? "zh-CN" : "en") + "'});window.__SCHEME='" + scheme + "';const mm=matchMedia.bind(window);window.matchMedia=(q)=>/prefers-color-scheme/.test(q)?{matches:/dark/.test(q)===(window.__SCHEME==='dark'),media:q,onchange:null,addEventListener(){},removeEventListener(){},addListener(){},removeListener(){},dispatchEvent(){return false}}:mm(q);<\\/script>");
    f.appendChild(i); fr.appendChild(f);
  }
}
draw();
</script></body></html>`;
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, "prototype.html"), page);
console.log(`inline.mjs: ${path.join(out, "prototype.html")} (${(page.length / 1024).toFixed(0)} KB)`);
