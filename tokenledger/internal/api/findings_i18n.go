package api

import (
	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/i18n"
)

// The findings the dashboard prints, in every language this build ships.
//
// A finding is a SENTENCE WITH DATA IN IT ("session a1b2 burned 4.1M tokens —
// 12× the median"), which is why it could not be translated the way a fixed
// note was: there is no constant to look up. findings.Finding now carries the
// template id and the values that went into it, so the sentence can be built
// again in another language instead of the English one being parsed back apart.
//
// The English entries here are not decoration. findings_i18n_test.go renders
// every finding this package can produce through the English template and
// asserts it reproduces Title/Detail byte for byte — so these cannot drift from
// what internal/findings actually emits, and an English viewer is guaranteed
// the same text as before this file existed.
var findingTitles = map[string]i18n.Text{
	findings.TmplRunawaySession: {
		i18n.EN:   "session {session} burned {tokens} tokens — {mult}× the median session",
		i18n.ZhCN: "会话 {session} 烧掉了 {tokens} token —— 是中位数会话的 {mult} 倍",
	},
	findings.TmplUnpricedModel: {
		i18n.EN:   "{model}: {n} requests have incomplete pricing",
		i18n.ZhCN: "{model}：有 {n} 次请求计价不完整",
	},
	findings.TmplTimeInCritical: {
		i18n.EN:   "{label} spent {duration} above 90% of its 5-hour window",
		i18n.ZhCN: "{label} 有 {duration} 处在 5 小时窗口的 90% 以上",
	},
	findings.TmplCacheHitDrop: {
		i18n.EN:   "cache hit on {project} fell {from} → {to}",
		i18n.ZhCN: "{project} 的缓存命中率从 {from} 掉到 {to}",
	},
	findings.TmplSpendSpikeTotal: {
		i18n.EN:   "tokens are {ratio}× the previous period",
		i18n.ZhCN: "token 用量是上一段时间的 {ratio} 倍",
	},
	findings.TmplSpendSpikeProject: {
		i18n.EN:   "{project} is {ratio}× its previous period and the top contributor",
		i18n.ZhCN: "{project} 是它上一段时间的 {ratio} 倍，也是涨得最多的那个",
	},
	findings.TmplWindowHigh: {
		i18n.EN:   "{label} is at {pct}% of its {window}",
		i18n.ZhCN: "{label} 已经用到它 {window} 的 {pct}%",
	},
	findings.TmplStaleAgentNever: {
		i18n.EN:   "{label} has never reported",
		i18n.ZhCN: "{label} 从未上报过",
	},
	findings.TmplStaleAgentLast: {
		i18n.EN:   "{label} last reported {ago} ago",
		i18n.ZhCN: "{label} 最后一次上报是在 {ago} 前",
	},
	findings.TmplLiveRunaway: {
		i18n.EN:   "live session {session} has {tokens} tokens in flight",
		i18n.ZhCN: "实时会话 {session} 有 {tokens} token 正在处理中",
	},
	findings.TmplFreeAllowanceGone: {
		i18n.EN:   "{model} has used its whole free monthly allowance ({used} of {allowance} tokens)",
		i18n.ZhCN: "{model} 已经用完了它整个月的免费额度（{allowance} token 里用了 {used}）",
	},
	findings.TmplFreeAllowanceNear: {
		i18n.EN:   "{model} is at {pct}% of its free monthly allowance ({used} of {allowance} tokens)",
		i18n.ZhCN: "{model} 已经用掉免费额度的 {pct}%（{allowance} token 里用了 {used}）",
	},
}

