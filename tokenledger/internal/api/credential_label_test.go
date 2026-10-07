package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sessions"
)

// claude-fleet#2104: the hub showed one subscription twice. A login moved onto
// the vault's setup token, its weekly schedule then moved, and the probe's
// fingerprint no longer matched the real account's frozen last reset — so the
// reading minted "win_…" beside the account it was. The label the token is
// kept under names the account; the reading must land there.
func TestIngest_ProbeLabelFoldsAnUnmatchedFingerprintOntoItsAccount(t *testing.T) {
	cases := []struct {
		name, label string
		phantom     bool
		fold        bool
	}{
		{"label is the mail domain", "icloud", false, false},
		{"label is the local part", "ylianghui", false, false},
		{"an existing phantom is folded in", "icloud", false, true},
		{"no label: the old phantom", "", true, false},
		{"label fits two accounts: no guess", "lee", true, false},
		{"label fits nothing", "spare", true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			tok := h.enroll(t, "mini")
			old := time.Date(2026, 10, 5, 18, 0, 0, 0, time.UTC)
			moved := time.Date(2026, 10, 9, 14, 0, 0, 0, time.UTC)
			login := func(uuid, email string, reset time.Time) {
				resp := h.push(t, tok, model.Batch{
					Identity:      model.Identity{Source: "claude", AccountUUID: uuid, Email: email, DisplayName: "Lee", MachineID: "m", Hostname: "mini"},
					AccountOrigin: model.OriginLogin,
					Limits:        &model.LimitsSnapshot{ObservedAt: time.Now().UTC().Add(-48 * time.Hour), SevenDay: model.Window{Utilization: 95, ResetsAt: &reset}},
				})
				resp.Body.Close()
			}
			login("u-icloud", "ylianghui@icloud.com", old)
			login("u-gmail", "verky.yi@gmail.com", time.Date(2026, 10, 12, 18, 0, 0, 0, time.UTC))

			key := sessions.FingerprintFor(&moved)
			if tc.fold {
				// The phantom an older hub already minted for this schedule.
				r := h.push(t, tok, model.Batch{
					Identity:      model.Identity{Source: "claude", AccountUUID: key, MachineID: "m", Hostname: "mini"},
					AccountOrigin: model.OriginSession,
					Limits:        &model.LimitsSnapshot{ObservedAt: time.Now().UTC().Add(-time.Hour), SevenDay: model.Window{Utilization: 9, ResetsAt: &moved}},
				})
				r.Body.Close()
				if had, _ := h.srv.Store.AccountExists(key); !had {
					t.Fatalf("setup: no phantom %s", key)
				}
			}
			resp := h.push(t, tok, model.Batch{
				Identity:      model.Identity{Source: "claude", AccountUUID: key, MachineID: "m", Hostname: "mini"},
				AccountOrigin: model.OriginSession,
				Limits:        &model.LimitsSnapshot{SevenDay: model.Window{Utilization: 10, ResetsAt: &moved}, CredentialLabel: tc.label},
			})
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("push: %d", resp.StatusCode)
			}

			accts, err := h.srv.Store.ListAccounts()
			if err != nil {
				t.Fatal(err)
			}
			has := false
			for _, a := range accts {
				has = has || a.AccountUUID == key
			}
			if has != tc.phantom {
				t.Fatalf("phantom %s present = %v, want %v (%d accounts)", key, has, tc.phantom, len(accts))
			}
			if !tc.phantom {
				got, err := h.srv.Store.LatestLimits("u-icloud")
				if err != nil || got == nil || got.SevenDay.ResetsAt == nil || !got.SevenDay.ResetsAt.Equal(moved) {
					t.Fatalf("the reading did not land on u-icloud: %+v %v", got, err)
				}
				// The account keeps its own name: the stand-in carried none.
				for _, a := range accts {
					if a.AccountUUID == "u-icloud" && a.Email != "ylianghui@icloud.com" {
						t.Fatalf("email overwritten: %q", a.Email)
					}
				}
			}
		})
	}
}
