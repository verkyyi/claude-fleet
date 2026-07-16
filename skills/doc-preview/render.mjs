// Render Markdown for the doc-preview skill. Three modes:
//   page  <srcMd> <outHtml> <metaJson>   — render one doc + write its entry metadata
//                                           (reads ID/HREF/ADDED/SESSION/SRC from env)
//   index <outIndexHtml> <entriesDir>     — (re)build the fixed root page listing ALL entries
//   list  <entriesDir>                    — print current entries as plain text (for --list)
//
// Rendering is client-side (marked + github-markdown-css from a CDN, loaded by the
// viewer's browser) so the host needs no npm install — just node.
import fs from 'node:fs';
import path from 'node:path';

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// Lucide-style inline stroke icons (match Claude artifact aesthetics; no emoji).
const ICON_PATHS = {
  'book-open': '<path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/>',
  'file-text': '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/>',
  moon: '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>',
  menu: '<line x1="4" x2="20" y1="6" y2="6"/><line x1="4" x2="20" y1="12" y2="12"/><line x1="4" x2="20" y1="18" y2="18"/>',
  'arrow-up': '<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>',
  'arrow-right': '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  inbox: '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
};
const icon = (name, size = 16, cls = '') =>
  `<svg class="ico${cls ? ' ' + cls : ''}" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON_PATHS[name]}</svg>`;

