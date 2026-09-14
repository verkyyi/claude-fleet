package api

import (
	"fmt"
	"net/http"

	"github.com/verkyyi/ccquota/internal/i18n"
	"github.com/verkyyi/ccquota/internal/store"
)

// The dashboard's server-side prose, in every language this build ships.
//
// Each English entry is the exported constant it translates, never a second
// copy: the constant stays the one definition (and the one thing the existing
// tests assert), and this file only adds languages to it.
var (
	realSpendNote = i18n.Text{
		i18n.EN: RealSpendNote,
		i18n.ZhCN: "真实支出 = 订阅发票 + 网关按量计费 + 那些网关根本看不到的路径的厂商账单" +
			"（视频生成、文件转写这类异步任务 API）。" +
			"按 token 折算的假想成本不在其中：订阅制下没有人按 token 被收费，" +
			"把那个数字加进来等于凭空造出一笔从未发生的支出。",
	}
	acrossNoteText = i18n.Text{
		i18n.EN: acrossNote,
		i18n.ZhCN: "利用率是每个订阅各自的，永远不相加：它们是独立的额度池，各自独立重置。" +
			"token 和假想成本才是可加的，也才可以跨订阅比较。",
	}
	shareDisclaimerText = i18n.Text{
		i18n.EN: shareDisclaimer,
		i18n.ZhCN: "账号级利用率是精确值，且已经覆盖了每一台设备。" +
			"按端点的分摊是按比例估算的。费用按来源分别报告，永远不跨来源相加：" +
			"Claude 和 Codex 的数字是按 API 价折算的等价估算，不是账单；网关的数字是真收的按次费用。" +
			"真实支出 = 订阅 + 网关。",
	}
	scopeNoteAll = i18n.Text{
		i18n.EN: "Totals span every subscription on this hub. Tokens and notional costs are " +
			"additive; rate-limit utilization is not and is reported per subscription.",
		i18n.ZhCN: "这些合计跨了本 hub 上的每一个订阅。token 和假想成本可以相加；" +
			"限流利用率不能，它按订阅分别报告。",
	}
	liveNoteText = i18n.Text{
		i18n.EN: liveNote,
		i18n.ZhCN: "来自 Claude 的 statusLine 心跳和 Codex 的日志观测。" +
			"Codex 那部分是「近期有活动」，不是持续在线的保证。" +
			"会话合计与持久账本是重叠的，永远不要把两者相加。",
	}
	accountUsageNote = i18n.Text{
		i18n.EN: accountUsageNoteEN,
		i18n.ZhCN: "服务端合计与本地归属明细是重叠的，不能相加。" +
			"历史上未归属的会话不计入本地账号数字。" +
			"日期边界、覆盖范围和更新延迟都还不可直接比较；两者有差不代表漏采，也不代表有云端用量。",
	}
)

// accountUsageNoteEN is the note /v1/account-usage carries. Lifted out of the
// handler so the translation above anchors on the same string rather than a
// second copy of it.
const accountUsageNoteEN = "Service totals and local attributed details overlap and must not be added. " +
	"Historical unassigned sessions are excluded from the local account figure. Date boundaries, coverage " +
	"and update delay are not yet comparable; a difference does not prove missing or cloud usage."

// localeOf is how every dashboard handler asks which language to answer in.
func localeOf(r *http.Request) string { return i18n.FromRequest(r) }

// RealSpendNoteIn is RealSpendNote in a viewer's language.
func RealSpendNoteIn(locale string) string { return realSpendNote.In(locale) }

// scopeNoteIn is scopeNote in a viewer's language. An account-scoped request
// still gets no note: there is nothing to warn about when the scope is one
// subscription.
func scopeNoteIn(account, locale string) string {
	if scopeNote(account) == "" {
		return ""
	}
	return scopeNoteAll.In(locale)
}

// Why a quota reading is unavailable, as codes rather than sentences.
const (
	ReasonCodexNoLimits     = "codex_no_limits"
	ReasonNoEndpointReading = "no_endpoint_reading"
	ReasonEndpointReports   = "endpoint_reports"
	ReasonWrongSource       = "wrong_source"
	ReasonCodexUnassigned   = "codex_unassigned"
	ReasonCodexUnverified   = "codex_unverified"
	ReasonCodexStale        = "codex_stale"
	ReasonCodexWindowReset  = "codex_window_reset"
)

