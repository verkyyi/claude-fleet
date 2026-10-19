package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/rolemerge"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Template registration (claude-fleet#4032, the SPACE EPIC's contract 9): once
// a template merges, the service's CI registers its agent.md here with
// templates:write. A template is its sha256 — the digest is computed here,
// never taken from the caller — so registering the same text again is the same
// row, and a changed text is a new digest beside the old one, which stays.
// Only a registered digest is ever started (svc_runner.go). A principal sees
// and runs only its own.

const (
	SvcTemplatesPath = "/v1/svc/templates"

	svcTemplateMax = 256 << 10
)

// SvcTemplateRequest is POST /v1/svc/templates.
type SvcTemplateRequest struct {
	Name    string `json:"name"`
	AgentMD string `json:"agent_md"`
}

// SvcTemplateView is a registered template as its principal reads it — never
// its text.
type SvcTemplateView struct {
	Name    string    `json:"name"`
	Digest  string    `json:"digest"`
	Created time.Time `json:"created"`
}

// SvcTemplateDigest is the digest a template's text registers under.
func SvcTemplateDigest(agentMD string) string {
	sum := sha256.Sum256([]byte(agentMD))
	return hex.EncodeToString(sum[:])
}

// svcTemplateName is the frontmatter name of an agent.md, or why it has none.
func svcTemplateName(agentMD string) (string, string) {
	if !utf8.ValidString(agentMD) {
		return "", "agent_md is not UTF-8"
	}
	front, _, err := rolemerge.Parse(strings.ReplaceAll(agentMD, "\r\n", "\n"))
	if err != nil {
		return "", "agent_md's frontmatter: " + err.Error()
	}
	v, _ := front.Get("name")
	name, _ := v.(string)
	if !svcWord(name, 100) {
		return "", "agent_md has no frontmatter name (one word of at most 100 bytes)"
	}
	return name, ""
}

func (s *Server) svcTemplatesMux(m *http.ServeMux) {
	list := s.svcOnly(store.SvcRunsRead, http.HandlerFunc(s.handleSvcTemplatesList))
	put := s.svcOnly(store.SvcTemplatesWrite, http.HandlerFunc(s.handleSvcTemplatePut))
	m.Handle(SvcTemplatesPath, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			list.ServeHTTP(w, r)
		case http.MethodPost:
			put.ServeHTTP(w, r)
		default:
			w.Header().Set("Allow", "GET, POST")
			httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		}
	}))
}

func (s *Server) handleSvcTemplatePut(w http.ResponseWriter, r *http.Request) {
	p, _, _ := SvcCallerOf(r.Context())
	now := time.Now()
	var req SvcTemplateRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2*svcTemplateMax+16<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return
	}
	if req.AgentMD == "" {
		httpError(w, http.StatusBadRequest, "agent_md is required")
		return
	}
	if len(req.AgentMD) > svcTemplateMax {
		httpError(w, http.StatusRequestEntityTooLarge, "agent_md is larger than 256 KiB")
		return
	}
	name, why := svcTemplateName(req.AgentMD)
	if why != "" {
		httpError(w, http.StatusBadRequest, why)
		return
	}
	if req.Name != "" && req.Name != name {
		httpError(w, http.StatusBadRequest, "name is "+req.Name+" but agent_md's frontmatter says "+name)
		return
	}
	digest := SvcTemplateDigest(req.AgentMD)
	if err := s.Store.PutSvcTemplate(store.SvcTemplate{Principal: p.ID, Digest: digest, Name: name,
		AgentMD: req.AgentMD}, now); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	t, err := s.Store.SvcTemplateOf(p.ID, digest)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.svcAudit(p.ID, "svc.template.put", t.Name+"@"+digest, "ok", "", now)
	writeJSON(w, http.StatusOK, SvcTemplateView{Name: t.Name, Digest: t.Digest, Created: t.Created})
}

func (s *Server) handleSvcTemplatesList(w http.ResponseWriter, r *http.Request) {
	p, _, _ := SvcCallerOf(r.Context())
	ts, err := s.Store.SvcTemplates(p.ID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]SvcTemplateView, 0, len(ts))
	for _, t := range ts {
		out = append(out, SvcTemplateView{Name: t.Name, Digest: t.Digest, Created: t.Created})
	}
	writeJSON(w, http.StatusOK, map[string]any{"templates": out})
}
