package api

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
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
