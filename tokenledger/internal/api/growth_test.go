package api

import (
	"bytes"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// c2Template is the frozen shipper contract, verbatim.
//
// Two fields are parameters rather than literals, and only two: `day` and
// `ai.updated_at` are the fields this hub reads against a clock, so hardcoding
// them would make the whole suite quietly change meaning as the calendar moved
// past them. Every figure below is the contract's own, which is what makes the
// board assertions mean something.
const c2Template = `{
  "source": "growth-facts",
  "day": %q,
  "h5": { "arr_cny": 303600, "expiring_in_window_cny": 282000,
          "expiring_accounts": 52, "churned_accounts": 6, "active_accounts": 76 },
  "ai": { "signed_deals": 0, "qualified_leads": 0, "arr_cny": 0,
          "updated_at": %q },
  "okr": { "focus": "wechat_agent", "quarter": "2026Q4-首单",
           "target_annualized": 420000, "days_to_kill_switch": 76 }
}`

func c2(day string, aiUpdated time.Time) []byte {
	return []byte(fmt.Sprintf(c2Template, day, aiUpdated.UTC().Format(time.RFC3339)))
}

func today() string { return time.Now().UTC().Format(model.GrowthDayLayout) }

func (h *harness) pushGrowth(t *testing.T, token string, body []byte) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/ingest/growth", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// seedGrowth ships one day through the real ingest path — the house rule:
// tests exercise the endpoint, not the store behind it.
func seedGrowth(t *testing.T, h *harness, body []byte) {
	t.Helper()
	tok := h.tokens["growth"]
	if tok == "" {
		tok = h.enroll(t, "growth")
	}
	resp := h.pushGrowth(t, tok, body)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		buf := new(bytes.Buffer)
		buf.ReadFrom(resp.Body)
		t.Fatalf("seed growth: %d %s", resp.StatusCode, buf.String())
	}
}

// ① no token and ② the wrong token are both 401, and the viewer token — which
// opens the dashboard — must not open a write path.
func TestGrowthIngest_RequiresAnEnrollmentToken(t *testing.T) {
	h := newHarness(t)
	body := c2(today(), time.Now().Add(-time.Hour))
	for name, tok := range map[string]string{"none": "", "garbage": "ccq_not-a-token"} {
		resp := h.pushGrowth(t, tok, body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s token: %d, want 401", name, resp.StatusCode)
		}
	}
	resp := h.pushGrowth(t, viewerToken, body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("viewer token was accepted for growth ingest: %d", resp.StatusCode)
	}
}

// ③ a legal body lands, and the board prints it: ¥303,600 on the books and the
// 52 accounts that renew in the window.
func TestGrowthIngest_StoresAndTheBoardShowsIt(t *testing.T) {
	h := newHarness(t)
	seedGrowth(t, h, c2(today(), time.Now().Add(-time.Hour)))

	resp, body := h.get(t, "/growth")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /growth: %d", resp.StatusCode)
	}
	page := string(body)
	for _, want := range []string{"303,600", "52"} {
		if !strings.Contains(page, want) {
			t.Errorf("the board does not carry %q", want)
		}
	}
	// The rest of the contract, so a page that happened to contain those two
	// substrings somewhere else could not pass.
	for _, want := range []string{"282,000", "76", "wechat_agent", "2026Q4-首单", "420,000"} {
		if !strings.Contains(page, want) {
			t.Errorf("the board does not carry %q", want)
		}
	}
	// Money is money: a bare 303600 on a board of yuan is a different claim.
	if strings.Contains(page, ">303600<") {
		t.Error("a figure was printed ungrouped")
	}
}

// ④ the same (source, day) pushed twice is ONE row. Everything in this ledger
// is a level, so a second push must replace the day rather than add to it.
func TestGrowthIngest_SameDayTwiceIsOneRow(t *testing.T) {
	h := newHarness(t)
	day := today()
	seedGrowth(t, h, c2(day, time.Now().Add(-time.Hour)))
	seedGrowth(t, h, c2(day, time.Now().Add(-time.Hour)))

	var rows int
	if err := h.srv.Store.DB().QueryRow(
		`SELECT COUNT(*) FROM growth_facts WHERE source = 'growth-facts' AND day = ?`, day,
	).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("growth_facts holds %d rows for one (source, day); want exactly 1", rows)
	}
}