function pageHtml(title, b64, meta = {}) {
  const metaLine = [
    meta.session ? `${esc(meta.session)}` : '',
    meta.added ? `${esc(meta.added)}` : '',
    meta.disp ? `<span class="mono" title="${esc(meta.full || meta.disp)}">${esc(meta.disp)}</span>` : '',
  ].filter(Boolean).join('<span class="sep">·</span>');
  return `<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<!-- Dark variants are scoped to screen only: print media queries can't flip prefers-color-scheme,
     so an unscoped dark stylesheet would print a dark (ink-wasting) page from a dark-themed device.
     Light variants also cover print → printing is always light, automatically. -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github.min.css" media="print, screen and (prefers-color-scheme: light)">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github-dark.min.css" media="screen and (prefers-color-scheme: dark)">
<style>
 /* doc-preview 文档样式 —— 阅读/打印优先，明暗跟随系统，无交互组件（仅 tailnet 内公开链接开关）。
    设计语言对齐 Claude Artifact 文档：考究字阶 + 有色偏中性色 + 单一强调色(teal) + 打印适配。 */
 :root{color-scheme:light dark;
   --ground:#f3f6f5;--surface:#fff;--ink:#1a2220;--mut:#5c6d68;
   --accent:#0f9e86;--accent-soft:#e6f4ef;--hairline:#e5eae8;--bd:#e5eae8;
   --code-bg:#f4f7f6;--code-ink:#1f2a27;--sel:#cdeee5;
   --shadow:0 1px 2px rgba(20,40,36,.05),0 16px 40px -22px rgba(20,40,36,.28);--maxw:47rem}
 @media(prefers-color-scheme:dark){:root{
   --ground:#0e1413;--surface:#151d1b;--ink:#e9efec;--mut:#93a7a1;
   --accent:#3fc9ad;--accent-soft:#123029;--hairline:#243330;--bd:#243330;
   --code-bg:#101917;--code-ink:#d6e0dd;--sel:#1d4b41;
   --shadow:0 1px 2px rgba(0,0,0,.3),0 22px 46px -24px rgba(0,0,0,.62)}}
 html{scroll-behavior:smooth}
 body{margin:0;background:var(--ground);color:var(--ink);
   font:15.5px/1.78 -apple-system,BlinkMacSystemFont,system-ui,"PingFang SC","Hiragino Sans GB","Microsoft YaHei","Noto Sans SC",sans-serif;
   -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
 ::selection{background:var(--sel)}
 /* 页眉 + 公开链接开关（与文档同宽居中） */
 .hdr{max-width:var(--maxw);margin:0 auto;padding:22px 8px 0;display:flex;align-items:center;gap:8px;flex-wrap:wrap;
   font-size:12.5px;color:var(--mut)}
 .hdr a{display:inline-flex;align-items:center;gap:5px;color:var(--accent);text-decoration:none;font-weight:500}
 .hdr a:hover{text-decoration:underline}
 .hdr .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;overflow-wrap:anywhere}
 .hdr .sep{opacity:.5;margin:0 2px}
 .ico{flex:none;vertical-align:-2px}
 .share{display:inline-flex;align-items:center;gap:7px;margin-left:auto}
 .share[hidden]{display:none}
 .share .swlbl{font-size:12px;color:var(--mut)}
 .sw{position:relative;width:34px;height:19px;flex:none;border-radius:999px;border:1px solid var(--bd);
   background:color-mix(in srgb,var(--ink) 9%,transparent);cursor:pointer;padding:0;transition:.15s}
 .sw .knob{position:absolute;top:1px;left:1px;width:15px;height:15px;border-radius:50%;background:var(--surface);
   box-shadow:0 1px 2px rgba(0,0,0,.25);transition:.15s}
 .share.on .sw{background:var(--accent);border-color:var(--accent)}
 .share.on .sw .knob{left:16px}
 .sw:disabled{opacity:.5;cursor:progress}
 .purl{display:inline-flex;align-items:center;gap:6px;font-size:11.5px}
 .purl a{color:var(--accent);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;text-decoration:none;overflow-wrap:anywhere}
 .purl a:hover{text-decoration:underline}
 .cpy{font-size:11px;border:1px solid var(--bd);background:transparent;color:var(--mut);border-radius:6px;padding:1px 7px;cursor:pointer}
 .cpy:hover{color:var(--accent);border-color:var(--accent)}
 .spin{font-size:12px;color:var(--mut)}
 /* 文档纸面 */
 .markdown-body{box-sizing:border-box;max-width:var(--maxw);margin:16px auto 60px;background:var(--surface);
   border:1px solid var(--hairline);border-radius:14px;box-shadow:var(--shadow);padding:clamp(24px,4.5vw,52px)}
 .markdown-body>:first-child{margin-top:0}
 .markdown-body>:last-child{margin-bottom:0}
 .markdown-body :is(h1,h2,h3,h4,h5,h6){line-height:1.32;font-weight:700;text-wrap:balance;scroll-margin-top:16px;margin:1.85em 0 .7em}
 .markdown-body h1{font-size:1.68em;margin:.1em 0 .5em;letter-spacing:-.01em}
 .markdown-body h2{font-size:1.16em;letter-spacing:.005em}
 .markdown-body :is(h2,h3).numbered{display:flex;align-items:baseline;gap:.5em}
 .markdown-body .hn{flex:none;color:var(--accent);font-weight:700;font-size:.86em;font-variant-numeric:tabular-nums;min-width:1.3em}
 .markdown-body .ht{text-wrap:balance;min-width:0}
 .markdown-body h3{font-size:.98em;color:var(--mut);margin-top:1.7em}
 .markdown-body h4{font-size:1.02em}
 .markdown-body :is(h5,h6){font-size:.9em;color:var(--mut);letter-spacing:.02em}
 .markdown-body p{margin:0 0 1em}
 .markdown-body a{color:var(--accent);text-decoration:none;border-bottom:1px solid color-mix(in srgb,var(--accent) 32%,transparent)}
 .markdown-body a:hover{border-bottom-color:var(--accent)}
 .markdown-body strong{font-weight:700}
 .markdown-body em{font-style:italic}
 .markdown-body hr{height:1px;background:var(--hairline);border:0;margin:2em 0}
 .markdown-body :is(ul,ol){margin:0 0 1em;padding-left:1.45em}
 .markdown-body li{margin:.3em 0}
 .markdown-body li::marker{color:var(--accent)}
 .markdown-body :is(ul ul,ol ol,ul ol,ol ul){margin:.25em 0}
 .markdown-body li.task-list-item{list-style:none;margin-left:-1.15em}
 .markdown-body li.task-list-item input{margin:0 .5em 0 0;vertical-align:middle}
 .markdown-body blockquote{margin:0 0 1.15em;padding:.72em 1.05em;background:var(--accent-soft);
   border-radius:10px;border-left:3px solid var(--accent)}
 .markdown-body blockquote>:first-child{margin-top:0}
 .markdown-body blockquote>:last-child{margin-bottom:0}
 .markdown-body blockquote p{font-size:.96em}
 .markdown-body .eyebrow{display:flex;align-items:center;gap:10px;font-size:12px;letter-spacing:.12em;color:var(--mut);margin:0 0 14px}
 .markdown-body .eyebrow .brand{color:var(--accent);font-weight:700;letter-spacing:.05em}
 .markdown-body .eyebrow .sep{width:1px;height:12px;background:var(--hairline)}
 .markdown-body .status{display:inline-flex;align-items:center;gap:7px;margin:.1em 0 .3em;padding:5px 13px;background:var(--accent-soft);color:var(--accent);border-radius:999px;font-size:13px;font-weight:600;-webkit-print-color-adjust:exact;print-color-adjust:exact}
 .markdown-body .status .dot{flex:none;width:7px;height:7px;border-radius:50%;background:currentColor}
 .markdown-body .facts{display:grid;grid-template-columns:max-content 1fr;border-top:1px solid var(--hairline);margin:0 0 1.15em}
 .markdown-body .facts dt{padding:11px 20px 11px 0;color:var(--mut);font-size:13px;white-space:nowrap;border-bottom:1px solid var(--hairline)}
 .markdown-body .facts dd{margin:0;padding:11px 0;border-bottom:1px solid var(--hairline)}
 .markdown-body .safe{color:var(--accent);font-weight:600}
 @media(max-width:520px){.markdown-body .facts{grid-template-columns:1fr}.markdown-body .facts dt{padding-bottom:2px;border-bottom:0}.markdown-body .facts dd{padding-top:2px}.markdown-body .facts dd:not(:last-child){padding-bottom:12px}}
 .markdown-body .doc-footer{margin:2.6em 0 .4em;padding-top:1.7em;border-top:1px solid var(--hairline);text-align:center}
 .markdown-body .doc-footer .cta{margin:0 0 13px;font-size:14px;font-weight:600;color:var(--accent)}
 .markdown-body .doc-footer .qr{width:128px;height:128px;border-radius:11px;border:1px solid var(--hairline);background:#fff;padding:7px;box-sizing:content-box;-webkit-print-color-adjust:exact;print-color-adjust:exact}
 .markdown-body .doc-footer .org{margin:15px 0 0;font-size:13px;color:var(--mut)}
 .markdown-body .doc-footer .co{margin:3px 0 0;font-size:12px;color:var(--mut);opacity:.82}
 .markdown-body :not(pre)>code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.87em;
   background:var(--code-bg);color:var(--code-ink);padding:.13em .42em;border-radius:5px;border:1px solid var(--hairline)}
 .markdown-body pre{margin:0 0 1.15em;padding:14px 16px;background:var(--code-bg);border:1px solid var(--hairline);
   border-radius:10px;overflow-x:auto;font-size:12.8px;line-height:1.6}
 .markdown-body pre code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:none;border:0;padding:0;color:var(--code-ink)}
 .markdown-body pre code.hljs{background:none;padding:0}
 .markdown-body img{max-width:100%;height:auto;border-radius:8px}
 .markdown-body .mermaid{margin:0 0 1.15em;text-align:center;overflow-x:auto}
 /* 表格：容器可横滚（窄屏/长表兜底），细线 + 斑马 + 等宽数字 */
 .tbl{overflow-x:auto;margin:0 0 1.3em;border:1px solid var(--hairline);border-radius:10px}
 .markdown-body .tbl table{margin:0;display:table;width:100%;max-width:none;border-collapse:collapse;
   font-size:13.5px;line-height:1.55;font-variant-numeric:tabular-nums}
 .markdown-body .tbl thead th{background:color-mix(in srgb,var(--accent-soft) 60%,var(--surface));
   text-align:left;font-weight:700;color:var(--mut);font-size:12px;letter-spacing:.02em;
   padding:9px 13px;border-bottom:1.5px solid var(--hairline);white-space:nowrap}
 .markdown-body .tbl td{padding:8px 13px;border-bottom:1px solid var(--hairline);vertical-align:top;
   white-space:normal}
 /* 长 token（会员编号/哈希/URL）不折行，整体展示；过宽时表格容器横向滚动 */
 .markdown-body .tbl :is(td,th){overflow-wrap:normal}
 .markdown-body .tbl :is(td,th) code{white-space:nowrap;word-break:normal}
 .markdown-body .nw{white-space:nowrap}  /* 单元格内不折行的短数据（时间/编号等） */
 .markdown-body .tbl tbody tr:last-child td{border-bottom:0}
 .markdown-body .tbl tbody tr:nth-child(even){background:color-mix(in srgb,var(--accent-soft) 30%,transparent)}
 .markdown-body .tbl :is(th,td)[align=right]{text-align:right}
 .markdown-body .tbl :is(th,td)[align=center]{text-align:center}
 @media(max-width:760px){
   body{font-size:15px}
   .markdown-body{margin:10px auto 44px;padding:20px 16px;border-radius:12px}
   .markdown-body h1{font-size:1.55em}.markdown-body h2{font-size:1.1em}
   .markdown-body .tbl :is(th,td){font-size:12.5px;padding:6px 9px}
   .hdr{padding:14px 13px 0}
 }
 @media print{
   :root{color-scheme:light;--ground:#fff;--surface:#fff}
   @page{margin:15mm}
   html,body{background:#fff !important;color:#1f2328}
   .hdr,.share,.spin{display:none !important}
   .markdown-body{max-width:none;margin:0;padding:0;border:0;border-radius:0;box-shadow:none;font-size:12px;background:#fff}
   .markdown-body h1{border-color:#d5dbd9}
   .tbl{overflow:visible;border-color:#d5dbd9}
   .markdown-body pre{white-space:pre-wrap;word-break:break-word;background:#f6f8f7 !important;-webkit-print-color-adjust:exact;print-color-adjust:exact}
   .markdown-body :is(pre,blockquote,img,figure,.mermaid){break-inside:avoid}
   .markdown-body thead{display:table-header-group}
   .markdown-body .tbl thead th{background:#eef4f2 !important;-webkit-print-color-adjust:exact;print-color-adjust:exact}
   .markdown-body .tbl tbody tr:nth-child(even){background:#f6f9f8 !important;-webkit-print-color-adjust:exact;print-color-adjust:exact}
   .markdown-body blockquote{background:#eef6f3 !important;-webkit-print-color-adjust:exact;print-color-adjust:exact}
   .markdown-body tr{break-inside:avoid}
   .markdown-body :is(h1,h2,h3,h4){break-after:avoid-page;break-inside:avoid}
   .markdown-body a{color:inherit;border-bottom:0}
 }
</style></head><body>
<div class="hdr">
 <a href="/">${icon('book-open', 13)}全部文档</a>
 ${metaLine ? `<span class="sep">·</span>${metaLine}` : ''}
 <span class="share" id="share" hidden>
  <button class="sw" id="sw" role="switch" aria-checked="false" aria-label="公开链接" title="生成可公开访问的链接"><span class="knob"></span></button>
  <span class="swlbl">${icon('link', 12)} 公开链接</span>
  <span class="spin" id="spin" hidden>⋯</span>
  <span class="purl" id="purl" hidden><a id="plink" target="_blank" rel="noopener"></a><button class="cpy" id="cpy">复制</button></span>
 </span>
</div>
<article class="markdown-body" id="c"></article>
<script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/highlight.js@11/highlight.min.js"></script>
<script>
 const md = decodeURIComponent(escape(atob("${b64}")));
 marked.setOptions({ gfm:true, breaks:false });
 const c = document.getElementById('c');
 c.innerHTML = marked.parse(md);
 c.querySelectorAll('pre code').forEach(b=>{try{hljs.highlightElement(b)}catch(e){}});

 // 表格套横向滚动容器（窄屏兜底；打印时展开）。
 c.querySelectorAll('table').forEach(t=>{
   const box = document.createElement('div'); box.className='tbl';
   t.before(box); box.appendChild(t);
 });

 // 标题加稳定 id，便于外部 #锚点 链接（无可见交互件）。
 const used = {};
 const slug = (t) => { let s = t.trim().toLowerCase().replace(/[^\\w\\u4e00-\\u9fa5\\s-]/g,'').replace(/\\s+/g,'-') || 'section';
   if (used[s] != null) { used[s]++; s += '-' + used[s]; } else used[s] = 0; return s; };
 c.querySelectorAll('h1,h2,h3,h4').forEach(h=>{ h.id = slug(h.textContent); });
 // 章节号（一/二/… 或 1./１．）抽成 teal 序号标记，贴近 Artifact 版式。
 c.querySelectorAll('h2,h3').forEach(h=>{
   const m=h.textContent.match(/^\\s*([0-9\\uFF10-\\uFF19一二三四五六七八九十百]{1,3})\\s*[、.．·)]\\s*(\\S.*)$/);
   if(!m) return;
   h.classList.add('numbered');
   const hn=document.createElement('span'); hn.className='hn'; hn.textContent=m[1];
   const ht=document.createElement('span'); ht.className='ht'; ht.textContent=m[2];
   h.textContent=''; h.append(hn,ht);
 });

 // mermaid（仅文档用到时才加载渲染）。
 if (c.querySelector('code.language-mermaid')) {
   const s = document.createElement('script');
   s.src = 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js';
   s.onload = () => {
     c.querySelectorAll('code.language-mermaid').forEach(b=>{
       const d = document.createElement('div'); d.className='mermaid'; d.textContent = b.textContent;
       b.closest('pre').replaceWith(d);
     });
     mermaid.initialize({ startOnLoad:false, theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default' });
     mermaid.run({ nodes: c.querySelectorAll('.mermaid') });
   };
   document.body.appendChild(s);
 }

 // 公开链接开关。仅在 tailnet 内查看文档时出现；公网视图（Funnel 把文档挂在 /p/ 路径）直接隐藏。
 // 开关调用同源的 /_ctl 控制接口 —— 该接口只在 tailnet serve 源上存在，Funnel 从不代理它。
 (function(){
   const ID = ${JSON.stringify(meta.id || '')};
   const share0 = document.getElementById('share');
   // 公网视图（Funnel 把文档挂在 /p/ 路径）：彻底移除开关，不留痕迹。
   if (!ID || location.pathname.indexOf('/p/') === 0) { if (share0) share0.remove(); return; }
   const el=document.getElementById('share'), sw=document.getElementById('sw'),
     purl=document.getElementById('purl'), plink=document.getElementById('plink'),
     cpy=document.getElementById('cpy'), spin=document.getElementById('spin');
   if(!el||!sw) return;
   const setState=(pub,url)=>{ sw.setAttribute('aria-checked',pub?'true':'false'); el.classList.toggle('on',!!pub);
     if(pub&&url){ plink.href=url; plink.textContent=url.replace(/^https?:\\/\\//,''); purl.hidden=false; } else { purl.hidden=true; } };
   const busy=b=>{ spin.hidden=!b; sw.disabled=b; };
   const api=(method,route)=>{ busy(true);
     return fetch(route,{method,headers:{'Content-Type':'application/json'},body:method==='POST'?JSON.stringify({id:ID}):undefined})
       .then(r=>r.json()).catch(()=>({error:'network'})).finally(()=>busy(false)); };
   api('GET','/_ctl/status?id='+encodeURIComponent(ID)).then(d=>{ if(d&&!d.error){ el.hidden=false; setState(d.public,d.url); } });
   sw.addEventListener('click',()=>{ const on=sw.getAttribute('aria-checked')!=='true';
     api('POST',on?'/_ctl/publish':'/_ctl/unpublish').then(d=>{ if(d&&!d.error) setState(d.public,d.url); else alert('公开链接操作失败：'+((d&&d.error)||'unknown')); }); });
   cpy.addEventListener('click',()=>{ if(navigator.clipboard) navigator.clipboard.writeText(plink.href).then(()=>{ cpy.textContent='已复制'; setTimeout(()=>cpy.textContent='复制',1200); }); });
 })();
</script></body></html>`;
}

