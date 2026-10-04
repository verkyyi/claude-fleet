package codex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type loginObservation struct {
	Account     string    `json:"account"`
	Fingerprint string    `json:"credential_version"`
	At          time.Time `json:"at"`
}

// RecordLogin establishes a conservative boundary before the next launch.
// It records only the identity observed by an explicit add/login command,
// never a claim about the directory's older or already-running sessions.
func RecordLogin(home string) error {
	a, err := ReadAuth(home)
	if err != nil || a.Mode != "subscription" {
		return nil
	}
	return atomicJSON(filepath.Join(home, ".ccquota-login-observation.json"), loginObservation{Account: a.Identity.AccountUUID, Fingerprint: a.fingerprint, At: time.Now().UTC()})
}

func LoginObservedAt(home string, auth *Auth) time.Time {
	if auth == nil {
		return time.Time{}
	}
	b, err := os.ReadFile(filepath.Join(home, ".ccquota-login-observation.json"))
	if err != nil || len(b) > 16384 {
		return time.Time{}
	}
	var ob loginObservation
	if json.Unmarshal(b, &ob) != nil || ob.Account != auth.Identity.AccountUUID || ob.Fingerprint != auth.fingerprint || ob.At.After(time.Now()) {
		return time.Time{}
	}
	return ob.At
}
