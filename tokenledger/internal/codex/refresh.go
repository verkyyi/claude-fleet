package codex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
)

const refreshAhead = 24 * time.Hour

var ErrProfileBusy = errors.New("Codex profile is in use by another ccquota login, run, or refresh")

// ErrHubManaged: the home's refresh_token is the hub placeholder. The hub
// refreshes this account and the node agent (ccquota agent with
// CCQUOTA_FLEET_CREDS=1) rewrites auth.json before the access token expires;
// a local refresh here is always wrong and is refused before anything runs.
var ErrHubManaged = errors.New("Codex home is hub-managed: the hub refreshes it and the node agent renews auth.json; it is never refreshed on this machine")

// AcquireProfile serializes ccquota maintenance and managed launches across
// processes. The OS releases the lock after a crash. Direct Codex clients do
// not participate; token persistence is always left to the official CLI.
func AcquireProfile(home string) (func(), error)    { return acquireProfile(home, false) }
func AcquireRunProfile(home string) (func(), error) { return acquireProfile(home, true) }
func acquireProfile(home string, shared bool) (func(), error) {
	f, err := os.OpenFile(filepath.Join(home, ".ccquota-auth.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, errors.New("Codex profile is not writable for credential maintenance")
	}
	if err := lockFile(f, shared); err != nil {
		f.Close()
		return nil, ErrProfileBusy
	}
	return func() { unlockFile(f); f.Close() }, nil
}

type refreshState struct {
	Fingerprint string     `json:"credential_version"`
	State       string     `json:"state"`
	Reason      string     `json:"reason,omitempty"`
	AttemptAt   *time.Time `json:"attempt_at,omitempty"`
	RetryAt     *time.Time `json:"retry_at,omitempty"`
	Failures    int        `json:"failures,omitempty"`
}

func readRefreshState(home string) refreshState {
	var s refreshState
	b, err := os.ReadFile(filepath.Join(home, ".ccquota-auth-state.json"))
	if err == nil && len(b) < 16384 {
		_ = json.Unmarshal(b, &s)
	}
	return s
}

func atomicJSON(path string, value any) error {
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".ccquota-write-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(append(b, '\n')); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

// LoginHealth is metadata only. No token or credential fingerprint leaves
// the endpoint. Expiry of an access token alone never means re-login is needed.
func LoginHealth(home string, auth *Auth, enabled bool) *model.LoginHealth {
	h := &model.LoginHealth{AutoRefresh: enabled, State: "no_credentials"}
	if auth == nil {
		h.Reason = "No readable file login; use ccquota codex login for this profile"
		return h
	}
	if auth.Mode != "subscription" {
		h.State = "unsupported"
		h.Reason = "ChatGPT file login is required for subscription quota and automatic renewal"
		return h
	}
	h.HasRefreshToken = auth.HasRefreshToken
	h.LastRefreshAt = auth.LastRefresh
	if !auth.ExpiresAt.IsZero() {
		t := auth.ExpiresAt
		h.AccessExpiresAt = &t
	}
	h.State = "valid"
	if auth.HubManaged {
		// The hub is the one refresher (claude-fleet#1666): refresh_due,
		// reauth_required and this machine's renewal record have no meaning
		// here, so none of them is read. The only thing that can be wrong is a
		// lease the node agent did not renew in time.
		h.Source, h.AutoRefresh = "hub", false
		if !auth.ExpiresAt.IsZero() && !auth.ExpiresAt.After(time.Now()) {
			h.State = "access_expired"
			h.Reason = "Hub lease expired and the node agent has not renewed it; check ccquota agent (CCQUOTA_FLEET_CREDS=1) on this machine"
		}
		applyUpstream(h, home, auth)
		return h
	}
	h.Source = "local"
	if !auth.ExpiresAt.IsZero() && time.Until(auth.ExpiresAt) <= refreshAhead {
		h.State = "refresh_due"
		if !auth.HasRefreshToken {
			h.Reason = "No refresh credential; sign in again before access expires"
		}
	}
	if !auth.ExpiresAt.IsZero() && !auth.ExpiresAt.After(time.Now()) {
		h.State = "access_expired"
		h.Reason = "Access token expired; renewal has not yet been verified"
		if !auth.HasRefreshToken {
			h.State = "reauth_required"
			h.Reason = "Access token expired and no refresh credential is available"
		}
	}
	s := readRefreshState(home)
	if s.Fingerprint == auth.fingerprint {
		h.RefreshAttemptAt, h.RetryAt = s.AttemptAt, s.RetryAt
		if s.State != "" && s.State != "valid" {
			h.State, h.Reason = s.State, s.Reason
			if h.State == "refreshing" && s.AttemptAt != nil && time.Since(*s.AttemptAt) > time.Minute {
				h.State, h.Reason = "retry_pending", "Previous renewal was interrupted; it will be retried"
			}
		}
	}
	applyUpstream(h, home, auth)
	return h
}

// applyUpstream downgrades a login the clock still calls usable when the
// upstream has refused this exact access token (claude-fleet#1920). An
// expired, reauth-required or otherwise already-unusable state stays as it is:
// it is the more specific word.
func applyUpstream(h *model.LoginHealth, home string, auth *Auth) {
	if h.State != "valid" && h.State != "refresh_due" && h.State != "retry_pending" && h.State != "refreshing" {
		return
	}
	v := upstreamRejection(home, auth)
	if v == nil {
		return
	}
	at := v.At
	h.State, h.UpstreamError, h.UpstreamRejectedAt = "access_rejected", v.Error, &at
	if h.Source == "hub" {
		h.Reason = "Upstream refused this hub lease (" + v.Error + ", " + at.Format(time.RFC3339) + ") before its expiry; the hub must issue a new one — a local refresh or re-login here does not fix it"
	} else {
		h.Reason = "Upstream refused this access token (" + v.Error + ", " + at.Format(time.RFC3339) + ") before its expiry; renewal will be attempted, sign in again if it stays refused"
	}
}

// Maintain refreshes only near expiry (or after an authorization error), in
// the original profile. It never copies a refresh token or rewrites auth.json.
// Official Codex owns the refresh exchange and its credential persistence.
// A hub-managed home is refused outright (ErrHubManaged) — before the official
// CLI is started and without touching the renewal record.
func Maintain(ctx context.Context, binary, home string, force bool) (*Auth, error) {
	unlock, err := AcquireProfile(home)
	if err != nil {
		a, _ := ReadAuth(home)
		return a, err
	}
	defer unlock()
	a, err := ReadAuth(home)
	if err != nil {
		return a, err
	}
	if a.HubManaged {
		return a, ErrHubManaged
	}
	if a.Mode != "subscription" {
		return a, errors.New("ChatGPT file login is required for Codex renewal")
	}
	now := time.Now().UTC()
	due := !a.ExpiresAt.IsZero() && !a.ExpiresAt.After(now.Add(refreshAhead))
	if !due && !force {
		return a, nil
	}
	s := readRefreshState(home)
	if s.Fingerprint != a.fingerprint {
		s = refreshState{Fingerprint: a.fingerprint}
	}
	if a.ExpiresAt.After(now) && s.State == "valid" && s.AttemptAt != nil && now.Sub(*s.AttemptAt) < 10*time.Minute {
		return a, nil
	}
	if s.State == "reauth_required" {
		return a, errors.New("Codex refresh credential rejected; sign in again for this profile")
	}
	if s.RetryAt != nil && now.Before(*s.RetryAt) {
		return a, errors.New("Codex renewal is waiting for its retry time")
	}
	if force && !due && a.LastRefresh != nil && now.Sub(*a.LastRefresh) < 10*time.Minute {
		return a, nil
	}
	if !a.HasRefreshToken {
		return a, errors.New("Codex refresh credential is unavailable; sign in again for this profile")
	}
	s.State, s.Reason, s.AttemptAt = "refreshing", "Renewing through the official Codex CLI", &now
	path := filepath.Join(home, ".ccquota-auth-state.json")
	if err := atomicJSON(path, s); err != nil {
		return a, errors.New("could not save Codex renewal state")
	}
	err = refreshOfficial(ctx, binary, home)
	after, readErr := ReadAuth(home)
	if readErr == nil && after.Identity.AccountUUID != a.Identity.AccountUUID {
		return after, errors.New("Codex profile account changed during renewal; waiting for the next scan")
	}
	if err == nil && (readErr != nil || after.ExpiresAt.IsZero() || !after.ExpiresAt.After(now)) {
		err = errors.New("Codex renewal did not persist a valid access token")
	}
	if err == nil {
		s = refreshState{Fingerprint: after.fingerprint, State: "valid", AttemptAt: &now}
	} else {
		s.Failures++
		s.State, s.Reason = "retry_pending", "Codex renewal temporarily unavailable; local usage collection continues"
		var re *rpcError
		if errors.As(err, &re) && re.reauth {
			s.State, s.Reason, s.RetryAt = "reauth_required", re.Error(), nil
		} else {
			retry := now.Add(time.Minute * time.Duration(1<<min(s.Failures, 6)))
			s.RetryAt = &retry
		}
	}
	if saveErr := atomicJSON(path, s); saveErr != nil {
		return after, errors.New("could not persist Codex renewal result")
	}
	if after != nil {
		return after, err
	}
	return a, err
}

func refreshOfficial(ctx context.Context, binary, home string) error {
	c, err := openRPC(ctx, binary, home)
	if err != nil {
		return err
	}
	var out struct {
		Account *struct {
			Type string `json:"type"`
		} `json:"account"`
	}
	err = c.Call(2, "account/read", map[string]bool{"refreshToken": true}, &out)
	c.Close()
	// Older CLIs log a rejected refresh and return account:null instead of
	// a protocol error. Only retain recognized, credential-free markers.
	if (err != nil || out.Account == nil) && c.diagnostics.reauthenticationRequired() {
		return &rpcError{reauth: true}
	}
	if err != nil {
		return err
	}
	if out.Account == nil || out.Account.Type != "chatgpt" {
		return errors.New("Codex renewal did not return a ChatGPT login")
	}
	return nil
}
