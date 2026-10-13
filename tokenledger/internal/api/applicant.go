package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

// The applicant (EPIC #4048 共同约定 6): a person whose sign-in worked but
// whom the list does not name gets no principal and no /app session — only
// ccq_applicant, a signed note of the way they came in (kind, subject,
// display) that /apply reads and nothing else does. Its path is /apply, so a
// browser never even sends it to /app, /v1 or /admin, and the only reader is
// applicantFrom: every other route treats its holder as signed out (BREAK-IT
// apply-reaches-app). The sign-in branches that mint it are C2's (#4050);
// C3 (#4051) landed first and left both halves here.

const (
	applicantCookie = "ccq_applicant"
	applicantPath   = "/apply"
	applicantTTL    = 7 * 24 * time.Hour
)

// applicant is who /apply is talking to.
type applicant struct {
	Kind    string `json:"k"`
	Subject string `json:"s"`
	Display string `json:"d"`
	Exp     int64  `json:"e"`
}

// applicantMAC signs an applicant note: its own label, so no other signed
// blob of a sign-in (signBlob's "flow.") can stand in for one.
func applicantMAC(enc, key string) []byte {
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte("applicant." + enc))
	return m.Sum(nil)
}

// issueApplicant gives this browser the applicant note for (kind, subject),
// called display, for seven days.
func (s *Server) issueApplicant(w http.ResponseWriter, r *http.Request, kind, subject, display string) {
	body, _ := json.Marshal(applicant{Kind: kind, Subject: subject, Display: display,
		Exp: time.Now().Add(applicantTTL).Unix()})
	enc := base64.RawURLEncoding.EncodeToString(body)
	v := enc + "." + base64.RawURLEncoding.EncodeToString(applicantMAC(enc, s.sessionKey()))
	http.SetCookie(w, &http.Cookie{
		Name: applicantCookie, Value: v, Path: applicantPath,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
		MaxAge: int(applicantTTL.Seconds()),
	})
}

// applicantFrom is the applicant r carries, if its note is this hub's,
// unexpired and whole. The ONE reader of ccq_applicant.
func (s *Server) applicantFrom(r *http.Request) (applicant, bool) {
	c, err := r.Cookie(applicantCookie)
	if err != nil || !s.signinOn() {
		return applicant{}, false
	}
	enc, sig64, ok := strings.Cut(c.Value, ".")
	if !ok {
		return applicant{}, false
	}
	sig, err := base64.RawURLEncoding.DecodeString(sig64)
	if err != nil || !hmac.Equal(sig, applicantMAC(enc, s.sessionKey())) {
		return applicant{}, false
	}
	body, err := base64.RawURLEncoding.DecodeString(enc)
	if err != nil {
		return applicant{}, false
	}
	var a applicant
	if json.Unmarshal(body, &a) != nil || a.Kind == "" || strings.TrimSpace(a.Subject) == "" ||
		a.Exp < time.Now().Unix() {
		return applicant{}, false
	}
	return a, true
}
