package api

import (
	"net/http"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// The website's front page inside WeChat (T794): the page asks who is looking
// through the service account's silent authorisation (snsapi_base, the relay
// road of wx_relay.go — no prompt, no code) and the answer comes back to the
// page itself instead of the console or /apply, so its card can say 「欢迎回来」
// to a member and offer one tap to apply to anyone else. Applying is still the
// person's tap: nothing here submits a request.

// ApplicantPath is the front page's question «who is this applicant» — the
// note's name, whether the service account can reach them, whether they have
// asked already. Under /apply: the note's cookie goes nowhere else.
const ApplicantPath = ApplyPath + "/me"

// homeNext is next when it is one of the website's front pages, else "".
func homeNext(next string) string {
	switch next {
	case "/", "/en/":
		return next
	}
	return ""
}

// homeReturn sends a landing that would go to the console or /apply back to
// the front page the silent start came from; any other hop (a trial, a
// refusal, an error back to /signin) goes where it was going.
type homeReturn struct {
	http.ResponseWriter
	next string
}

func (h *homeReturn) WriteHeader(code int) {
	if code == http.StatusFound || code == http.StatusSeeOther {
		switch h.Header().Get("Location") {
		case AppPrefix, AppPrefix + "/", ApplyPath:
			h.Header().Set("Location", h.next)
		}
	}
	h.ResponseWriter.WriteHeader(code)
}

type applicantInfo struct {
	Name     string `json:"name"`
	Followed bool   `json:"followed"`
	Applied  bool   `json:"applied"`
}

// handleApplicant answers GET /apply/me for the applicant note this
// browser carries; 401 without one.
func (s *Server) handleApplicant(w http.ResponseWriter, r *http.Request) {
	if s.Store == nil || !s.signinOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	a, ok := s.applicantFrom(r)
	if !ok {
		httpError(w, http.StatusUnauthorized, "no applicant here")
		return
	}
	out := applicantInfo{Name: applicantName(a.Display)}
	if isWeChatKind(a.Kind) {
		if rs, err := s.Store.HubReachOf(store.ApplicantReachOwner(a.Kind, a.Subject)); err == nil {
			for _, x := range rs {
				out.Followed = out.Followed || (x.Channel == store.ReachWeChatMP && x.Followed)
			}
		}
	}
	if rs, err := s.Store.Requests().ByIdentity(a.Kind, a.Subject); err == nil && len(rs) > 0 {
		out.Applied = true
	}
	writeJSON(w, http.StatusOK, out)
}

// applicantName is the name to greet: "" for the stand-in wxLand makes when
// WeChat gave none (「微信用户·1a2b」).
func applicantName(display string) string {
	d := strings.TrimSpace(display)
	for _, loc := range []string{i18n.ZhCN, i18n.EN} {
		if strings.HasPrefix(d, pageT(loc, "wx.user")+"·") {
			return ""
		}
	}
	return d
}
