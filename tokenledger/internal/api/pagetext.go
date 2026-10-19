package api

import "github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"

// pageText is every sentence the public pages say — /signin, the "can't use this hub" refusal and the /fleet/login
// confirmation — in both languages (claude-fleet#2023).
//
// The words follow the Chinese design page's glossary: 会话 / 执行会话 / 机器 / 设备 / 订阅 /
// 订阅池 / 余量 / 登录 / 管理员 / 使用者 / 凭据. Never translated: the product
// name, commands (fleet login), session keys, machine names, model ids.
//
// {v} in a key is a value the page bolds (tb in pagelang.go); {name} anywhere
// else is filled by the caller. pagelang_test.go fails a key missing either
// language and a template naming a key that is not here.
var pageText = map[string]i18n.Text{
	"lang.label": {i18n.EN: "Language", i18n.ZhCN: "语言"},

	// ── /signin ───────────────────────────────────────────────────────
	"signin.title":  {i18n.EN: "Sign in · claudefleet", i18n.ZhCN: "登录 · claudefleet"},
	"signin.h1":     {i18n.EN: "Sign in", i18n.ZhCN: "登录"},
	"signin.lead":   {i18n.EN: "Pick up your chats and sessions. Not on the list yet? Sign in with GitHub, then apply right there.", i18n.ZhCN: "继续你的对话和会话。还不在名单上的，用 GitHub 登录后可以当场申请。"},
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
		i18n.EN:   "Nobody has invited {v} to this hub yet.",
		i18n.ZhCN: "还没有人邀请你（{v}）。",
	},
	// The terminal's words for a person nobody named (claude-fleet#4050):
	// where to apply, in a browser.
	"deny.notlisted.cli": {
		i18n.EN:   "You're not on the list yet — open {url} in a browser to apply.",
		i18n.ZhCN: "还不在名单上，在浏览器打开 {url} 申请。",
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
