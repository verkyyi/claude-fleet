package pricing

import (
	"strings"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// Every source this build knows must have a stated basis and a review date.
// A figure with neither is a figure nobody can check, and a wrong note is
// worse than none: it tells the reader the number is something it is not.
func TestEverySourceHasAStatedBasis(t *testing.T) {
	for _, s := range model.Sources {
		p := ProvenanceFor(s)
		if p.Source != s {
			t.Errorf("%s: provenance is for %q", s, p.Source)
		}
		if p.Kind != model.CostKind(s) || p.Kind == model.CostUnknown {
			t.Errorf("%s: kind = %q, want %q", s, p.Kind, model.CostKind(s))
		}
		if p.RatesAsOf == "" {
			t.Errorf("%s: no rates_as_of — a stale rate is a reporting bug and this is what exposes it", s)
		}
		if p.Note == "" {
			t.Errorf("%s: no note", s)
		}
	}
}

// The bug this replaced: "anything that is not Claude" got the Codex note, so
// a gateway figure — an actual per-call charge — was described as an
// API-equivalent estimate, and an unfiltered scope was described as one
// source's basis when it has none (issue #4).
func TestNoteDoesNotMisdescribeASource(t *testing.T) {
	if got := Note(model.SourceGateway); got != GatewayPriceNote {
		t.Errorf("gateway note = %q", got)
	}
	if strings.Contains(Note(model.SourceGateway), "API equivalent") {
		t.Error("the gateway note calls a real charge an API equivalent")
	}
	if got := Note(model.SourceCodex); got != OpenAIPriceNote {
		t.Errorf("codex note = %q", got)
	}
	if got := Note(model.SourceClaude); got != ClaudePriceNote {
		t.Errorf("claude note = %q", got)
	}
	if got := Note(""); got != MixedSourceNote {
		t.Errorf("unfiltered note = %q, want the mixed-source note", got)
	}

	// A billed source's note has to say so in a word a reader cannot miss,
	// and a notional one has to disclaim the invoice reading.
	if !strings.Contains(GatewayPriceNote, "billed per call") {
		t.Error("the gateway note does not say it is billed")
	}
	for _, n := range []string{ClaudePriceNote, OpenAIPriceNote} {
		if !strings.Contains(n, "API equivalent") {
			t.Errorf("a notional note does not say what the figure is: %q", n)
		}
	}
	if !strings.Contains(MixedSourceNote, "never added") {
		t.Error("the mixed-source note does not state the rule")
	}
}

// Unfiltered means every source, filtered means exactly one. A surface that
// asked for provenance and got the wrong count would label its columns wrong.
func TestProvenanceCountMatchesTheScope(t *testing.T) {
	if got := Provenance(""); len(got) != len(model.Sources) {
		t.Errorf("unfiltered provenance has %d entries, want %d", len(got), len(model.Sources))
	}
	if got := Provenance(); len(got) != len(model.Sources) {
		t.Errorf("no-arg provenance has %d entries, want %d", len(got), len(model.Sources))
	}
	if got := Provenance(model.SourceGateway); len(got) != 1 || got[0].Source != model.SourceGateway {
		t.Errorf("filtered provenance = %+v", got)
	}
}

// An unrecognised source is described as unrecognised rather than given a
// borrowed rate date, which would make an unreviewed figure look reviewed.
func TestUnknownSourceGetsNoBorrowedBasis(t *testing.T) {
	p := ProvenanceFor("some-future-thing")
	if p.Kind != model.CostUnknown {
		t.Errorf("kind = %q, want unknown", p.Kind)
	}
	if p.RatesAsOf != "" {
		t.Errorf("rates_as_of = %q, want empty: nobody has reviewed rates for it", p.RatesAsOf)
	}
	if !strings.Contains(p.Note, "no rate table") {
		t.Errorf("note = %q, want it to say the basis is missing", p.Note)
	}
}
