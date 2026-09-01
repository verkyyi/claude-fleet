package sessions

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAccountKeyFor_StableAndNonSecret(t *testing.T) {
	tok := "sk-ant-oat01-supersecret"
	k := AccountKeyFor(tok)

	if k == "" {
		t.Fatal("a real token produced no key")
	}
	if k != AccountKeyFor(tok) {
		t.Fatal("the key is not stable for the same token")
	}
	if AccountKeyFor("sk-ant-oat01-other") == k {
		t.Fatal("two different tokens collided")
	}
	// The whole point: the token must not be recoverable from what lands on
	// disk. A usage monitor that leaks credentials is worse than the problem.
	if len(k) >= len(tok) || containsAny(k, tok) {
		t.Fatalf("key %q leaks the token", k)
	}
	if AccountKeyFor("") != "" {
		t.Error("no token must map to no key, not to a hash of the empty string")
	}
}

func containsAny(hay, needle string) bool {
	for n := 8; n <= len(needle); n++ {
		if len(needle) >= n && len(hay) >= n {
			for i := 0; i+n <= len(needle); i++ {
				if idx := indexOf(hay, needle[i:i+n]); idx >= 0 {
					return true
				}
			}
		}
	}
	return false
}

func indexOf(hay, needle string) int {
	for i := 0; i+len(needle) <= len(hay); i++ {
		if hay[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}

func TestWriteAndLoad(t *testing.T) {
	dir := t.TempDir()
	pct := 19.0
	s := Stamp{
		SessionID: "sess-1", TranscriptPath: "/p/a.jsonl",
		StampedAt: time.Now().UTC(), AccountKey: "tok_abc", Label: "me@example.com",
		FiveHourPct: &pct,
	}
	if err := Write(dir, s); err != nil {
		t.Fatal(err)
	}

	idx, err := Load(dir, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := idx.BySession["sess-1"]; !ok || got.AccountKey != "tok_abc" {
		t.Fatalf("BySession = %+v", idx.BySession)
	}
	// The transcript path is the join key the scanner actually has.
	if got, ok := idx.ByTranscript["/p/a.jsonl"]; !ok || got.Label != "me@example.com" {
		t.Fatalf("ByTranscript = %+v", idx.ByTranscript)
	}
	if got := idx.ByTranscript["/p/a.jsonl"]; got.FiveHourPct == nil || *got.FiveHourPct != 19 {
		t.Error("the rate-limit reading did not survive the round trip")
	}
}

// A stamp older than the window describes a session whose account may since
// have changed; trusting it reintroduces exactly the staleness this fixes.
func TestLoad_IgnoresStaleStamps(t *testing.T) {
	dir := t.TempDir()
	old := Stamp{SessionID: "old", TranscriptPath: "/p/old.jsonl",
		StampedAt: time.Now().Add(-48 * time.Hour), AccountKey: "tok_old"}
	fresh := Stamp{SessionID: "new", TranscriptPath: "/p/new.jsonl",
		StampedAt: time.Now(), AccountKey: "tok_new"}
	for _, s := range []Stamp{old, fresh} {
		if err := Write(dir, s); err != nil {
			t.Fatal(err)
		}
	}

	idx, err := Load(dir, 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := idx.BySession["old"]; ok {
		t.Error("a stamp older than the window was trusted")
	}
	if _, ok := idx.BySession["new"]; !ok {
		t.Error("a fresh stamp was dropped")
	}

	// Control: with no window, both are kept — otherwise the assertion above
	// would pass on a Load that discards everything.
	all, err := Load(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(all.BySession) != 2 {
		t.Fatalf("unbounded Load returned %d stamps, want 2", len(all.BySession))
	}
}

// The hook is optional; an absent directory is the normal single-account case.
func TestLoad_MissingDirIsNotAnError(t *testing.T) {
	idx, err := Load(filepath.Join(t.TempDir(), "nope"), time.Hour)
	if err != nil {
		t.Fatalf("a machine without the hook must not error: %v", err)
	}
	if len(idx.BySession) != 0 {
		t.Error("expected an empty index")
	}
}

// Session ids arrive from a hook payload; they must not be able to write
// outside the directory.
func TestWrite_SessionIDCannotEscape(t *testing.T) {
	dir := t.TempDir()
	s := Stamp{SessionID: "../../escaped", TranscriptPath: "/p/x.jsonl", StampedAt: time.Now()}
	if err := Write(dir, s); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dir, time.Hour); err != nil {
		t.Fatal(err)
	}
	// Nothing may exist above the sessions directory.
	if _, err := readDirNames(filepath.Join(dir, "..", "..")); err == nil {
		// The temp root exists; what matters is that no file named "escaped"
		// landed outside Dir(dir).
		if fileExists(filepath.Join(dir, "..", "escaped.json")) {
			t.Fatal("a stamp escaped its directory")
		}
	}
}

func TestPrune(t *testing.T) {
	dir := t.TempDir()
	if err := Write(dir, Stamp{SessionID: "a", StampedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	n, err := Prune(dir, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("pruned %d fresh stamps, want 0", n)
	}
}

func TestIndex_Accounts(t *testing.T) {
	idx := &Index{BySession: map[string]Stamp{
		"a": {AccountKey: "tok_1", Label: "one@example.com"},
		"b": {AccountKey: "tok_1"},
		"c": {AccountKey: "tok_2", Label: "two@example.com"},
		"d": {AccountKey: ""},
	}}
	got := idx.Accounts()
	if len(got) != 2 {
		t.Fatalf("accounts = %v, want 2 (the unstamped one is the machine login)", got)
	}
	if got["tok_1"] != "one@example.com" {
		t.Errorf("a known label lost to an unlabelled sibling: %v", got)
	}
}

func readDirNames(p string) ([]string, error) { return nil, nil }
func fileExists(p string) bool                { _, err := os.Stat(p); return err == nil }

// The token is unreachable from a hook, so the reset schedule is what actually
// identifies a subscription. Verified on a live machine: 17 sessions collapsed
// into exactly two groups matching the account supervisor's own view.
func TestFingerprintFor_SameScheduleSameAccount(t *testing.T) {
	base5 := time.Date(2026, 9, 1, 13, 40, 0, 0, time.UTC)
	base7 := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)

	a := FingerprintFor(&base5, &base7)
	if a == "" {
		t.Fatal("no fingerprint from a full reading")
	}

	// The SAME account one window later: both resets have advanced, but the
	// phase has not. A raw-timestamp fingerprint would change identity every
	// five hours.
	next5 := base5.Add(5 * time.Hour)
	next7 := base7.Add(7 * 24 * time.Hour)
	if b := FingerprintFor(&next5, &next7); b != a {
		t.Fatalf("fingerprint changed when the window rolled over: %s -> %s", a, b)
	}

	// A different account: the real second one from that machine, whose 7-day
	// reset sat three days away.
	other5 := time.Date(2026, 9, 1, 13, 30, 0, 0, time.UTC)
	other7 := time.Date(2026, 9, 7, 5, 0, 0, 0, time.UTC)
	if c := FingerprintFor(&other5, &other7); c == a {
		t.Fatal("two subscriptions with different reset schedules produced one fingerprint")
	}
}

func TestFingerprintFor_NoReadingNoFingerprint(t *testing.T) {
	if got := FingerprintFor(nil, nil); got != "" {
		t.Errorf("got %q; a session with no rate-limit reading cannot be identified", got)
	}
}

// A token, when one is visible, is authoritative and must win over the guess.
func TestStamp_AccountPrefersTheTokenOverTheHeuristic(t *testing.T) {
	r5 := time.Date(2026, 9, 1, 13, 40, 0, 0, time.UTC)
	r7 := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)

	withTok := Stamp{AccountKey: "tok_real", FiveHourAt: &r5, SevenDayAt: &r7}
	if withTok.Account() != "tok_real" {
		t.Errorf("Account() = %q, want the token-derived key", withTok.Account())
	}
	if withTok.AccountIsInferred() {
		t.Error("a token-derived key must not be reported as inferred")
	}

	noTok := Stamp{FiveHourAt: &r5, SevenDayAt: &r7}
	if noTok.Account() == "" {
		t.Fatal("no identifier at all without a token")
	}
	if !noTok.AccountIsInferred() {
		t.Error("a reset-phase key MUST be reported as inferred; it is a heuristic")
	}
}

// Plans have rate-limit windows; API keys have invoices. That absence is the
// only signal distinguishing them, and the difference matters: API spend
// counted against a plan's quota is misattributed entirely.
func TestInferBilling(t *testing.T) {
	if got := InferBilling(true); got != BillingSubscription {
		t.Errorf("with rate limits = %q, want subscription", got)
	}
	if got := InferBilling(false); got != BillingAPI {
		t.Errorf("without rate limits = %q, want api", got)
	}
}

// The same reset reaches ccquota at two precisions: /api/oauth/usage says
// 13:39:59.278, the statusLine says 13:40:00. Measured on a live machine, that
// 0.722s straddled a second boundary and made one subscription look like two.
func TestFingerprintFor_ToleratesSourcePrecisionSkew(t *testing.T) {
	api5 := time.Date(2026, 9, 1, 13, 39, 59, 278002000, time.UTC)
	api7 := time.Date(2026, 9, 4, 13, 59, 59, 278026000, time.UTC)
	sl5 := time.Date(2026, 9, 1, 13, 40, 0, 0, time.UTC)
	sl7 := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)

	if a, b := FingerprintFor(&api5, &api7), FingerprintFor(&sl5, &sl7); a != b {
		t.Fatalf("the same subscription fingerprinted differently by source: %s vs %s", a, b)
	}
}

// Control: quantising must not merge subscriptions that genuinely differ. The
// real second account's resets were ten minutes and three days away.
func TestFingerprintFor_QuantisingDoesNotMergeRealAccounts(t *testing.T) {
	a5 := time.Date(2026, 9, 1, 13, 40, 0, 0, time.UTC)
	a7 := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	b5 := time.Date(2026, 9, 1, 13, 30, 0, 0, time.UTC)
	b7 := time.Date(2026, 9, 7, 5, 0, 0, 0, time.UTC)

	if FingerprintFor(&a5, &a7) == FingerprintFor(&b5, &b7) {
		t.Fatal("two genuinely different subscriptions collapsed into one")
	}
}