// A correction for a day already shipped replaces the whole document. The
// alternative — merging field by field — would let a figure that dropped out
// of the shipper's query keep its old value under a fresh date.
func TestGrowthIngest_ASecondPushReplacesTheDay(t *testing.T) {
	h := newHarness(t)
	day := today()
	seedGrowth(t, h, c2(day, time.Now().Add(-time.Hour)))
	seedGrowth(t, h, []byte(fmt.Sprintf(`{
	  "source": "growth-facts", "day": %q,
	  "h5": { "arr_cny": 311000, "expiring_in_window_cny": 0,
	          "expiring_accounts": 0, "churned_accounts": 7, "active_accounts": 80 },
	  "ai": { "signed_deals": 1, "qualified_leads": 3, "arr_cny": 96000, "updated_at": %q },
	  "okr": { "focus": "wechat_agent", "quarter": "2026Q4-首单",
	           "target_annualized": 420000, "days_to_kill_switch": 75 }
	}`, day, time.Now().Add(-time.Hour).UTC().Format(time.RFC3339))))

	_, body := h.get(t, "/growth")
	page := string(body)
	if !strings.Contains(page, "311,000") {
		t.Error("the board is not showing the corrected figure")
	}
	if strings.Contains(page, "303,600") {
		t.Error("the superseded figure is still on the board: the upsert merged instead of replacing")
	}
}

// ⑤ the hand-filled half goes stale, and the board says so INSTEAD of printing
// the old figures as today's. This is the criterion the whole feature turns
// on: the AI deals are typed in by a person, and a board that shows last
// week's number in today's slot lies more convincingly than an empty one.
func TestGrowthBoard_StaleAIHalfIsNotPrintedAsToday(t *testing.T) {
	h := newHarness(t)
	seedGrowth(t, h, []byte(fmt.Sprintf(`{
	  "source": "growth-facts", "day": %q,
	  "h5": { "arr_cny": 303600, "expiring_in_window_cny": 282000,
	          "expiring_accounts": 52, "churned_accounts": 6, "active_accounts": 76 },
	  "ai": { "signed_deals": 4, "qualified_leads": 9, "arr_cny": 512000, "updated_at": %q },
	  "okr": { "focus": "wechat_agent", "quarter": "2026Q4-首单",
	           "target_annualized": 420000, "days_to_kill_switch": 76 }
	}`, today(), time.Now().AddDate(0, 0, -5).UTC().Format(time.RFC3339))))

	_, body := h.get(t, "/growth")
	page := string(body)
	if !strings.Contains(page, "距上次更新 5 天") {
		t.Errorf("the board does not say how stale the hand-filled half is:\n%s", page)
	}
	// The figures may still appear as a dated FILING -- that is not a lie --
	// but never in a value slot, which is what `<div class="v">` is.
	for _, n := range []string{"4", "9", "512,000"} {
		if strings.Contains(page, `<div class="v">`+n+`</div>`) {
			t.Errorf("stale figure %q is printed as a current value", n)
		}
	}
	// The measured half is unaffected: it came off a database tonight.
	if !strings.Contains(page, "303,600") {
		t.Error("the stale AI half took the measured H5 half down with it")
	}

	// A person who updated an hour ago gets the figures back, in the slots.
	h2 := newHarness(t)
	seedGrowth(t, h2, []byte(fmt.Sprintf(`{
	  "source": "growth-facts", "day": %q,
	  "h5": { "arr_cny": 303600, "expiring_in_window_cny": 282000,
	          "expiring_accounts": 52, "churned_accounts": 6, "active_accounts": 76 },
	  "ai": { "signed_deals": 4, "qualified_leads": 9, "arr_cny": 512000, "updated_at": %q },
	  "okr": { "focus": "wechat_agent", "quarter": "2026Q4-首单",
	           "target_annualized": 420000, "days_to_kill_switch": 76 }
	}`, today(), time.Now().Add(-time.Hour).UTC().Format(time.RFC3339))))
	_, fresh := h2.get(t, "/growth")
	if !strings.Contains(string(fresh), `<div class="v">512,000`) &&
		!strings.Contains(string(fresh), `<div class="v">¥512,000`) {
		t.Errorf("a freshly confirmed figure is not on the board:\n%s", fresh)
	}
	if strings.Contains(string(fresh), "距上次更新") {
		t.Error("an hour-old filing was reported as stale")
	}
}

// The board is the most sensitive surface this binary serves. No credential is
// a 401 -- not a redirect, which would hide the real reason.
func TestGrowthBoard_RequiresViewerCredentials(t *testing.T) {
	h := newHarness(t)
	seedGrowth(t, h, c2(today(), time.Now().Add(-time.Hour)))
	for _, path := range []string{"/growth", "/growth/"} {
		resp, err := h.http.Client().Get(h.http.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		body := new(bytes.Buffer)
		body.ReadFrom(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("GET %s with no credential: %d, want 401", path, resp.StatusCode)
		}
		if strings.Contains(body.String(), "303,600") {
			t.Errorf("GET %s leaked a revenue figure to an anonymous caller", path)
		}
	}
}

// A hub nobody pointed a growth shipper at is a working hub. It must say so
// rather than draw an empty ledger that reads like a business with no revenue.
func TestGrowthBoard_SaysWhenNothingHasShipped(t *testing.T) {
	h := newHarness(t)
	resp, body := h.get(t, "/growth")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /growth on an empty hub: %d", resp.StatusCode)
	}
	if !strings.Contains(string(body), "还没有任何一天的数据") {
		t.Errorf("an empty board does not say it is empty:\n%s", body)
	}
}

