// internal/api/growth_text.go
package api

import "github.com/verkyyi/ccquota/internal/i18n"

// The board's prose, in the two languages this build ships.
//
// Chinese first in intent and English as the honest fallback — the reverse of
// the dashboard, and for the reason growthLocale gives: this page's readers are
// one named staff list and its vocabulary is that team's. Every entry still
// carries an EN string, because i18n.Text falls back to it and a blank where a
// revenue caveat belongs is the one outcome worse than the wrong language.
var growthText = map[string]i18n.Text{
	"title": {
		i18n.EN:   "Growth ledger",
		i18n.ZhCN: "经营台账",
	},
	"back": {
		i18n.EN:   "← the token ledger",
		i18n.ZhCN: "← 回 token 台账",
	},

	"empty.title": {
		i18n.EN:   "No day has been shipped yet",
		i18n.ZhCN: "还没有任何一天的数据",
	},
	"empty.hint": {
		i18n.EN: "POST a day to /v1/ingest/growth with this shipper's own enrollment token. " +
			"A day nobody ships stays missing: nothing here is back-filled, because a figure " +
			"the hub invented is one no query can reproduce.",
		i18n.ZhCN: "把一天的事实 POST 到 /v1/ingest/growth，带这条 shipper 自己的 enrollment token。" +
			"漏跑的那天就一直空着：这里不补跑，hub 自己编出来的数字没人能复算。",
	},

	"meta.day":      {i18n.EN: "Day", i18n.ZhCN: "数据日期"},
	"meta.source":   {i18n.EN: "Shipper", i18n.ZhCN: "来源"},
	"meta.received": {i18n.EN: "Received", i18n.ZhCN: "入库"},

	"h5.title": {
		i18n.EN:   "Subscriptions on the books",
		i18n.ZhCN: "在手订阅",
	},
	"h5.arr":              {i18n.EN: "ARR", i18n.ZhCN: "在手年费"},
	"h5.expiring":         {i18n.EN: "Expiring in window", i18n.ZhCN: "窗口内到期"},
	"h5.expiringAccounts": {i18n.EN: "Accounts expiring", i18n.ZhCN: "到期账号"},
	"h5.churned":          {i18n.EN: "Churned accounts", i18n.ZhCN: "已流失账号"},
	"h5.active":           {i18n.EN: "Active accounts", i18n.ZhCN: "活跃账号"},

	"ai.title": {
		i18n.EN:   "New AI business",
		i18n.ZhCN: "AI 新单",
	},
	"ai.hint": {
		i18n.EN: "Hand-filled: these deals live in conversations, not in a system, " +
			"so there is nothing to query and nobody to blame but the calendar.",
		i18n.ZhCN: "这半是人手填的：单子长在对话里，没有系统承载，取不到数。",
	},
	"ai.signed": {i18n.EN: "Signed deals", i18n.ZhCN: "已签约"},
	"ai.leads":  {i18n.EN: "Qualified leads", i18n.ZhCN: "合格商机"},
	"ai.arr":    {i18n.EN: "ARR", i18n.ZhCN: "年费"},
	"ai.updated": {
		i18n.EN:   "Last confirmed by a person at {when}.",
		i18n.ZhCN: "上次有人确认：{when}。",
	},

	// The staleness sentence. It REPLACES the three figures rather than
	// captioning them, which is the whole rule: a board that prints last
	// week's hand-filled number in today's slot lies more convincingly than a
	// board that prints nothing.
	"ai.stale": {
		i18n.EN:   "{days} days since the last update",
		i18n.ZhCN: "距上次更新 {days} 天",
	},
	"ai.staleWhy": {
		i18n.EN: "Nobody has confirmed these figures in more than {limit} days, " +
			"so they are not shown as today's.",
		i18n.ZhCN: "超过 {limit} 天没人更新，就不把旧数字当成今天的印在这里。",
	},
	"ai.lastFiled": {
		i18n.EN:   "Last filed ({when}): {signed} signed · {leads} qualified leads · {arr} ARR.",
		i18n.ZhCN: "上次填报（{when}）：签约 {signed} · 合格商机 {leads} · 年费 {arr}。",
	},

	"okr.title":   {i18n.EN: "The target these are read against", i18n.ZhCN: "对着哪个目标看"},
	"okr.focus":   {i18n.EN: "Focus this quarter", i18n.ZhCN: "本季聚焦"},
	"okr.quarter": {i18n.EN: "Quarter", i18n.ZhCN: "季度"},
	"okr.target":  {i18n.EN: "Target, annualized", i18n.ZhCN: "目标年化"},
	"okr.killSwitch": {
		i18n.EN:   "Kill switch",
		i18n.ZhCN: "距 kill switch",
	},
	"okr.killSwitch.left": {
		i18n.EN:   "{days} days",
		i18n.ZhCN: "{days} 天",
	},
	"okr.killSwitch.past": {
		i18n.EN:   "{days} days past",
		i18n.ZhCN: "已过 {days} 天",
	},
}

// gt reads one entry in a locale and fills its {placeholders}.
//
// Every string on this board goes through it, including the ones with no
// arguments, so a translator sees one convention rather than two — and so an
// added placeholder cannot quietly bypass interpolation at one call site.
func gt(key, locale string, args map[string]string) string {
	txt, ok := growthText[key]
	if !ok {
		// A missing key is a bug in this file, and it should look like one.
		// Returning the key beats returning "" — a blank slot on a board of
		// figures reads as a measured zero.
		return key
	}
	return i18n.Interpolate(txt.In(locale), args)
}