var findingDetails = map[string]i18n.Text{
	findings.TmplRunawaySession: {
		i18n.EN:   "{project} · {model} · {duration} · {turns} turns",
		i18n.ZhCN: "{project} · {model} · {duration} · {turns} 轮次",
	},
	findings.TmplUnpricedModel: {
		i18n.EN:   "A price or required usage metadata is missing. These requests are excluded from cost totals; their cost is unknown.",
		i18n.ZhCN: "缺价格，或者缺计价必需的用量元数据。这些请求不计入费用合计；它们的费用是未知，不是 0。",
	},
	findings.TmplTimeInCritical: {
		i18n.EN:   "{episodes} episode(s) · previous period {prev}",
		i18n.ZhCN: "{episodes} 次 · 上一段时间 {prev}",
	},
	findings.TmplCacheHitDrop: {
		i18n.EN:   "Turns there re-read context instead of hitting cache; each turn costs more than it did.",
		i18n.ZhCN: "那边的轮次在重读上下文而不是命中缓存；每一轮都比以前更贵。",
	},
	findings.TmplSpendSpikeTotal: {
		i18n.EN:   "{tokens} vs {prev}",
		i18n.ZhCN: "{tokens} 对比 {prev}",
	},
	findings.TmplSpendSpikeProject: {
		i18n.EN:   "{tokens} vs {prev}",
		i18n.ZhCN: "{tokens} 对比 {prev}",
	},
	findings.TmplStaleAgentNever: {
		i18n.EN:   "Its share of every total is under-counted until it returns.",
		i18n.ZhCN: "在它回来之前，它在每个合计里的那一份都是少算的。",
	},
	findings.TmplStaleAgentLast: {
		i18n.EN:   "Its share of every total is under-counted until it returns.",
		i18n.ZhCN: "在它回来之前，它在每个合计里的那一份都是少算的。",
	},
	findings.TmplLiveRunaway: {
		i18n.EN:   "{project}",
		i18n.ZhCN: "{project}",
	},
	findings.TmplFreeAllowanceGone: {
		i18n.EN: "Calls beyond the allowance are charged, and this build still reports them as free — " +
			"its cost for this model is a floor, not a bill. Set a rate for it in --pricing.",
		i18n.ZhCN: "超出额度的调用是要收钱的，而这个版本仍然把它们当免费报 —— " +
			"这个模型的费用是个下界，不是账单。在 --pricing 里给它配一个费率。",
	},
	findings.TmplFreeAllowanceNear: {
		i18n.EN:   "Past it the vendor charges, and this build would keep reporting the calls as free.",
		i18n.ZhCN: "过了这条线厂商就开始收费，而这个版本还会继续把这些调用当免费报。",
	},
	// TmplWindowHigh carries no detail; a missing entry renders as none.
}

// defaultWindow is the wording findings uses when a reading states no window of
// its own. The provider's OWN label is left alone — that is its wording, not
// ours to restate.
var defaultWindow = i18n.Text{i18n.EN: "5-hour window", i18n.ZhCN: "5 小时窗口"}

// localizeFinding re-renders one finding in `locale`.
//
// A finding with no template (one built before this existed, or by a caller
// outside this package) is returned untouched: showing the English sentence is
// right, and blanking it would be losing the alert entirely.
func localizeFinding(f findings.Finding, locale string) findings.Finding {
	if f.Template == "" {
		return f
	}
	args := f.Args
	if args["windowDefaulted"] == "true" {
		cp := make(map[string]string, len(args))
		for k, v := range args {
			cp[k] = v
		}
		cp["window"] = defaultWindow.In(locale)
		args = cp
	}
	if txt, ok := findingTitles[f.Template]; ok {
		f.Title = i18n.Interpolate(txt.In(locale), args)
	}
	if txt, ok := findingDetails[f.Template]; ok {
		f.Detail = i18n.Interpolate(txt.In(locale), args)
	}
	return f
}

// localizeFindings re-renders a list. Severity, Kind, Scope and Link are
// untouched: they are identifiers and the page acts on them.
func localizeFindings(fs []findings.Finding, locale string) []findings.Finding {
	out := make([]findings.Finding, len(fs))
	for i, f := range fs {
		out[i] = localizeFinding(f, locale)
	}
	return out
}
