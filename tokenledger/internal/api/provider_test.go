package api

import (
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

func gatewayBatch(account string, rows ...[2]string) model.Batch {
	b := model.Batch{Identity: model.Identity{
		AccountUUID: account, Source: model.SourceGateway, DisplayName: "AI 网关",
		Hostname: "gw", OS: "linux", Arch: "amd64", MachineID: "gw1",
	}}
	for i, r := range rows {
		b.Events = append(b.Events, model.UsageEvent{
			Source: model.SourceGateway, AccountUUID: account, MessageUUID: r[0],
			TS:    time.Now().UTC().Add(-time.Duration(i+1) * time.Minute),
			Model: "deepseek-v4-flash", OutputTokens: 10,
			Details: &model.UsageDetails{Provider: r[1], BillingMode: "metered"},
		})
	}
	return b
}

func TestUsage_ByProvider(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "gw")
	h.push(t, tok, gatewayBatch("gateway:aicall",
		[2]string{"a1", "ark.cn-beijing.volces.com"},
		[2]string{"a2", "dashscope.aliyuncs.com"},
		[2]string{"a3", "ark.cn-beijing.volces.com"}))

	var got struct {
		Buckets []struct {
			Key    string `json:"key"`
			Events int64  `json:"events"`
		} `json:"buckets"`
	}
	h.getJSON(t, "/v1/usage?by=provider&since=1d&account=all", &got)
	if len(got.Buckets) != 2 {
		t.Fatalf("buckets = %+v; want two providers", got.Buckets)
	}
	if got.Buckets[0].Key != "ark.cn-beijing.volces.com" || got.Buckets[0].Events != 2 {
		t.Errorf("top bucket = %+v; want ark with 2 events", got.Buckets[0])
	}
}

func TestUsage_ProviderFilterNarrows(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "gw")
	h.push(t, tok, gatewayBatch("gateway:aicall",
		[2]string{"b1", "ark.cn-beijing.volces.com"},
		[2]string{"b2", "dashscope.aliyuncs.com"}))

	var got struct {
		Events int64 `json:"events"`
	}
	h.getJSON(t, "/v1/summary?provider=dashscope.aliyuncs.com&since=1d&account=all", &got)
	if got.Events != 1 {
		t.Errorf("events = %d, want 1", got.Events)
	}
}

// An empty bucket has two causes and neither is a vendor. The response says so
// rather than leaving a blank row for the reader to interpret.
func TestUsage_EmptyProviderCarriesTheNote(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "cc")
	h.push(t, tok, model.Batch{
		Identity: model.Identity{AccountUUID: "acct", Hostname: "h", OS: "linux", Arch: "amd64", MachineID: "m"},
		Events: []model.UsageEvent{{
			AccountUUID: "acct", MessageUUID: "c1", TS: time.Now().UTC().Add(-time.Minute),
			Model: "claude-sonnet-5", OutputTokens: 10,
		}},
	})

	var got struct {
		ProviderNote string `json:"provider_note"`
	}
	h.getJSON(t, "/v1/usage?by=provider&since=1d&account=all", &got)
	if got.ProviderNote == "" {
		t.Error("a response with an empty provider bucket must explain it")
	}
}

// A scope with no blank bucket has nothing to explain and must not carry a
// note that would read as a caveat on figures that have none.
func TestUsage_NoNoteWhenEveryBucketDeclaresAProvider(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "gw")
	h.push(t, tok, gatewayBatch("gateway:aicall", [2]string{"d1", "ark.cn-beijing.volces.com"}))

	var got struct {
		ProviderNote string `json:"provider_note"`
	}
	h.getJSON(t, "/v1/usage?by=provider&since=1d&account=all", &got)
	if got.ProviderNote != "" {
		t.Errorf("unexpected note %q", got.ProviderNote)
	}
}