function readEntries(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')); } catch { return null; } })
    .filter(Boolean)
    .sort((a, b) => String(b.id).localeCompare(String(a.id)));
}

// Deterministic pastel chip color per session label (stable across rebuilds).
function chipColor(s) {
  let h = 0;
  for (const ch of String(s || '?')) h = (h * 31 + ch.codePointAt(0)) % 360;
  return { bg: `hsl(${h} 70% 94%)`, fg: `hsl(${h} 55% 32%)`, br: `hsl(${h} 60% 82%)` };
}

function indexHtml(entries) {
  const cards = entries.map((e) => {
    const c = chipColor(e.session);
    return `<a class="card" href="${esc(e.href)}">
    <div class="doc"><span class="ic">${icon('file-text', 15)}</span><span class="ttl">${esc(e.title)}</span></div>
    <div class="src" title="${esc(e.full || e.src)}">${esc(e.src)}</div>
    <div class="meta">
      <span class="chip" style="background:${c.bg};color:${c.fg};border-color:${c.br}">${esc(e.session || '—')}</span>
      <span class="time">${esc(e.added || '')}</span>
      <span class="open">打开 ${icon('arrow-right', 12)}</span>
    </div></a>`;
  }).join('\n');
  const body = entries.length
    ? `<div class="grid">${cards}</div>`
    : `<div class="empty"><div class="emoji">${icon('inbox', 40)}</div><p>当前没有正在共享的文档。</p>
       <p class="hint">在终端运行 <code>share.sh &lt;file.md&gt;</code> 来分享一篇。</p></div>`;
  const n = entries.length;
  const sessions = [...new Set(entries.map((e) => e.session).filter(Boolean))].length;
  return `<!doctype html><html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>doc-preview · 共享 ${n} 篇</title>
<style>
 :root{--bg:#f6f8fa;--card:#fff;--bd:#d8dee4;--ink:#1f2328;--mut:#636c76;--accent:#0969da}
 *{box-sizing:border-box}
 body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,system-ui,"PingFang SC",Segoe UI,sans-serif}
 .wrap{max-width:940px;margin:0 auto;padding:40px 22px 60px}
 header{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:6px}
 h1{font-size:22px;margin:0;letter-spacing:-.01em;display:inline-flex;align-items:center;gap:8px}
 .pill{font-size:12px;font-weight:600;color:#0a3069;background:#ddf4ff;border:1px solid #b6e3ff;border-radius:999px;padding:2px 10px}
 .live{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--mut);margin-left:auto}
 .dot{width:8px;height:8px;border-radius:50%;background:#1f883d;box-shadow:0 0 0 0 rgba(31,136,61,.5);animation:p 2s infinite}
 @keyframes p{0%{box-shadow:0 0 0 0 rgba(31,136,61,.5)}70%{box-shadow:0 0 0 7px rgba(31,136,61,0)}100%{box-shadow:0 0 0 0 rgba(31,136,61,0)}}
 .sub{color:var(--mut);font-size:13px;margin:2px 0 26px}
 .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:14px}
 .card{display:flex;flex-direction:column;gap:8px;background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:16px 16px 13px;text-decoration:none;color:inherit;transition:.15s ease;box-shadow:0 1px 2px rgba(27,31,36,.04)}
 .card:hover{border-color:#aeb8c2;box-shadow:0 6px 18px rgba(27,31,36,.10);transform:translateY(-2px)}
 .doc{display:flex;align-items:flex-start;gap:8px}
 .ic{line-height:1.4;color:#57606a;display:inline-flex;padding-top:2px} .ttl{font-weight:650;font-size:15px;color:var(--ink);word-break:break-word}
 .src{font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--mut);background:#f0f3f6;border-radius:6px;padding:5px 8px;word-break:break-all}
 .meta{display:flex;align-items:center;gap:8px;margin-top:auto}
 .chip{font-size:11px;font-weight:600;border:1px solid;border-radius:999px;padding:1px 9px;white-space:nowrap}
 .time{font-size:11px;color:#8b949e;white-space:nowrap}
 .open{margin-left:auto;font-size:12px;font-weight:600;color:var(--accent);opacity:0;transition:.15s}
 .card:hover .open{opacity:1}
 .empty{text-align:center;color:var(--mut);padding:70px 0}
 .empty .emoji{color:#8b949e;margin-bottom:6px}.empty .hint{font-size:13px}
 code{background:#eef1f4;border-radius:5px;padding:1px 6px;font:12px ui-monospace,Menlo,monospace}
 footer{margin-top:30px;padding-top:16px;border-top:1px solid #e6eaef;color:#8b949e;font-size:12px;line-height:1.9}
 footer code{background:#eef1f4}
</style></head><body>
<div class="wrap">
 <header>
  <h1>${icon('book-open', 20)} 文档预览</h1>
  <span class="pill">${n} 篇${sessions > 1 ? ` · ${sessions} 个会话` : ''}</span>
  <span class="live"><span class="dot"></span>tailnet 实时预览</span>
 </header>
 <p class="sub">固定地址 · 所有会话共享同一 URL，新分享会追加到下方，不会顶掉已有的。</p>
 ${body}
 <footer>
  管理命令： <code>share.sh &lt;file.md&gt;</code> 追加 ·
  <code>share.sh --remove &lt;关键词&gt;</code> 删除单篇 ·
  <code>share.sh --stop</code> 全部停止
 </footer>
</div>
</body></html>`;
}

