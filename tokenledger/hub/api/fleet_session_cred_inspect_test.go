package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestSessionCredInspectIssuingNodeOnly(t *testing.T) {
	h, node, foreign, fleet, _ := sessHarness(t)
	issued := sessIssue(t, h, node, fleet, nil)
	wid := assertClaims(fleet, time.Now()).WorkerID
	req := map[string]any{"original": issued["cred"], "effective": issued["cred"], "worker_id": wid, "provider": "codex"}
	before := len(sessAudits(t, h))
	for _, token := range []string{"", foreign, sessVerifier, viewerToken} {
		if st, _ := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/inspect", token, "", req); st == 200 {
			t.Fatal("foreign caller inspected credential")
		}
	}
	st, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/inspect", node, "", req)
	if st != 200 || out["worker_id"] != wid || out["binding"] != nil {
		t.Fatalf("original authorized scope: %d %v", st, out)
	}
	if len(sessAudits(t, h)) != before {
		t.Fatal("inspection mutated audit")
	}
	for _, key := range []string{"original", "effective", "worker_id", "provider"} {
		bad := make(map[string]any)
		for k, v := range req {
			bad[k] = v
		}
		bad[key] = "foreign"
		if st, _ := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/inspect", node, "", bad); st == 200 {
			t.Fatal("scope mismatch accepted", key)
		}
	}
}

func TestSessionCredInspectFreshNoRenewal(t *testing.T) {
	h, node, _, fleet, _ := sessHarness(t)
	issued := sessIssue(t, h, node, fleet, nil)
	cred := issued["cred"].(string)
	c, why := h.srv.parseSessionPass(cred, time.Now())
	if why != "" {
		t.Fatal(why)
	}
	expired := *c
	expired.Exp = time.Now().Add(-time.Hour).Unix()
	original := signSessionCred(expired, h.srv.SessionCredKey)
	request := map[string]any{"original": original, "effective": cred, "worker_id": c.WorkerID, "provider": "codex"}
	before, err := h.srv.Store.SessionCredByID(c.ID)
	if err != nil {
		t.Fatal(err)
	}
	audits := len(sessAudits(t, h))
	check := func(want int) {
		t.Helper()
		status, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/inspect", node, "", request)
		raw, _ := json.Marshal(out)
		if status != want || strings.Contains(string(raw), cred) || strings.Contains(string(raw), original) {
			t.Fatalf("inspect: %d %s", status, raw)
		}
	}
	check(200)
	after, _ := h.srv.Store.SessionCredByID(c.ID)
	if !reflect.DeepEqual(before, after) || len(sessAudits(t, h)) != audits {
		t.Fatal("inspection mutated credential or audit")
	}
	request["effective"] = original
	check(403) // An expired original alone is never a current grant.
	request["effective"] = cred
	other := *c
	other.ID = "another-credential"
	request["original"] = signSessionCred(other, h.srv.SessionCredKey)
	check(403)
	request["original"] = original
	// Warm verifier cache cannot hide a revocation from this endpoint.
	h.srv.verifySessionCred(cred, "", "", false, time.Now())
	if _, err := h.srv.Store.RevokeSessionCred(c.ID, "fixture", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	check(403)
}

func TestSessionCredInspectFreshRowAndSigningKinds(t *testing.T) {
	for _, fault := range []string{"h2", "row-expired", "row-provider", "worker", "principal", "machine", "provider"} {
		t.Run(fault, func(t *testing.T) {
			h, node, _, fleet, _ := sessHarness(t)
			issued := sessIssue(t, h, node, fleet, nil)
			cred := issued["cred"].(string)
			claims, _ := h.srv.parseSessionPass(cred, time.Now())
			original := cred
			want := 403
			switch fault {
			case "h2":
				_, h.srv.RelaySignKey, _ = ed25519.GenerateKey(rand.Reader)
				claims.V = 2
				original = h.srv.signSessionPass(*claims)
				want = 200
			case "row-expired":
				_, err := h.srv.Store.DB().Exec(`UPDATE fleet_session_creds SET expires_at = ? WHERE id = ?`, time.Now().Add(-time.Hour).UTC().Format(time.RFC3339), claims.ID)
				if err != nil {
					t.Fatal(err)
				}
			case "row-provider":
				_, err := h.srv.Store.DB().Exec(`UPDATE fleet_session_creds SET providers = 'claude' WHERE id = ?`, claims.ID)
				if err != nil {
					t.Fatal(err)
				}
			default:
				switch fault {
				case "worker":
					claims.WorkerID = "other"
				case "principal":
					claims.Principal = "other"
				case "machine":
					claims.Machine = "other"
				case "provider":
					claims.Providers = []string{"codex"}
				}
				original = h.srv.signSessionPass(*claims)
			}
			status, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/inspect", node, "", map[string]any{
				"original": original, "effective": cred, "worker_id": issued["worker_id"], "provider": "codex"})
			if status != want {
				t.Fatalf("%d %v", status, out)
			}
		})
	}
}