var limitsReasons = map[string]i18n.Text{
	ReasonCodexNoLimits: {
		i18n.EN:   "Codex local usage reports token consumption only; subscription limits are not collected",
		i18n.ZhCN: "Codex 的本地用量只上报 token 消耗，不采集订阅额度",
	},
	ReasonNoEndpointReading: {
		i18n.EN:   "no endpoint on this subscription has been able to read its account-wide limits",
		i18n.ZhCN: "这个订阅下没有任何端点能读到它的账号级额度",
	},
	ReasonWrongSource: {
		i18n.EN:   "account does not belong to the selected source",
		i18n.ZhCN: "这个账号不属于当前选中的来源",
	},
	ReasonCodexUnassigned: {
		i18n.EN:   "Historical or unassigned Codex usage; select a linked Codex account to view its quota",
		i18n.ZhCN: "历史的或未归属的 Codex 用量；选一个已关联的 Codex 账号才能看到它的额度",
	},
	ReasonCodexUnverified: {
		i18n.EN:   "No verified Codex quota reading; local usage history is retained separately",
		i18n.ZhCN: "没有已核实的 Codex 额度读数；本地用量历史是单独保留的",
	},
	ReasonCodexStale: {
		i18n.EN:   "Codex quota reading is stale; waiting for a fresh observation",
		i18n.ZhCN: "Codex 的额度读数已过期，正在等新的观测",
	},
	ReasonCodexWindowReset: {
		i18n.EN:   "Codex quota window reset; waiting for a fresh reading",
		i18n.ZhCN: "Codex 的额度窗口已重置，正在等新的读数",
	},
}

// endpointReportsFrame wraps an endpoint's own words. The words themselves are
// never touched: an agent said them, and rewriting them would be putting a
// sentence in its mouth that it did not report.
var endpointReportsFrame = i18n.Text{
	i18n.EN:   "%s reports: %s",
	i18n.ZhCN: "%s 报告：%s",
}

func endpointReports(endpoint, reason, locale string) string {
	return fmt.Sprintf(endpointReportsFrame.In(locale), endpoint, reason)
}

// LimitsReasonIn names one unavailability code in a viewer's language. An
// unknown code returns "" rather than inventing an explanation — an empty
// reason renders as the card's plain "no reading available", which is true.
func LimitsReasonIn(code, locale string) string {
	if txt, ok := limitsReasons[code]; ok {
		return txt.In(locale)
	}
	return ""
}

// localizeLimits restates a reading's reason in the viewer's language. Called
// only from the dashboard's own handlers: LimitsFor and friends stay English
// for internal/mcp, whose consumer is an agent.
func localizeLimits(v *LimitsView, locale string) {
	if v == nil {
		return
	}
	v.Disclaimer = shareDisclaimerText.In(locale)
	switch {
	case v.ReasonCode == ReasonEndpointReports:
		v.Reason = endpointReports(v.ReasonEndpoint, v.ReasonDetail, locale)
	case v.ReasonCode != "":
		v.Reason = LimitsReasonIn(v.ReasonCode, locale)
	}
}

// localizedReasons restates each unpriced-reason row in the viewer's language,
// leaving source and model — identifiers — exactly as they are.
func localizedReasons(rows []store.UnpricedReason, locale string) []store.UnpricedReason {
	out := make([]store.UnpricedReason, len(rows))
	for i, r := range rows {
		r.Reason = store.UnpricedReasonIn(r.Code, locale)
		out[i] = r
	}
	return out
}

// fxNote is what every converted figure has to say for itself.
//
// It is the counterpart of pricing.GatewayPriceNote: that one says a gateway
// figure IS the charge, this one says a converted figure is NOT. Both exist
// because the number alone cannot tell a reader which it is looking at.
var fxNote = i18n.Text{
	i18n.EN: "Converted for display only. The ledger keeps every figure in the currency it was " +
		"billed in, and no total is computed through this rate — a converted amount is an " +
		"approximation of an invoice, never the invoice.",
	i18n.ZhCN: "仅为显示而折算。账本里每个数字都保留它被计费时的币种，" +
		"也没有任何合计是经由这个汇率算出来的 —— 折算出来的金额是对账单的近似，永远不是账单本身。",
}
