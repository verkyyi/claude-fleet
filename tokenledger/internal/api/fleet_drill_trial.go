package api

import (
	"bytes"
	"crypto/rand"
	"encoding/base32"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Drill triers (claude-fleet#4215): the isolated drill (claude-fleet#4061)
// walks the trial as two stand-in strangers instead of two real WeChat
// accounts scanned by hand, so it can run again. The flow:
//
//	POST /v1/admin/drill/trial     an admin mints one → {subject, code, url, expires_at}
//	                               ({"subject": …}: another code for the same one — it comes back)
//	GET  /auth/drill/trial?code=   the code, once → the SAME trialSignIn a real
//	                               sign-in the list refused takes: a trial
//	                               session, /app/try, never the list
//	DELETE /v1/self                the drill trier deletes itself (its session)
//
// Everything after the sign-in — the claim, the heartbeat, the pause, the
// budget, the give-back, the kept conversation and its seed — is the real
// person's road, no branch. Its life is a drill's (2h, 5m…24h); at its end
// the sweep gives its machine back, then deletes its conversation, identity,
// trial and person. fleet.trial off ⇒ both doors 404; no code ⇒ nothing here
// runs (TestDrillTrialOffAddsNothing).
const (
	DrillTrialPath       = "/v1/admin/drill/trial"
	DrillTrialRedeemPath = "/auth/drill/trial"

	// drillTrialCodeTTL is how long an exchange code is good for.
	drillTrialCodeTTL = 10 * time.Minute

	// trialEndDrill: the drill trier's life ran out with a machine in hand.
	trialEndDrill = "drill"
)

var drillTrialCodeRe = regexp.MustCompile(`^ft_[a-z2-7]{26}$`)

// DrillTrialMessage is what `fleet drill trial` signs: the life asked
// (0 = the default) and the subject coming back ("" = a new one).
func DrillTrialMessage(ts int64, ttlSecs int, subject string) string {
	return strings.TrimRight(fmt.Sprintf("fleet-drill %d trial %d %s", ts, ttlSecs, subject), " ")
}

// mintDrillTrialToken is "<prefix>" + 26 base32 letters of 130 random bits.
func mintDrillTrialToken(prefix string) (string, error) {
	b := make([]byte, 17)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate exchange code: %w", err)
	}
	return prefix + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))[:26], nil
}

type drillTrialRequest struct {
	TTLSeconds int    `json:"ttl_seconds,omitempty"`
	Subject    string `json:"subject,omitempty"`
	Cert       string `json:"cert,omitempty"`
	Sig        string `json:"sig,omitempty"`
	TS         int64  `json:"ts,omitempty"`
}

// DrillTrialResponse is the body of POST /v1/admin/drill/trial. Code (and the
// URL that carries it) is shown this once; the hub keeps only its hash.
type DrillTrialResponse struct {
	Subject       string    `json:"subject"`
	Kind          string    `json:"kind"`
	PersonID      string    `json:"person_id,omitempty"`
	Code          string    `json:"code"`
	URL           string    `json:"url"`
	CodeExpiresAt time.Time `json:"code_expires_at"`
	ExpiresAt     time.Time `json:"expires_at"`
}

