package pricing

import (
	"strings"
	"testing"

	"github.com/verkyyi/ccquota/internal/i18n"
	"github.com/verkyyi/ccquota/internal/model"
)

// Every translation's English entry must BE the exported constant, not a copy
// of it. A copy drifts: someone edits the constant, the tests that assert on it
// still pass, and the English shown to an English viewer silently becomes the
// stale duplicate this file holds.
func TestPriceNotes_EnglishIsTheConstant(t *testing.T) {
	for name, pair := range map[string]struct {
		text   i18n.Text
		const_ string
	}{
		"claude":      {claudeNote, ClaudePriceNote},
		"codex":       {openAINote, OpenAIPriceNote},
		"gateway":     {gatewayNote, GatewayPriceNote},
		"vendor_bill": {vendorBillNote, VendorBillPriceNote},
		"voice":       {voiceNote, VoicePriceNote},
		"mixed":       {mixedNote, MixedSourceNote},
		"unknown":     {unknownSourceNote, unknownSourceNoteEN},
	} {
		if pair.text[i18n.EN] != pair.const_ {
			t.Errorf("%s: the English entry has drifted from its constant", name)
		}
		zh := pair.text[i18n.ZhCN]
		if strings.TrimSpace(zh) == "" {
			t.Errorf("%s: no Chinese text", name)
		}
		if zh == pair.const_ {
			t.Errorf("%s: the Chinese entry is just the English text", name)
		}
	}
}

// Every source model.Sources knows must have a note in every language. A source
// added there with no translation would print an English paragraph mid-page --
// the same silent gap the dashboard's own SOURCE_LABEL guard exists to catch.
func TestNoteIn_EverySourceIsTranslated(t *testing.T) {
	for _, src := range model.Sources {
		en := NoteIn(src, i18n.EN)
		zh := NoteIn(src, i18n.ZhCN)
		if en == "" || zh == "" {
			t.Errorf("%s: empty note (en=%q zh=%q)", src, en, zh)
		}
		if en == zh {
			t.Errorf("%s: the Chinese note is the English one", src)
		}
		if en != Note(src) {
			t.Errorf("%s: NoteIn(en) disagrees with Note()", src)
		}
	}
	// An unfiltered scope is the mixed-source rule, in both languages.
	if NoteIn("", i18n.EN) != MixedSourceNote {
		t.Error(`NoteIn("", en) is not the mixed-source note`)
	}
	if NoteIn("", i18n.ZhCN) == MixedSourceNote {
		t.Error(`NoteIn("", zh-CN) was not translated`)
	}
}

// Only the prose travels. Source, kind and the rate-review date are a filter
// value, a classification and a date: a reader grepping for `gateway` or
// checking when rates were last reviewed needs the same token in any language.
func TestProvenanceIn_TranslatesOnlyTheNote(t *testing.T) {
	for _, src := range model.Sources {
		base, zh := ProvenanceFor(src), ProvenanceForIn(src, i18n.ZhCN)
		if zh.Source != base.Source || zh.Kind != base.Kind || zh.RatesAsOf != base.RatesAsOf {
			t.Errorf("%s: identifiers changed with the locale: %+v vs %+v", src, zh, base)
		}
		if zh.Note == base.Note {
			t.Errorf("%s: note was not translated", src)
		}
	}
	all := ProvenanceIn(i18n.ZhCN)
	if len(all) != len(model.Sources) {
		t.Fatalf("ProvenanceIn returned %d entries; want %d", len(all), len(model.Sources))
	}
}
