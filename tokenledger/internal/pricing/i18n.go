package pricing

import "github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"

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
	mixedNote = i18n.Text{
		i18n.EN: MixedSourceNote,
		i18n.ZhCN: "当前范围跨了不止一个来源：Claude 和 Codex 的数字各按自己的公开 API 价折算，" +
			"都是订阅制工作的估算，分开报告。真实支出是订阅本身；折算出来的数字不属于它。",
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
	default:
		return unknownSourceNote.In(locale)
	}
}

// ProvenanceForIn is ProvenanceFor in a viewer's language.
//
// Only the NOTE is translated. Source, kind and rates-as-of are identifiers and
// a date: a reader filtering by `codex` or grepping a rate review date needs
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
