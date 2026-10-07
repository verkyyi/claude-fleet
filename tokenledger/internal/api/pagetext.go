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
	"landing.description": {
		i18n.EN:   "Run a fleet of Claude Code sessions: GitHub issues in, pull requests out, sharing one pool of subscriptions.",
		i18n.ZhCN: "同时跑一队 Claude Code 会话：GitHub issue 进，PR 出，共用一池订阅。",
	},
	"landing.nav.how": {i18n.EN: "How it works", i18n.ZhCN: "工作原理"},
	"landing.signin":  {i18n.EN: "Sign in", i18n.ZhCN: "登录"},
	"landing.h1.pre":  {i18n.EN: "Run a ", i18n.ZhCN: "同时跑"},
	"landing.h1.em":   {i18n.EN: "fleet", i18n.ZhCN: "一队"},
	"landing.h1.post": {i18n.EN: " of Claude Code sessions. One task per window.", i18n.ZhCN: " Claude Code 会话，一个任务一个窗口。"},
	"landing.sub": {
		i18n.EN: "claudefleet turns GitHub issues into parallel coding sessions, each in its own git worktree, running on the fleet's machines and sharing one pool of subscriptions. " +
			"Every task ends as its own pull request. Your computer doesn't need Claude Code installed — a browser or a terminal is enough.",
		i18n.ZhCN: "claudefleet 把 GitHub issue 变成并行的编码会话：每个会话在自己的 git worktree 里，跑在 fleet 的机器上，共用一池订阅，最后各自交一个 PR。" +
			"你的电脑不用装 Claude Code，有浏览器或终端就行。",
	},
	"landing.cta.signin":   {i18n.EN: "Sign in with GitHub", i18n.ZhCN: "用 GitHub 登录"},
	"landing.cta.how":      {i18n.EN: "How it works", i18n.ZhCN: "工作原理"},
	"landing.copy":         {i18n.EN: "Copy", i18n.ZhCN: "复制"},
	"landing.copied":       {i18n.EN: "Copied", i18n.ZhCN: "已复制"},
	"landing.term.aria":    {i18n.EN: "Example of the fleet session list", i18n.ZhCN: "fleet 会话列表示例"},
	"landing.term.bar":     {i18n.EN: "fleet · 5 sessions · 3 machines", i18n.ZhCN: "fleet · 5 个会话 · 3 台机器"},
	"landing.term.session": {i18n.EN: "session", i18n.ZhCN: "会话"},
	"landing.term.machine": {i18n.EN: "machine", i18n.ZhCN: "机器"},
	"landing.term.r1":      {i18n.EN: "Team settings reach every machine", i18n.ZhCN: "团队设置几分钟内到每台机器"},
	"landing.term.r2":      {i18n.EN: "Install sync keeps fleet.conf", i18n.ZhCN: "安装同步保留 fleet.conf"},
	"landing.term.r3":      {i18n.EN: "Doctor row for the team layer", i18n.ZhCN: "体检加一行团队配置"},
	"landing.term.r4":      {i18n.EN: "Front page for the hub", i18n.ZhCN: "入口的首页"},
	"landing.term.r5":      {i18n.EN: "Portal plan", i18n.ZhCN: "入口方案"},
	"landing.term.pool":    {i18n.EN: "pool  A 62% · B 18% · C full · Codex 30%", i18n.ZhCN: "订阅池  A 62% · B 18% · C 已满 · Codex 30%"},
	"landing.meter.caption": {
		i18n.EN:   "Claude and Codex tokens this fleet has run so far, counted live by the hub.",
		i18n.ZhCN: "这个 fleet 至今跑过的 Claude 和 Codex token，由入口实时累计。",
	},
	"landing.what.eyebrow": {i18n.EN: "What it does", i18n.ZhCN: "做什么"},
	"landing.what.h2":      {i18n.EN: "Many sessions, many machines, one place to see them", i18n.ZhCN: "很多会话、很多机器，在一个地方看全"},
	"landing.f1.h":         {i18n.EN: "Issues in, pull requests out", i18n.ZhCN: "issue 进，PR 出"},
	"landing.f1.p": {
		i18n.EN:   "Hand an issue to a worker. It claims it, works in its own worktree, runs the related tests and opens the PR. It asks you only when it needs a decision.",
		i18n.ZhCN: "把一个 issue 交给执行会话。它认领、在自己的 worktree 里改、跑相关测试、开 PR；需要你拍板时才来问。",
	},
	"landing.f2.h": {i18n.EN: "Subscriptions, pooled", i18n.ZhCN: "订阅合成一个池"},
	"landing.f2.p": {
		i18n.EN:   "New sessions start on the Claude or Codex subscription with the most headroom; a full one waits for its window to reset.",
		i18n.ZhCN: "新会话自动用余量最多的 Claude 或 Codex 订阅；用满的那个跳过，等额度重置。",
	},
	"landing.f3.h": {i18n.EN: "Sessions run on the fleet's machines", i18n.ZhCN: "会话跑在 fleet 的机器上"},
	"landing.f3.p": {
		i18n.EN:   "Macs, Linux boxes, a temporary machine when you run out of room. Your computer can sleep; pick up on another device.",
		i18n.ZhCN: "Mac、Linux、不够时临时加一台。你的电脑不用一直开着，换台设备接着看。",
	},
	"landing.how.eyebrow": {i18n.EN: "How it works", i18n.ZhCN: "工作原理"},
	"landing.how.h2":      {i18n.EN: "Three steps to your first fleet session", i18n.ZhCN: "三步跑起第一个 fleet 会话"},
	"landing.s1.h":        {i18n.EN: "Install the client", i18n.ZhCN: "装客户端"},
	"landing.s1.pre":      {i18n.EN: "Run ", i18n.ZhCN: "在你平时用的电脑上运行 "},
	"landing.s1.post":     {i18n.EN: " on the computer you work from.", i18n.ZhCN: "。"},
	"landing.s2.h":        {i18n.EN: "Sign in with GitHub", i18n.ZhCN: "用 GitHub 登录"},
	"landing.s2.post": {
		i18n.EN:   " shows a code; confirm it in the browser. Only people on this hub's list get in.",
		i18n.ZhCN: " 会显示一个验证码，在浏览器里确认。只有本入口名单上的人能进。",
	},
	"landing.s3.h": {i18n.EN: "Hand it an issue", i18n.ZhCN: "交给它一个 issue"},
	"landing.s3.post": {
		i18n.EN:   " starts a worker on the best machine and subscription, and it lands as a PR.",
		i18n.ZhCN: " 在最合适的机器和订阅上开一个执行会话，最后以 PR 合入。",
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
		i18n.EN:   "{v} isn't on this hub's list. Ask an admin to add your GitHub username.",
		i18n.ZhCN: "{v} 不在本入口的名单上。请让管理员加上你的 GitHub 用户名。",
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
		i18n.EN:   "Issued to {login}, valid until {until}. Back in the terminal, fleet login writes the certificate for you.",
		i18n.ZhCN: "已签发给 {login}，{until} 前有效。回到终端，fleet login 会自动写好证书。",
	},
	"login.confirm.lead": {
		i18n.EN:   "Check that the code below matches the one in your terminal, then choose Confirm.",
		i18n.ZhCN: "确认终端上显示的验证码与下面一致，再点「确认签发」。",
	},
	"login.code":     {i18n.EN: "Code", i18n.ZhCN: "验证码"},
	"login.for":      {i18n.EN: "Issued to", i18n.ZhCN: "签给"},
	"login.account":  {i18n.EN: "system account", i18n.ZhCN: "系统账号"},
	"login.keyfp":    {i18n.EN: "Key fingerprint", i18n.ZhCN: "密钥指纹"},
	"login.validity": {i18n.EN: "Valid for 12 hours; scan again once it expires.", i18n.ZhCN: "有效期 12 小时，过期后再扫一次即可。"},
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