// labelled gives the harness a --pricing table that names some upstreams, which
// is the only place an upstream's display name can come from.
func labelled(t *testing.T, h *harness) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "pricing.json")
	if err := os.WriteFile(p, []byte(
		`{"gateway": {"providers": {"ark.cn-beijing.volces.com": {"label": "火山方舟"}}}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	tbl := pricing.Default()
	if err := tbl.LoadOverrides(p); err != nil {
		t.Fatal(err)
	}
	h.srv.Pricing = tbl
}

// The store cannot name an upstream -- it has no edge to internal/pricing and
// leaves Label empty in this dimension. The api layer, which already holds the
// table, is where the two meet; before this the mechanism had no caller at all
// and every provider row rendered as a bare hostname.
func TestUsage_ByProvider_CarriesTheOperatorsLabel(t *testing.T) {
	h := newHarness(t)
	labelled(t, h)
	tok := h.enroll(t, "gw")
	h.push(t, tok, gatewayBatch("gateway:aicall",
		[2]string{"L1", "ark.cn-beijing.volces.com"},
		[2]string{"L2", "dashscope.aliyuncs.com"}))

	var got struct {
		Buckets []struct {
			Key   string `json:"key"`
			Label string `json:"label"`
		} `json:"buckets"`
	}
	h.getJSON(t, "/v1/usage?by=provider&since=1d&account=all", &got)

	want := map[string]string{
		"ark.cn-beijing.volces.com": "火山方舟",
		// Named by nobody, so named by nothing: the caller falls back to the
		// key. A hub that invented a label here would be publishing a guess
		// about whose money this is.
		"dashscope.aliyuncs.com": "",
	}
	if len(got.Buckets) != len(want) {
		t.Fatalf("buckets = %+v; want %d", got.Buckets, len(want))
	}
	for _, b := range got.Buckets {
		w, ok := want[b.Key]
		if !ok {
			t.Errorf("unexpected bucket %q", b.Key)
			continue
		}
		if b.Label != w {
			t.Errorf("%s label = %q, want %q", b.Key, b.Label, w)
		}
	}
}

// The empty provider is not a vendor, so it has no name to carry -- and
// --pricing refuses to give it one. A labelled table must leave it blank and
// let provider_note do the explaining.
func TestUsage_ByProvider_EmptyProviderStaysUnlabelled(t *testing.T) {
	h := newHarness(t)
	labelled(t, h)
	tok := h.enroll(t, "cc")
	h.push(t, tok, model.Batch{
		Identity: model.Identity{AccountUUID: "acct", Hostname: "h", OS: "linux", Arch: "amd64", MachineID: "m"},
		Events: []model.UsageEvent{{
			AccountUUID: "acct", MessageUUID: "e1", TS: time.Now().UTC().Add(-time.Minute),
			Model: "claude-sonnet-5", OutputTokens: 10,
		}},
	})

	var got struct {
		Buckets []struct {
			Key   string `json:"key"`
			Label string `json:"label"`
		} `json:"buckets"`
		ProviderNote string `json:"provider_note"`
	}
	h.getJSON(t, "/v1/usage?by=provider&since=1d&account=all", &got)
	if len(got.Buckets) != 1 || got.Buckets[0].Key != "" {
		t.Fatalf("buckets = %+v; want one blank bucket", got.Buckets)
	}
	if got.Buckets[0].Label != "" {
		t.Errorf("blank provider got label %q; it is not a vendor", got.Buckets[0].Label)
	}
	if got.ProviderNote == "" {
		t.Error("the blank bucket is still explained by the note, not by a label")
	}
}

// The reported bug (issue #134), at the layer it was reported from: the
// dashboard expands the "declares no upstream" row by asking for that row's
// own key. A blank key reached `where` as "no constraint", so the drill-down
// answered with every upstream on the hub -- the one reading that must never
// come back from a row the reader clicked to NARROW.
func TestUsage_DrillIntoUndeclaredReturnsOnlyUndeclaredModels(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "mixed")
	// Two upstreams that declare themselves...
	h.push(t, tok, gatewayBatch("gateway:aicall",
		[2]string{"u1", "ark.cn-beijing.volces.com"},
		[2]string{"u2", "dashscope.aliyuncs.com"}))
	// ...and one Claude transcript, which declares none. gatewayBatch's events
	// all run "deepseek-v4-flash", so a leak is visible by model id alone.
	h.push(t, tok, model.Batch{
		Identity: model.Identity{AccountUUID: "acct", Hostname: "h", OS: "linux", Arch: "amd64", MachineID: "m"},
		Events: []model.UsageEvent{{
			AccountUUID: "acct", MessageUUID: "u3", TS: time.Now().UTC().Add(-time.Minute),
			Model: "claude-sonnet-5", OutputTokens: 10,
		}},
	})

	var got struct {
		Buckets []struct {
			Key    string `json:"key"`
			Events int64  `json:"events"`
		} `json:"buckets"`
	}
	h.getJSON(t, "/v1/usage?by=model&provider="+url.QueryEscape(store.Undeclared)+"&since=1d&account=all", &got)

	if len(got.Buckets) != 1 {
		t.Fatalf("buckets = %+v; want only the models with no declared upstream", got.Buckets)
	}
	if got.Buckets[0].Key != "claude-sonnet-5" || got.Buckets[0].Events != 1 {
		t.Errorf("bucket = %+v; want claude-sonnet-5 with 1 event", got.Buckets[0])
	}
}

// The other half of the same distinction, and the reason the sentinel had to
// be a new value rather than a reinterpretation of "": an omitted chip still
// places no constraint. Regressing this would silently narrow every unscoped
// read on the hub.
func TestUsage_OmittedProviderStillSpansEveryUpstream(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "mixed")
	h.push(t, tok, gatewayBatch("gateway:aicall",
		[2]string{"o1", "ark.cn-beijing.volces.com"},
		[2]string{"o2", "dashscope.aliyuncs.com"}))
	h.push(t, tok, model.Batch{
		Identity: model.Identity{AccountUUID: "acct", Hostname: "h", OS: "linux", Arch: "amd64", MachineID: "m"},
		Events: []model.UsageEvent{{
			AccountUUID: "acct", MessageUUID: "o3", TS: time.Now().UTC().Add(-time.Minute),
			Model: "claude-sonnet-5", OutputTokens: 10,
		}},
	})

	for _, qs := range []string{"", "&provider="} {
		var got struct {
			Events int64 `json:"events"`
		}
		h.getJSON(t, "/v1/summary?since=1d&account=all"+qs, &got)
		if got.Events != 3 {
			t.Errorf("provider%q: events = %d, want all 3", qs, got.Events)
		}
	}
}
