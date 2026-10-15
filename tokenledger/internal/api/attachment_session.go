package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

func attachmentSessionKey(r *http.Request) string {
	if c, err := r.Cookie(authz.CookieName); err == nil && c.Value != "" {
		return "attachment:" + HashToken(c.Value)
	}
	return ""
}

func (s *Server) attachmentSessionLive(r *http.Request) bool {
	key := attachmentSessionKey(r)
	if key == "" {
		return false
	}
	revoked, err := s.Store.RevokedJTI(key, time.Now())
	return err == nil && !revoked
}

// The signed cookie itself stays out of storage. Expiring, indexed hashes let
// active attachments fail closed on logout, including on another hub replica.
func (s *Server) logoutAttachments(r *http.Request) error {
	key := attachmentSessionKey(r)
	if key == "" {
		return nil
	}
	sess, _, ok := s.personSession(r)
	if !ok {
		return nil
	}
	_, err := s.Store.AddRevocations([]store.Revocation{{JTI: key, Exp: sess.Exp, Src: key, Reason: "browser logout"}}, time.Now())
	return err
}
