package api

import "github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"

// pageText is every sentence the public pages say — the front page,
// /signin, the "can't use this hub" refusal and the /fleet/login
// confirmation — in both languages (claude-fleet#2023).
//
// The words follow the Chinese design page's glossary, the same one at the
// head of web/dist/lib/i18n/zh-CN.js: 会话 / 执行会话 / 机器 / 设备 / 订阅 /
// 订阅池 / 余量 / 登录 / 管理员 / 使用者 / 凭据. Never translated: the product
// name, commands (fleet login), session keys, machine names, model ids.
//
// {v} in a key is a value the page bolds (tb in pagelang.go); {name} anywhere
// else is filled by the caller. pagelang_test.go fails a key missing either
// language and a template naming a key that is not here.
var pageText = map[string]i18n.Text{
	"lang.label": {i18n.EN: "Language", i18n.ZhCN: "语言"},

	// ── the front page (landing.html) ─────────────────────────────────
	// For people who are not developers (claude-fleet#3307): plain words, no
	// internal names. The mock's words are the client's own (fleet_view.py's
	// panel, fleet-topbar.py's top line).
	"landing.description": {
		i18n.EN:   "Claude Code, already set up for you: it runs on our machines, and you open it from your computer or your phone.",
		i18n.ZhCN: "Claude Code，已经替你装好：跑在我们的机器上，从电脑或手机打开就能用。",
	},
	"landing.nav.how": {i18n.EN: "How it works", i18n.ZhCN: "怎么用"},
	"landing.signin":  {i18n.EN: "Sign in", i18n.ZhCN: "登录"},
	"landing.h1.pre":  {i18n.EN: "Claude Code, ", i18n.ZhCN: "Claude Code，"},
	"landing.h1.em":   {i18n.EN: "already set up", i18n.ZhCN: "已经替你装好"},
	"landing.h1.post": {i18n.EN: " for you.", i18n.ZhCN: "。"},
	"landing.sub": {
		i18n.EN: "It runs on our machines, and you open it from your computer or your phone. " +
			"There is nothing to install on the phone, the subscriptions are provided, and the machine you land on is your own home machine.",
		i18n.ZhCN: "它跑在我们的机器上，你从电脑或手机打开就能用。" +
			"手机上什么都不用装，订阅由我们提供，你连进去的是属于你自己的家机器。",
	},
	"landing.cta.signin":    {i18n.EN: "Sign in with GitHub", i18n.ZhCN: "用 GitHub 登录"},
	"landing.cta.phone":     {i18n.EN: "Open on your phone", i18n.ZhCN: "在手机上打开"},
	"landing.install.label": {i18n.EN: "On a computer, one line sets it up:", i18n.ZhCN: "在电脑上，一行就装好："},
	"landing.copy":          {i18n.EN: "Copy", i18n.ZhCN: "复制"},
	"landing.copied":        {i18n.EN: "Copied", i18n.ZhCN: "已复制"},

	"landing.mock.aria": {
		i18n.EN:   "A computer and a phone, each showing one session full screen with the panel of every session open over it",
		i18n.ZhCN: "一台电脑和一部手机，各自整屏显示一个会话，上面打开着列出所有会话的面板",
	},
	"landing.mock.cap.mac":   {i18n.EN: "On your computer · iTerm2 · ⌘P", i18n.ZhCN: "在电脑上 · iTerm2 · ⌘P"},
	"landing.mock.cap.phone": {i18n.EN: "On your phone · Termius · ⌃space", i18n.ZhCN: "在手机上 · Termius · ⌃空格"},
	"landing.mock.working":   {i18n.EN: "working", i18n.ZhCN: "在干活"},
	"landing.mock.left":      {i18n.EN: "62% left", i18n.ZhCN: "剩余 62%"},
	"landing.mock.s1":        {i18n.EN: "Weekly sales report", i18n.ZhCN: "每周销售周报"},
	"landing.mock.s2":        {i18n.EN: "Fix the signup form", i18n.ZhCN: "修好报名表"},
	"landing.mock.s3":        {i18n.EN: "Draft the newsletter", i18n.ZhCN: "写本期简报"},
	"landing.mock.s4":        {i18n.EN: "Tidy the photos folder", i18n.ZhCN: "整理照片文件夹"},
	"landing.mock.ask":       {i18n.EN: "asks: which colour?", i18n.ZhCN: "在问：用哪个颜色？"},
	"landing.mock.you":       {i18n.EN: "Chart last month's sales from sales.csv", i18n.ZhCN: "用 sales.csv 画上个月的销售图"},
	"landing.mock.c1":        {i18n.EN: "Read sales.csv · 412 rows", i18n.ZhCN: "读了 sales.csv · 412 行"},
	"landing.mock.c2":        {i18n.EN: "Wrote chart.png", i18n.ZhCN: "写好 chart.png"},
	"landing.mock.c3":        {i18n.EN: "Sales were up 18% in March, mostly from the new shop.", i18n.ZhCN: "三月销售涨了 18%，主要来自新开的店。"},
	"landing.mock.filter":    {i18n.EN: "type to filter", i18n.ZhCN: "打字筛选"},
	"landing.mock.dispatch":  {i18n.EN: "⚡ Dispatch a task…", i18n.ZhCN: "⚡ 派一件事…"},
	"landing.mock.new":       {i18n.EN: "+ New session", i18n.ZhCN: "+ 新会话"},
	"landing.mock.g.ask":     {i18n.EN: "Waiting on you 1", i18n.ZhCN: "等你 1"},
	"landing.mock.g.work":    {i18n.EN: "Working 2", i18n.ZhCN: "在干活 2"},
	"landing.mock.g.landed":  {i18n.EN: "Just landed 1", i18n.ZhCN: "刚落地 1"},
	"landing.mock.keys":      {i18n.EN: "↵ go  Tab act  ↑↓ pick  esc close", i18n.ZhCN: "↵ 切过去  Tab 操作  ↑↓ 选  esc 关"},
	"landing.mock.home":      {i18n.EN: "home", i18n.ZhCN: "家机器"},
	"landing.mock.phonekey":  {i18n.EN: "ctrl, then space", i18n.ZhCN: "点 ctrl，再点空格"},

	"landing.meter.caption": {
		i18n.EN:   "Claude and Codex tokens used here so far, counted live.",
		i18n.ZhCN: "这里至今用掉的 Claude 和 Codex token，实时累计。",
	},
	"landing.what.eyebrow": {i18n.EN: "Why it's easy", i18n.ZhCN: "为什么省事"},
	"landing.what.h2":      {i18n.EN: "One key, any device, a machine of your own", i18n.ZhCN: "一个键、任何设备、一台你自己的机器"},
	"landing.f1.h":         {i18n.EN: "One key: ⌘P", i18n.ZhCN: "一个键：⌘P"},
	"landing.f1.p": {
		i18n.EN:   "⌘P opens one panel with every session you have, on every machine, and everything you can do with them: start one, answer one, put one away.",
		i18n.ZhCN: "⌘P 打开一个面板：你所有的会话，不管在哪台机器上，还有能对它们做的事——开一个、回答一个、收起一个，都在这里。",
	},
	"landing.f2.h": {i18n.EN: "Any device", i18n.ZhCN: "任何设备"},
	"landing.f2.p": {
		i18n.EN:   "A computer takes one line to set up. A phone takes nothing but Termius: no other install, no Tailscale, and no computer left on.",
		i18n.ZhCN: "电脑上一行装好。手机上只要 Termius：不用再装别的，不用 Tailscale，也不用开着电脑。",
	},
	"landing.f3.h": {i18n.EN: "Your home machine, already set up", i18n.ZhCN: "你的家机器，已经装好"},
	"landing.f3.p": {
		i18n.EN:   "Claude Code is installed, the subscriptions are pooled, and the Mac and Linux machines behind it are looked after for you.",
		i18n.ZhCN: "Claude Code 已经装好，订阅合在一个池里共用，背后的 Mac 和 Linux 机器也有人替你照看。",
	},
	"landing.how.eyebrow":  {i18n.EN: "How it works", i18n.ZhCN: "怎么用"},
	"landing.how.h2":       {i18n.EN: "Start from whichever device is in your hand", i18n.ZhCN: "手边是哪台设备，就从哪台开始"},
	"landing.how.computer": {i18n.EN: "On a computer", i18n.ZhCN: "在电脑上"},
	"landing.how.phone":    {i18n.EN: "On a phone", i18n.ZhCN: "在手机上"},
	"landing.c1.h":         {i18n.EN: "Install", i18n.ZhCN: "装上"},
	"landing.c1.pre":       {i18n.EN: "Paste ", i18n.ZhCN: "在「终端」里粘贴 "},
	"landing.c1.post":      {i18n.EN: " into Terminal and press return.", i18n.ZhCN: "，按回车。"},
	"landing.c2.h":         {i18n.EN: "Type fleet", i18n.ZhCN: "输入 fleet"},
	"landing.c2.post": {
		i18n.EN:   " signs you in with GitHub and takes you to your home machine.",
		i18n.ZhCN: " 会用 GitHub 登录，然后带你进家机器。",
	},
	"landing.c3.h": {i18n.EN: "Press ⌘P", i18n.ZhCN: "按 ⌘P"},
	"landing.c3.p": {i18n.EN: "Pick a session, or start a new one.", i18n.ZhCN: "挑一个会话，或者开一个新的。"},
	"landing.m1.h": {i18n.EN: "Get Termius", i18n.ZhCN: "装 Termius"},
	"landing.m1.p": {
		i18n.EN:   "It is free on the App Store. Make a key in it; the private half never leaves your phone.",
		i18n.ZhCN: "App Store 里免费。在里面生成一把钥匙，私钥一直留在手机上。",
	},
	"landing.m2.h":    {i18n.EN: "Add your key", i18n.ZhCN: "加上钥匙"},
	"landing.m2.pre":  {i18n.EN: "Sign in with GitHub and paste the public key on ", i18n.ZhCN: "用 GitHub 登录后，把公钥贴到 "},
	"landing.m2.post": {i18n.EN: ".", i18n.ZhCN: "。"},
	"landing.m3.h":    {i18n.EN: "Connect", i18n.ZhCN: "连上"},
	"landing.m3.pre":  {i18n.EN: "In Termius, add a host for ", i18n.ZhCN: "在 Termius 里新建主机 "},
	"landing.m3.addr": {i18n.EN: "your address", i18n.ZhCN: "你的地址"},
	"landing.m3.post": {
		i18n.EN:   ". The keys page gives you all four fields to copy.",
		i18n.ZhCN: "：钥匙页把要填的四项都写好了，照抄就行。",
	},
	"landing.m4.h": {i18n.EN: "Press ⌃space", i18n.ZhCN: "按 ⌃空格"},
	"landing.m4.p": {
		i18n.EN:   "Tap ctrl, then space: the same panel as ⌘P on a computer.",
		i18n.ZhCN: "先点 ctrl，再点空格：就是电脑上 ⌘P 的那个面板。",
	},
	"landing.foot.oss":    {i18n.EN: "claudefleet · open source, MIT", i18n.ZhCN: "claudefleet · 开源，MIT 许可"},
	"landing.foot.hosted": {i18n.EN: "Hosted at {host}", i18n.ZhCN: "部署在 {host}"},

	// ── /signin ───────────────────────────────────────────────────────
	"signin.title":  {i18n.EN: "Sign in · claudefleet", i18n.ZhCN: "登录 · claudefleet"},
	"signin.h1":     {i18n.EN: "Sign in to claudefleet", i18n.ZhCN: "登录 claudefleet"},
	"signin.lead":   {i18n.EN: "This hub is private. Use the GitHub account an admin added.", i18n.ZhCN: "这个入口是私有的，请用管理员加过的 GitHub 账号登录。"},
	"signin.button": {i18n.EN: "Continue with GitHub", i18n.ZhCN: "用 GitHub 继续"},
	"signin.fine": {
		i18n.EN:   "claudefleet asks GitHub only who you are. It gets no access to your repositories or organizations.",
		i18n.ZhCN: "claudefleet 只向 GitHub 了解你是谁，拿不到你的仓库和组织。",
	},
	"signin.note.expired": {
		i18n.EN:   "That sign-in took too long or was started in another tab. Try again.",
		i18n.ZhCN: "这次登录太久了，或者是在另一个标签页里开始的。请再试一次。",
	},
	"signin.note.cancelled": {
		i18n.EN:   "GitHub didn't sign you in. Try again when you're ready.",
		i18n.ZhCN: "GitHub 没有让你登录。准备好了再试一次。",
	},
	"signin.note.github": {
		i18n.EN:   "GitHub couldn't be reached to finish signing you in. Try again in a minute.",
		i18n.ZhCN: "连不上 GitHub，没能完成登录。过一分钟再试。",
	},

	// ── the refusal ───────────────────────────────────────────────────
	"deny.title": {i18n.EN: "Can't use this hub · claudefleet", i18n.ZhCN: "不能使用本入口 · claudefleet"},
	"deny.h1":    {i18n.EN: "This GitHub account can't use this hub", i18n.ZhCN: "这个 GitHub 账号不能使用本入口"},
	"deny.renamed": {
		i18n.EN:   "The username {v} is on this hub's list, but it now belongs to a different GitHub account. An admin can check the Users page.",
		i18n.ZhCN: "用户名 {v} 在本入口的名单上，但它现在属于另一个 GitHub 账号。管理员可以去「使用者」页看一下。",
	},
	"deny.removed": {
		i18n.EN:   "{v} is no longer on this hub's list. Ask an admin to add your GitHub username again.",
		i18n.ZhCN: "{v} 已经不在本入口的名单上了。请让管理员重新加上你的 GitHub 用户名。",
	},
	"deny.notlisted": {
		i18n.EN:   "Nobody has invited {v} to this hub yet. Send this line to an admin: ",
		i18n.ZhCN: "还没有人邀请你（{v}）。把这行发给管理员：",
	},
	// The terminal's last words after deny.notlisted + deny.ask (#2261).
	"deny.after": {
		i18n.EN:   " — once invited, run the line they send you.",
		i18n.ZhCN: "——拿到邀请后，运行他发来的那一行就行。",
	},
	// The line a refused person sends (claude-fleet#2261): plain text, copied.
	"deny.ask": {
		i18n.EN:   "Please invite GitHub user {login}",
		i18n.ZhCN: "请邀请 GitHub 用户 {login}",
	},
	// An invite that cannot be used (claude-fleet#2261), one per reason.
	"deny.invite.expired": {
		i18n.EN:   "This invite has expired — an invite lasts 7 days. Ask whoever sent it for a new one.",
		i18n.ZhCN: "这条邀请已过期——邀请 7 天有效。请发邀请的人再发一条。",
	},
	"deny.invite.used": {
		i18n.EN:   "This invite was already used — each one lets one person in, once. Ask whoever sent it for a new one.",
		i18n.ZhCN: "这条邀请已经用过了——一条邀请只放一个人进来一次。请发邀请的人再发一条。",
	},
	"deny.invite.revoked": {
		i18n.EN:   "An admin withdrew this invite. Ask them for a new one.",
		i18n.ZhCN: "管理员已撤销这条邀请。请找他再发一条。",
	},
	"deny.invite.unknown": {
		i18n.EN:   "This hub never made this invite. Check the whole command was pasted, or ask for a new one.",
		i18n.ZhCN: "本入口没发过这条邀请。看看命令是不是没粘全，或者请人再发一条。",
	},
	"deny.invite.other-user": {
		i18n.EN:   "This invite is for another GitHub account, not {v}. Sign in with that account, or ask for an invite of your own.",
		i18n.ZhCN: "这条邀请是发给另一个 GitHub 账号的，不是 {v}。换那个账号登录，或者请人给你单独发一条。",
	},
	"deny.another": {i18n.EN: "Use another account", i18n.ZhCN: "换个账号"},
	"deny.back":    {i18n.EN: "Back to claudefleet", i18n.ZhCN: "回到 claudefleet"},
	"deny.fine": {
		i18n.EN:   "Response 403 · no session created · the attempt is in the audit log.",
		i18n.ZhCN: "返回 403 · 没有建立登录 · 这次尝试已记入审计。",
	},

	// ── /fleet/login — a terminal's `fleet login` confirmed in the browser ──
	"login.title":        {i18n.EN: "Get a connection certificate", i18n.ZhCN: "领取连接证书"},
	"login.title.node":   {i18n.EN: "Add {machine} as a node", i18n.ZhCN: "把 {machine} 加为节点"},
	"login.this.machine": {i18n.EN: "this machine", i18n.ZhCN: "这台机器"},
	"login.denied": {
		i18n.EN:   "Refused. fleet login in the terminal will stop.",
		i18n.ZhCN: "已拒绝。终端里的 fleet login 会停下来。",
	},
	"login.done.node": {
		i18n.EN:   "Added {node} as a node (certificate for {login}, valid until {until}). Back in the terminal, fleet node join finishes installing it and brings it online.",
		i18n.ZhCN: "已把 {node} 加为节点（证书签给 {login}，{until} 前有效）。回到终端，fleet node join 会接着装好并上线。",
	},
	"login.done": {
		i18n.EN:   "Signed in — you can go back to the terminal. (Certificate for {login}, valid until {until}; the terminal writes it for you.)",
		i18n.ZhCN: "已登录，可以回到终端。（证书签给 {login}，{until} 前有效，终端会自动写好。）",
	},
	"login.confirm.lead": {
		i18n.EN:   "Check that the code below matches the one in your terminal, then choose Confirm.",
		i18n.ZhCN: "确认终端上显示的验证码与下面一致，再点「确认签发」。",
	},
	"login.code":     {i18n.EN: "Code", i18n.ZhCN: "验证码"},
	"login.for":      {i18n.EN: "Issued to", i18n.ZhCN: "签给"},
	"login.account":  {i18n.EN: "system account", i18n.ZhCN: "系统账号"},
	"login.keyfp":    {i18n.EN: "Key fingerprint", i18n.ZhCN: "密钥指纹"},
	"login.validity": {i18n.EN: "Valid for 12 hours; fleet renews it by itself.", i18n.ZhCN: "有效期 12 小时，fleet 会自己续期。"},
	"login.node.note": {
		i18n.EN:   "Once confirmed, {node} becomes a node: the hub can place sessions on it.",
		i18n.ZhCN: "确认后 {node} 成为节点：入口可以把会话派到它上面。",
	},
	"login.btn.deny":    {i18n.EN: "Not me", i18n.ZhCN: "不是我"},
	"login.btn.approve": {i18n.EN: "Confirm", i18n.ZhCN: "确认签发"},
	"login.err.gone": {
		i18n.EN:   "This code has expired or was already used. Run fleet login again in the terminal.",
		i18n.ZhCN: "这个验证码已过期或已用过，请在终端重新运行 fleet login。",
	},
	"login.err.drill": {
		i18n.EN:   "The drill approval code is invalid, used or expired.",
		i18n.ZhCN: "演练确认码无效、已用过或已过期。",
	},
	"login.err.issue":  {i18n.EN: "Couldn't issue: {err}", i18n.ZhCN: "签发失败：{err}"},
	"login.err.notyet": {i18n.EN: "Can't issue yet: {err}", i18n.ZhCN: "还不能签发：{err}"},
	"login.err.nomachine": {
		i18n.EN:   "Can't issue yet: {why}. fleet login in the terminal has stopped; run it again once that is done.",
		i18n.ZhCN: "还不能签发：{why}。终端里的 fleet login 已停下，设好后重新运行。",
	},
	"login.why.nologin": {
		i18n.EN:   "the hub has not given you a machine login yet — ask an admin to set one for {who} on the Users page",
		i18n.ZhCN: "入口还没给你分配机器登录 —— 请管理员在「使用者」页给 {who} 设机器登录",
	},
	"login.why.notopen": {
		i18n.EN:   "your machine login {login} is not open on any machine yet — ask an admin to check {who} on the Users page",
		i18n.ZhCN: "你的机器登录 {login} 还没在任何机器上开好 —— 请管理员在「使用者」页查看 {who}",
	},
	"login.err.noperson": {
		i18n.EN:   "A connection certificate needs a personal GitHub sign-in (the operator token belongs to no one).",
		i18n.ZhCN: "领取连接证书需要用 GitHub 登录（运营者令牌不对应任何人）。",
	},
}
