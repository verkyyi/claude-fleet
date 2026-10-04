package pricing

import "github.com/verkyyi/ccquota/internal/i18n"

// The price notes in every language this build ships.
//
// The English entry is not a copy: it IS the exported constant above each one,
// so the two can never drift — the constant stays the single definition, and
// this file only adds languages to it. pricing_i18n_test.go pins that.
//
// These notes are the most load-bearing prose in the product: each one says
// which KIND of money a figure is, and reading a Claude estimate as an invoice
// is the exact error the whole cost model exists to prevent. So the Chinese is
// a translation of the CLAIM, not of the sentence shape.
var (
	claudeNote = i18n.Text{
		i18n.EN: ClaudePriceNote,
		i18n.ZhCN: "Claude：按 " + RatesAsOf + " 的公开 API 价折算的等价成本。" +
			"Pro / Max 订阅不按 token 计费，所以这是「同样的活儿按 API 价会花多少钱」——" +
			"用来给端点和项目排序有意义，当成账单读就会错。" +
			"订阅本身才是真金白银，它单独统计；两者永远不要相加。",
	}
	openAINote = i18n.Text{
		i18n.EN: OpenAIPriceNote,
		i18n.ZhCN: "Codex：按 2026-09-07 的公开 API 价折算的等价成本，含历史价格重估。" +
			"缺服务档位的按 Standard 计。订阅账单与额度包是另一回事；" +
			"厂商、模型或缓存写入拆不出来的部分保持未计价。",
	}
	gatewayNote = i18n.Text{
		i18n.EN: GatewayPriceNote,
		i18n.ZhCN: "网关：按次计费 —— 这个数字是真实发生的费用，不是其他来源那种按 API 价折算的估算。" +
			"费率是本部署自己的，在 --pricing 覆盖文件里以人民币记录，再按一个钉死的、人工复核过的汇率换成美元；" +
			"每条事件的计价依据里都带着当时用的费率和它的生效日期。" +
			"永远不要把网关的合计加到 Claude 或 Codex 的合计上：它们是两种不同的钱。",
	}
	vendorBillNote = i18n.Text{
		i18n.EN: VendorBillPriceNote,
		i18n.ZhCN: "厂商账单：从厂商发票上读来的，不是从请求里计量出来的。" +
			"这个数字是那些根本不经过本部署网关的消耗被实际收取的金额" +
			"（异步任务类 API —— 视频生成、文件转写 —— 会直接回一个厂商签名的结果 URL，" +
			"并要求输入可公开访问，所以那条数据通路上什么都不经过我们）。" +
			"发票行没有调用方，因此这些行没有按应用的归属，也没有 token 计数；计费单位是秒、张或次。" +
			"可以和网关合计相加（都是真收的钱）；但任何一个都不要加到 Claude 或 Codex 的数字上。",
	}
	voiceNote = i18n.Text{
		i18n.EN: VoicePriceNote,
		i18n.ZhCN: "语音：应用自己上报的模型调用用量 —— 实时语音识别与流式合成，" +
			"它们以 WebSocket 帧的形式传输，绕过了本部署能计量的一切。" +
			"这些行存在的意义是让那部分用量可见、可归属（租户、会话、听了多少秒、说了多少字）；" +
			"厂商发票给不了这些 —— 本部署实测时，agent 明明在跑，它报的语音识别时长却是 0 秒。" +
			"钱是发票的事：这里的行除非有采集器给了费用，否则就是未计价；" +
			"而任何在这里计了价的计费项，都必须从账单采集器的纳入清单里排除，" +
			"否则同一笔钱会被算两次。可以和网关或厂商账单合计相加（三者都是真收的钱）；" +
			"但它们中的任何一个都不要加到 Claude 或 Codex 的数字上。",
	}
	mixedNote = i18n.Text{
		i18n.EN: MixedSourceNote,
		i18n.ZhCN: "当前范围跨了不止一个来源，而 cost_usd 在每个来源里的含义都不一样：" +
			"Claude 和 Codex 的数字是订阅制工作按 API 价折算的估算，网关的数字是真收的按次费用。" +
			"它们分开报告，永远不相加。真实支出 = 订阅 + 网关；假想的那个数字不属于它。",
	}
	unknownSourceNote = i18n.Text{
		i18n.EN:   unknownSourceNoteEN,
		i18n.ZhCN: "无法识别的来源：本版本没有它的费率表，所以它的费用数字没有可陈述的依据，不计入任何合计。",
	}
)

// unknownSourceNoteEN is the default branch of ProvenanceFor, lifted out of the
// switch so the translation above can anchor on the same string the English
// path returns rather than a second copy of it.
const unknownSourceNoteEN = "Unrecognised source: this build has no rate table for it, so its cost figure " +
	"has no stated basis and belongs in no total."

// noteFor is the locale-aware twin of the note each source carries.
func noteFor(source string, locale string) string {
	switch source {
	case "claude":
		return claudeNote.In(locale)
	case "codex":
		return openAINote.In(locale)
	case "gateway":
		return gatewayNote.In(locale)
	case "vendor_bill":
		return vendorBillNote.In(locale)
	case "voice":
		return voiceNote.In(locale)
	default:
		return unknownSourceNote.In(locale)
	}
}

// ProvenanceForIn is ProvenanceFor in a viewer's language.
//
// Only the NOTE is translated. Source, kind and rates-as-of are identifiers and
// a date: a reader filtering by `gateway` or grepping a rate review date needs
// the same token whatever language the sentence beside it is in.
func ProvenanceForIn(source, locale string) SourceProvenance {
	p := ProvenanceFor(source)
	p.Note = noteFor(p.Source, locale)
	return p
}

// ProvenanceIn is Provenance in a viewer's language.
func ProvenanceIn(locale string, sources ...string) []SourceProvenance {
	out := Provenance(sources...)
	for i := range out {
		out[i].Note = noteFor(out[i].Source, locale)
	}
	return out
}

// NoteIn is Note in a viewer's language.
func NoteIn(source, locale string) string {
	if source == "" {
		return mixedNote.In(locale)
	}
	return ProvenanceForIn(source, locale).Note
}