// handleAdminDrillTrial serves POST /v1/admin/drill/trial: an admin's, by the
// same two doors as POST /v1/admin/drill.
func (s *Server) handleAdminDrillTrial(w http.ResponseWriter, r *http.Request) {
	if !s.trialOn() || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 64<<10))
	if err != nil {
		httpError(w, http.StatusBadRequest, "unreadable body")
		return
	}
	var req drillTrialRequest
	if len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, &req); err != nil {
			httpError(w, http.StatusBadRequest, "body must be JSON: "+err.Error())
			return
		}
	}
	if req.Cert == "" {
		s.viewerOnly(s.adminOnly(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			actor := principalOf(r.Context())
			if actor == "" {
				actor = "operator"
			}
			s.mintDrillTrial(w, r, req, actor)
		}))).ServeHTTP(w, r)
		return
	}
	now := time.Now()
	if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
		httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
		return
	}
	id, err := s.verifySSHRelayCert(req.Cert, req.Sig, DrillTrialMessage(req.TS, req.TTLSeconds, req.Subject), DrillSigNamespace, now)
	if err != nil {
		var re *sshRelayError
		if errors.As(err, &re) {
			httpError(w, http.StatusUnauthorized, re.msg)
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !s.principalIsAdmin(id.Principal) {
		httpError(w, http.StatusForbidden, "only an admin can mint a drill trier")
		return
	}
	s.mintDrillTrial(w, r, req, id.Principal)
}

// mintDrillTrial makes a new drill trier (or, with req.Subject, finds the one
// coming back) and hands out one exchange code for it.
func (s *Server) mintDrillTrial(w http.ResponseWriter, r *http.Request, req drillTrialRequest, actor string) {
	now := time.Now()
	var d *store.DrillTrial
	if subj := strings.TrimSpace(req.Subject); subj != "" {
		if req.TTLSeconds != 0 {
			httpError(w, http.StatusBadRequest, "ttl_seconds is the new drill trier's; one coming back keeps its life")
			return
		}
		got, err := s.Store.DrillTrialBySubject(subj)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if got == nil {
			// The person id works too: what a drill remembers of it.
			if got, err = s.Store.DrillTrialOf(subj); err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
		}
		if got == nil || !got.ExpiresAt.After(now) {
			httpError(w, http.StatusNotFound, "no live drill trier "+fmt.Sprintf("%q", subj))
			return
		}
		d = got
	} else {
		ttl := DrillDefaultTTL
		if req.TTLSeconds != 0 {
			ttl = time.Duration(req.TTLSeconds) * time.Second
			if ttl < drillMinTTL || ttl > DrillMaxTTL {
				httpError(w, http.StatusBadRequest, fmt.Sprintf("ttl_seconds must be %d…%d", int(drillMinTTL.Seconds()), int(DrillMaxTTL.Seconds())))
				return
			}
		}
		var rnd [8]byte
		if _, err := rand.Read(rnd[:]); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		d = &store.DrillTrial{Subject: fmt.Sprintf("trial-%x", rnd[:]), CreatedBy: actor, CreatedAt: now, ExpiresAt: now.Add(ttl)}
		if err := s.Store.CreateDrillTrial(*d); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	code, err := mintDrillTrialToken("ft_")
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	codeExp := now.Add(drillTrialCodeTTL)
	if codeExp.After(d.ExpiresAt) {
		codeExp = d.ExpiresAt
	}
	if err := s.Store.AddDrillTrialCode(d.Subject, HashToken(code), codeExp, now); err != nil {
		httpError(w, http.StatusConflict, err.Error())
		return
	}
	_ = s.Store.HubAudit(actor, "drill.trial.mint", d.Subject, "ok", "演练试用兑换码 · drill trier code until "+codeExp.UTC().Format(time.RFC3339), now)
	log.Printf("fleet: %s minted a drill trier code for %s (alive until %s)", actor, d.Subject, d.ExpiresAt.UTC().Format(time.RFC3339))
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, DrillTrialResponse{Subject: d.Subject, Kind: store.DrillKind, PersonID: d.PrincipalID,
		Code: code, URL: s.hubURL(r) + DrillTrialRedeemPath + "?code=" + url.QueryEscape(code),
		CodeExpiresAt: codeExp.UTC(), ExpiresAt: d.ExpiresAt.UTC()})
}

// handleDrillTrialRedeem serves GET /auth/drill/trial?code=ft_…: the code,
// once, signs its drill trier in as a trial person — trialSignIn, asked.
func (s *Server) handleDrillTrialRedeem(w http.ResponseWriter, r *http.Request) {
	if !s.trialOn() || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	now := time.Now()
	code := r.URL.Query().Get("code")
	if !drillTrialCodeRe.MatchString(code) {
		httpError(w, http.StatusUnauthorized, "兑换码无效 · exchange code unknown")
		return
	}
	d, err := s.Store.UseDrillTrialCode(HashToken(code), now)
	if err != nil {
		if !errors.Is(err, store.ErrDrillTrialCode) {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		_ = s.Store.HubAudit("drill-trial", "drill.trial.redeem", "", "refused", "兑换码无效、已用过或已过期 · code unknown, used or expired", now)
		httpError(w, http.StatusUnauthorized, "兑换码无效、已用过或已过期 · exchange code unknown, used or expired")
		return
	}
	if !s.trialSignIn(w, r, true, store.DrillKind, d.Subject, "演练试用 "+d.Subject, d.PrincipalID, now) {
		httpError(w, http.StatusServiceUnavailable, "the trial could not sign this drill trier in — see the hub's log")
		return
	}
	pid, err := s.Store.IdentityPrincipal(store.DrillKind, d.Subject)
	if err == nil && pid != "" {
		err = s.Store.SetDrillTrialPrincipal(d.Subject, pid)
	}
	if err != nil {
		log.Printf("fleet: drill trier %s: record its person: %v", d.Subject, err)
	}
	_ = s.Store.HubAudit(pid, "drill.trial.redeem", d.Subject, "ok", "演练试用登录 · drill trier signed in for a trial", now)
}

// SweepDrillTrials deletes every drill trier whose life is over: its machine
// given back first, then its rows (a login still on its way back waits for
// the next sweep).
func (s *Server) SweepDrillTrials(now time.Time) {
	if s.Store == nil {
		return
	}
	gone, err := s.Store.ExpiredDrillTrials(now)
	if err != nil {
		log.Printf("fleet: drill trier sweep: %v", err)
		return
	}
	for i := range gone {
		if _, err := s.retireDrillTrial(&gone[i], "expired", now); err != nil {
			log.Printf("fleet: drill trier sweep: %s: %v", gone[i].Subject, err)
		}
	}
}

// retireDrillTrial gives d's machine back (endTrial, the real road) and
// deletes d once nothing of it is left on a machine: done=false while a
// login is still on its way back.
func (s *Server) retireDrillTrial(d *store.DrillTrial, actor string, now time.Time) (done bool, err error) {
	if pid := d.PrincipalID; pid != "" {
		t, err := s.Store.Trial(pid)
		if err != nil {
			return false, err
		}
		if t != nil && t.State == store.TrialPlaced {
			ok, sent := s.endTrial(*t, trialEndDrill, now)
			if sent {
				s.dispatchAccounts()
			}
			if !ok {
				return false, nil
			}
		}
	}
	switch err := s.Store.DeleteDrillTrial(d.Subject); {
	case errors.Is(err, store.ErrDrillTrialBusy):
		log.Printf("fleet: drill trier %s: its login is still on its way back — deleted once it is", d.Subject)
		return false, nil
	case err != nil:
		return false, err
	}
	_ = s.Store.HubAudit(actor, "drill.trial.delete", d.Subject, "ok",
		"演练试用者删除（机器放回、对话密文、身份、试用） · drill trier deleted: machine back, conversation, identity, trial", now)
	log.Printf("fleet: drill trier %s (%s) deleted (%s)", d.Subject, orDefault(d.PrincipalID, "never signed in"), actor)
	return true, nil
}

// drillTrialSelfDelete is DELETE /v1/self by a drill trier's own session.
func (s *Server) drillTrialSelfDelete(w http.ResponseWriter, r *http.Request, pid string) {
	d, err := s.Store.DrillTrialOf(pid)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if d == nil {
		httpError(w, http.StatusForbidden, "only a drill person can delete itself")
		return
	}
	done, err := s.retireDrillTrial(d, pid, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !done {
		writeJSON(w, http.StatusAccepted, map[string]any{"status": "removing", "person_id": pid, "subject": d.Subject})
		return
	}
	clearCookie(w, r, authz.CookieName, "/")
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted", "person_id": pid, "subject": d.Subject})
}
