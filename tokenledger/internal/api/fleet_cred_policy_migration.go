package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

type policyMigrationObject struct {
	Key   string `json:"key"`
	Scope string `json:"scope"`
	ID    string `json:"id"`
	Label string `json:"label"`
}
type policyMigration struct {
	Revision string                  `json:"revision"`
	Objects  []policyMigrationObject `json:"objects"`
}

// Only absent rules need a decision. Existing lists, denials and malformed
// rules are preserved. Unknown identities are never converted into grants.
func (s *Server) credPolicyReview(settings map[string]string) (policyMigration, error) {
	review := policyMigration{Objects: []policyMigrationObject{}}
	people, err := s.Store.Principals()
	if err != nil {
		return review, err
	}
	peopleByID := map[string]string{}
	for _, p := range people {
		if p.ID != store.PoolPrincipal {
			peopleByID[p.ID] = p.Login
		}
	}
	registered, err := s.Store.HubUsers()
	if err != nil {
		return review, err
	}
	for _, u := range registered {
		peopleByID[githubPrincipal(u.GitHubID)] = u.Login
	}
	for id, label := range peopleByID {
		k := credUserKey(id)
		if _, ok := settings[k]; !ok {
			review.Objects = append(review.Objects, policyMigrationObject{k, "user", id, label})
		}
	}
	trusts, _, err := s.Store.EndpointTrusts()
	if err != nil {
		return review, err
	}
	// Use the roster's shared role classifier. Offline hosts still count;
	// where several names normalize to one machine, any hosting login wins.
	snapshot, err := s.Nodes(time.Now())
	if err != nil {
		return review, err
	}
	byMachine := map[string][]NodeView{}
	for _, node := range snapshot.Nodes {
		ep, known := trusts[node.EndpointID]
		if !known {
			continue
		}
		// Display hostnames can change. Join through the endpoint's enrolled
		// identity, exactly as credential authorization does.
		m := strings.ToLower(firstLabel(ep.EnrolledHost))
		node.Hostname = m
		byMachine[m] = append(byMachine[m], node)
	}
	roles := map[string]string{}
	for m, nodes := range byMachine {
		roles[m] = machineRole(MachineView{Hostname: m}, nodes)
	}
	seen := map[string]bool{}
	for _, ep := range trusts {
		m := strings.ToLower(firstLabel(ep.EnrolledHost))
		if m == "" || m == "?" || seen[m] || roles[m] == MachineRoleClient {
			continue
		}
		seen[m] = true
		k := credNodeKey(m)
		if _, ok := settings[k]; !ok {
			review.Objects = append(review.Objects, policyMigrationObject{k, "node", m, m})
		}
	}
	sort.Slice(review.Objects, func(i, j int) bool { return review.Objects[i].Key < review.Objects[j].Key })
	relevant := map[string]string{}
	for k, v := range settings {
		if strings.HasPrefix(k, "fleet.cred_allow.") || k == CredPolicyModeKey {
			relevant[k] = v
		}
	}
	raw, _ := json.Marshal([]any{relevant, review.Objects})
	sum := sha256.Sum256(raw)
	review.Revision = hex.EncodeToString(sum[:])
	return review, nil
}
func (s *Server) activateCredPolicy(w http.ResponseWriter, r *http.Request, req CredPolicyPut) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	if settings[CredPolicyModeKey] != "legacy" {
		httpError(w, 409, "strict mode already active")
		return
	}
	review, err := s.credPolicyReview(settings)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	if req.Revision == "" || req.Revision != review.Revision {
		httpError(w, 409, "objects or permissions changed; review again")
		return
	}
	allowed := map[string]bool{}
	for _, o := range review.Objects {
		allowed[o.Key] = true
	}
	grants := []string{}
	seen := map[string]bool{}
	for _, k := range req.Retain {
		if !allowed[k] {
			httpError(w, 400, "retain contains an object outside the review")
			return
		}
		if !seen[k] {
			seen[k] = true
			grants = append(grants, k)
		}
	}
	err = s.Store.ActivateCredPolicy(settings, grants, actorOf(r), time.Now())
	if errors.Is(err, store.ErrCredPolicyChanged) {
		httpError(w, 409, err.Error())
		return
	}
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	s.sessCred.drop("")
	writeJSON(w, 200, map[string]any{"ok": true, "mode": "strict"})
}