// A shipper bug is a 400 the shipper can act on, not a 500 that sends whoever
// wrote it reading hub logs -- and not a stored half-document either, because
// these figures get read out in a meeting.
func TestGrowthIngest_RejectsWhatItCannotStoreHonestly(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "growth")
	recent := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	okr := `"okr": { "focus": "wechat_agent", "quarter": "2026Q4-首单",
	          "target_annualized": 420000, "days_to_kill_switch": 76 }`
	h5 := `"h5": { "arr_cny": 303600, "expiring_in_window_cny": 282000,
	         "expiring_accounts": 52, "churned_accounts": 6, "active_accounts": 76 }`

	for name, body := range map[string]string{
		"no source": fmt.Sprintf(`{"source": "", "day": %q, %s,
			"ai": {"signed_deals":0,"qualified_leads":0,"arr_cny":0,"updated_at":%q}, %s}`,
			today(), h5, recent, okr),
		// A second spelling of one shipper is a second ledger nothing ever
		// reconciles, so it is refused rather than normalised.
		"shouting source": fmt.Sprintf(`{"source": "Growth-Facts", "day": %q, %s,
			"ai": {"signed_deals":0,"qualified_leads":0,"arr_cny":0,"updated_at":%q}, %s}`,
			today(), h5, recent, okr),
		"day is not a day": fmt.Sprintf(`{"source": "growth-facts", "day": "yesterday", %s,
			"ai": {"signed_deals":0,"qualified_leads":0,"arr_cny":0,"updated_at":%q}, %s}`,
			h5, recent, okr),
		"day is in the future": fmt.Sprintf(`{"source": "growth-facts", "day": %q, %s,
			"ai": {"signed_deals":0,"qualified_leads":0,"arr_cny":0,"updated_at":%q}, %s}`,
			time.Now().UTC().AddDate(0, 0, 9).Format(model.GrowthDayLayout), h5, recent, okr),
		// Without it, every surface has to assume the hand-filled figures are
		// current -- the one failure this whole feature exists to prevent.
		"no ai.updated_at": fmt.Sprintf(`{"source": "growth-facts", "day": %q, %s,
			"ai": {"signed_deals":0,"qualified_leads":0,"arr_cny":0}, %s}`, today(), h5, okr),
		"negative revenue": fmt.Sprintf(`{"source": "growth-facts", "day": %q,
			"h5": {"arr_cny": -1, "expiring_in_window_cny":0, "expiring_accounts":0,
			       "churned_accounts":0, "active_accounts":0},
			"ai": {"signed_deals":0,"qualified_leads":0,"arr_cny":0,"updated_at":%q}, %s}`,
			today(), recent, okr),
		"no focus": fmt.Sprintf(`{"source": "growth-facts", "day": %q, %s,
			"ai": {"signed_deals":0,"qualified_leads":0,"arr_cny":0,"updated_at":%q},
			"okr": {"focus": "", "quarter": "2026Q4", "target_annualized": 1, "days_to_kill_switch": 1}}`,
			today(), h5, recent),
		"not json": `{`,
	} {
		resp := h.pushGrowth(t, tok, []byte(body))
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", name, resp.StatusCode)
		}
	}

	var rows int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM growth_facts`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		t.Errorf("a refused push stored %d row(s)", rows)
	}
}

// The shipper is a nightly cron job, not a machine. Marking it keeps the fleet
// roster and the stale-agent finding from reporting it forever as a broken
// endpoint that stopped sending usage.
func TestGrowthIngest_ShipperLeavesTheAgentRoster(t *testing.T) {
	h := newHarness(t)
	seedGrowth(t, h, c2(today(), time.Now().Add(-time.Hour)))

	var kind string
	if err := h.srv.Store.DB().QueryRow(
		`SELECT kind FROM endpoints WHERE endpoint_id = 'ep_growth'`).Scan(&kind); err != nil {
		t.Fatal(err)
	}
	if kind != "growth_shipper" {
		t.Errorf("endpoint kind = %q; want growth_shipper", kind)
	}
}

// Chinese is this board's base language, English is available on request.
func TestGrowthBoard_SpeaksEnglishWhenAsked(t *testing.T) {
	h := newHarness(t)
	seedGrowth(t, h, c2(today(), time.Now().AddDate(0, 0, -5)))

	_, zh := h.get(t, "/growth")
	if !strings.Contains(string(zh), "距上次更新 5 天") {
		t.Error("the default board is not in Chinese")
	}
	_, en := h.get(t, "/growth?locale=en")
	if !strings.Contains(string(en), "5 days since the last update") {
		t.Errorf("?locale=en did not reach the English board:\n%s", en)
	}
}
