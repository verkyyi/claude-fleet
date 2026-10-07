package codex

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// upstreamFile is the last verdict an upstream gave on a home's access token
// (claude-fleet#1920). The clock says when a token expires; only the upstream
// can say it was revoked before then — a hub lease read token_revoked with a
// week left on its exp while `ccquota codex list` called it valid. Written by
// whatever actually spoke to the upstream with this home's token (the agent's
// quota poll, the fleet credential proxy), read by LoginHealth. Keyed by the
// credential fingerprint, so a new auth.json (a renewed lease, a re-login)
// outdates it without anyone deleting it. Holds no token and no message.
const upstreamFile = ".ccquota-upstream.json"

type upstreamVerdict struct {
	Fingerprint string    `json:"credential_version"`
	State       string    `json:"state"`           // "rejected" | "accepted"
	Error       string    `json:"error,omitempty"` // the upstream's code (token_revoked, …) or "401"
	At          time.Time `json:"at"`
	By          string    `json:"by,omitempty"` // "agent" | "proxy"
}

func readUpstream(home string) upstreamVerdict {
	var v upstreamVerdict
	b, err := os.ReadFile(filepath.Join(home, upstreamFile))
	if err == nil && len(b) < 4096 {
		_ = json.Unmarshal(b, &v)
	}
	return v
}

// RecordUpstream saves the verdict one Query got on auth: rejected when the
// upstream refused the access token, accepted when it answered the quota
// read. Anything else (a network error, an expired token never sent, a CLI
// that cannot start) says nothing about the credential and is not recorded.
// An unchanged verdict is not rewritten.
func RecordUpstream(home string, auth *Auth, result Result, err error) error {
	if auth == nil || auth.fingerprint == "" {
		return nil
	}
	if result.rejected != nil {
		err = result.rejected
	}
	v := upstreamVerdict{Fingerprint: auth.fingerprint, At: time.Now().UTC(), By: "agent"}
	var re *rpcError
	switch {
	case errors.As(err, &re) && re.unauthorized && !re.reauth:
		v.State, v.Error = "rejected", re.authCode
		if v.Error == "" {
			v.Error = "401"
		}
	case result.Quota != nil:
		v.State = "accepted"
	default:
		return nil
	}
	old := readUpstream(home)
	if old.Fingerprint == v.Fingerprint && old.State == v.State && old.Error == v.Error {
		return nil
	}
	if old.Fingerprint != v.Fingerprint && v.State == "accepted" {
		return nil // nothing on record for this credential to clear
	}
	return atomicJSON(filepath.Join(home, upstreamFile), v)
}

// upstreamRejection is the standing refusal of this exact credential, if any.
func upstreamRejection(home string, auth *Auth) *upstreamVerdict {
	v := readUpstream(home)
	if v.State != "rejected" || v.Fingerprint == "" || v.Fingerprint != auth.fingerprint {
		return nil
	}
	return &v
}