const [mode, ...rest] = process.argv.slice(2);

if (mode === 'page') {
  const [src, out, meta] = rest;
  const raw = fs.readFileSync(src, 'utf8');
  const m = raw.match(/^#\s+(.+?)\s*$/m);
  const title = (m ? m[1] : path.basename(src)).slice(0, 120);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, pageHtml(title, Buffer.from(raw, 'utf8').toString('base64'), {
    id: process.env.ID,
    session: process.env.SESSION, added: process.env.ADDED,
    disp: process.env.DISP, full: process.env.SRC,
  }));

  // Copy referenced LOCAL images next to the served page so relative paths resolve
  // (e.g. ![](assets/x.svg) or ![](../../doc/assets/x.svg)). Remote/data URLs are left alone.
  const srcDir = path.dirname(path.resolve(src));
  const outDir = path.dirname(out);
  const seen = new Set();
  for (const mm of raw.matchAll(/!\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)/g)) {
    const url = mm[1].replace(/^<|>$/g, '');
    if (/^(https?:|data:|\/\/|\/)/.test(url) || seen.has(url)) continue;
    seen.add(url);
    const from = path.resolve(srcDir, url);
    const to = path.resolve(outDir, url);
    try {
      if (fs.existsSync(from) && fs.statSync(from).isFile()) {
        fs.mkdirSync(path.dirname(to), { recursive: true });
        fs.copyFileSync(from, to);
      }
    } catch { /* best-effort: a missing image just won't render */ }
  }
  const entry = {
    id: process.env.ID, title,
    src: process.env.DISP || process.env.SRC || src, // short display path (repo/cwd folder + relative)
    full: process.env.SRC || src,                    // full absolute path (tooltip only)
    href: process.env.HREF, added: process.env.ADDED, session: process.env.SESSION,
  };
  fs.mkdirSync(path.dirname(meta), { recursive: true });
  fs.writeFileSync(meta, JSON.stringify(entry, null, 2));
  process.stdout.write(title);
} else if (mode === 'repage') {
  // Re-render an existing entry's page from its entry json (used by share.sh --refresh
  // after a template upgrade; keeps id/href/URL, re-reads the source file's CURRENT content).
  const [metaJson, out] = rest;
  const e = JSON.parse(fs.readFileSync(metaJson, 'utf8'));
  const src = e.full || e.src;
  if (!fs.existsSync(src)) { process.stdout.write(`skip (source gone): ${src}`); process.exit(0); }
  const raw = fs.readFileSync(src, 'utf8');
  const m = raw.match(/^#\s+(.+?)\s*$/m);
  const title = (m ? m[1] : path.basename(src)).slice(0, 120);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, pageHtml(title, Buffer.from(raw, 'utf8').toString('base64'), {
    id: e.id,
    session: e.session, added: e.added, disp: e.src, full: e.full,
  }));
  if (title !== e.title) { e.title = title; fs.writeFileSync(metaJson, JSON.stringify(e, null, 2)); }
  process.stdout.write(title);
} else if (mode === 'index') {
  const [out, entriesDir] = rest;
  fs.writeFileSync(out, indexHtml(readEntries(entriesDir)));
  process.stdout.write(String(readEntries(entriesDir).length));
} else if (mode === 'list') {
  const [entriesDir] = rest;
  const es = readEntries(entriesDir);
  if (!es.length) { process.stdout.write('(none)\n'); }
  for (const e of es) process.stdout.write(`  [${e.session || '?'}] ${e.title}  ${e.href}  <- ${e.src}  (${e.added})\n`);
} else {
  process.stderr.write('usage: render.mjs page|index|list ...\n');
  process.exit(1);
}
