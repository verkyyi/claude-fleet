package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// A gateway "account" is one calling application, billed per call. It has no
// quota window, so the old answer — "no endpoint on this subscription has been
// able to read its account-wide limits" — blamed a collector gap that cannot
// exist: nothing was ever going to read a window that is not there.
//
// This matters beyond the dashboard, which filters these out of the wall card
// entirely (#50): /v1/limits and the MCP tool still answer for every account,
// and an agent reading "no endpoint could read it" would go looking for a
// broken collector.
func TestLimits_MeteredAccountSaysThereIsNoWindow(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "gw")
	h.push(t, tok, gatewayBatch("gateway:aicall", [2]string{"g1", "ark.cn-beijing.volces.com"}))

	_, body := h.get(t, "/v1/limits?account=gateway:aicall")
	var v LimitsView
	if err := json.Unmarshal(body, &v); err != nil {
		t.Fatal(err)
	}
	if v.Available {
		t.Fatal("a gateway caller has no quota reading to be available")
	}
	if !strings.Contains(v.Reason, "billed per call") {
		t.Errorf("reason = %q; want it to say the account has no window, not that nobody read one", v.Reason)
	}
	if strings.Contains(v.Reason, "no endpoint") {
		t.Errorf("reason = %q; that describes a collector gap, and there is no collector to gap", v.Reason)
	}
}

// The subscription case must not have moved: a Claude account whose endpoints
// genuinely failed to read its limits still reports exactly that.
func TestLimits_SubscriptionKeepsTheEndpointGapWording(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "a")
	h.push(t, tok, batchFor("acct-a", "a", []string{"a1"}, "/a"))

	_, body := h.get(t, "/v1/limits?account=acct-a")
	var v LimitsView
	if err := json.Unmarshal(body, &v); err != nil {
		t.Fatal(err)
	}
	if v.Available {
		t.Fatal("this fixture pushes no limits snapshot")
	}
	if !strings.Contains(v.Reason, "no endpoint") {
		t.Errorf("reason = %q; a subscription with no reading still has a window somebody failed to read", v.Reason)
	}
}

// The reason is restated in the viewer's language on the dashboard's own
// handler, like every other code. An English sentence in the middle of a
// Chinese card is the failure this pins.
func TestLimits_MeteredReasonIsTranslated(t *testing.T) {
	if got := LimitsReasonIn(ReasonMeteredNoWindow, "zh-CN"); !strings.Contains(got, "按调用计费") {
		t.Errorf("zh-CN reason = %q; want the Chinese wording", got)
	}
	if LimitsReasonIn(ReasonMeteredNoWindow, "en") == LimitsReasonIn(ReasonMeteredNoWindow, "zh-CN") {
		t.Error("the two locales returned the same string — one dictionary is missing the code")
	}
}

// Every source that has no quota window must reach the same code. A vendor
// invoice is not a caller, but it is just as windowless, and it used to say
// the same wrong thing.
func TestLimits_EveryWindowlessSourceGetsTheSameCode(t *testing.T) {
	for _, src := range model.Sources {
		if model.HasQuotaWindow(src) {
			continue
		}
		h := newHarness(t)
		tok := h.enroll(t, "ep-"+src)
		b := gatewayBatch("acct-"+src, [2]string{"m1", "vendor.example"})
		b.Identity.Source = src
		b.Events[0].Source = src
		h.push(t, tok, b)

		_, body := h.get(t, "/v1/limits?account=acct-"+src)
		var v LimitsView
		if err := json.Unmarshal(body, &v); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(v.Reason, "billed per call") {
			t.Errorf("%s: reason = %q; want the no-window wording", src, v.Reason)
		}
	}
}
