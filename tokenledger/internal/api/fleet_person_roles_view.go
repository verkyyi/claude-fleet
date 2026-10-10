package api

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"sync"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/rolemerge"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The /config page's 「角色与规则」 (claude-fleet#2787, EPIC #2781 C6).
//
//   GET /v1/fleet/person-bundle/roles?merged=1
//
// The caller's own person layer — the same doors as the bundle itself —
// merged into the role definitions and rule table of the tree stable names:
// the release store's tree.tar.gz (agents/<role>.md, conf/agent-locked.list,
// conf/role-rules.default.md). The merge is internal/rolemerge, the Go copy
// of bin/fleet-role.py's, held to the same tests/role-merge vectors — so the
// page shows what `fleet role show <role> --sources` prints on a machine with
// no local layer. No release store, or stable not built yet ⇒ the person's
// layer alone, and `note` says why. Read-only: a change is a PUT of the layer.

func init() {
	rolemerge.SecretIn = func(v any) string { return secretIn("role", v) }
}

// roleTreeFiles are the stable tree's files the view reads.
var roleTreeFiles = func() []string {
	out := []string{"conf/agent-locked.list", "conf/role-rules.default.md"}
	for _, r := range rolemerge.Roles {
		out = append(out, "agents/"+r+".md")
	}
	return out
}()

// roleTreeCache keeps one stable's files: a tar is read once per sha.
type roleTreeCache struct {
	mu    sync.Mutex
	sha   string
	files map[string][]byte
}

// stableRoleTree is (stable's sha, its role files, "") or ("", nil, why not).
func (s *Server) stableRoleTree() (string, map[string][]byte, string) {
	if s.roleTreeFn != nil {
		return s.roleTreeFn()
	}
	if s.Releases == nil {
		return "", nil, "the hub keeps no releases (CCQUOTA_FLEET_RELEASE_KEY unset): only your layer is shown"
	}
	sha := s.Releases.StableSHA()
	if sha == "" {
		return "", nil, "the hub has seen no stable yet: only your layer is shown"
	}
	c := &s.roleTree
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.sha == sha {
		return sha, c.files, ""
	}
	dir := s.Releases.dir(sha)
	if dir == "" {
		return "", nil, fmt.Sprintf("stable %.7s is not built on the hub yet: only your layer is shown", sha)
	}
	tgz := filepath.Join(dir, release.TreeName)
	files := map[string][]byte{}
	for _, n := range roleTreeFiles {
		b, err := treeFile(tgz, n)
		if err != nil {
			log.Printf("fleet: release %.7s: read %s: %v", sha, n, err)
			return "", nil, fmt.Sprintf("stable %.7s's tree cannot be read: only your layer is shown", sha)
		}
		if b != nil {
			files[n] = b
		}
	}
	c.sha, c.files = sha, files
	return sha, files, ""
}

// PersonRoleDef is a definition as the frontmatter + body.
type PersonRoleDef struct {
	Front *rolemerge.OMap `json:"front"`
	Body  string          `json:"body"`
}

// PersonRole is one role in the merged view.
type PersonRole struct {
	// Fields / Body / Sources / Locked: the merge's answer (absent with no
	// built-in to merge into).
	Fields  *rolemerge.OMap `json:"fields,omitempty"`
	Body    string          `json:"body,omitempty"`
	Sources *rolemerge.OMap `json:"sources,omitempty"`
	Locked  []string        `json:"locked"`
	// Base is the built-in definition; Layer the person's, as read.
	Base  *PersonRoleDef `json:"base,omitempty"`
	Layer *PersonRoleDef `json:"layer,omitempty"`
	// Changed counts what the layer touches: each field it sets, and its body.
	Changed int `json:"changed"`
	// Problem: the layer is not used, and why (every machine refuses it too).
	Problem string `json:"problem,omitempty"`
}

// PersonRolesResponse is the merged view.
type PersonRolesResponse struct {
	Version int                   `json:"version"`
	Stable  string                `json:"stable,omitempty"`
	Note    string                `json:"note,omitempty"`
	Roles   map[string]PersonRole `json:"roles"`
	Rules   rolemerge.Table       `json:"rules"`
}

func (s *Server) writePersonRoles(w http.ResponseWriter, person string) {
	out := PersonRolesResponse{Roles: map[string]PersonRole{}}
	bundle := rolemerge.NewOMap()
	b, err := s.Store.PersonBundle(person, 0)
	switch {
	case errors.Is(err, store.ErrNoTeamBundle):
	case err != nil:
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	default:
		out.Version = b.Version
		if d, err := rolemerge.Decode([]byte(b.Bundle)); err == nil {
			if m, ok := d.(*rolemerge.OMap); ok {
				bundle = m
			}
		}
	}
	label := fmt.Sprintf("person:v%d", out.Version)
	sha, tree, note := s.stableRoleTree()
	out.Stable, out.Note = sha, note
	rv, _ := bundle.Get("roles")
	roles, _ := rv.(*rolemerge.OMap)
	for _, role := range rolemerge.Roles {
		pr := PersonRole{Locked: []string{}}
		var layers []rolemerge.Layer
		if ov, ok := roles.Get(role); ok {
			front, body, err := rolemerge.OverlayOf(ov)
			if err != nil {
				pr.Problem = err.Error()
			} else {
				bs, _ := body.(string)
				pr.Layer = &PersonRoleDef{Front: front, Body: bs}
				for _, k := range front.Keys {
					if k != "name" && k != "body" {
						pr.Changed++
					}
				}
				if bs != "" {
					pr.Changed++
				}
				if why := rolemerge.CheckOverlay(role, front, body); why != "" {
					pr.Problem = why
				} else {
					layers = append(layers, rolemerge.Layer{Label: label, Kind: "person", Front: front, Body: bs})
				}
			}
		}
		if raw, ok := tree["agents/"+role+".md"]; ok {
			bf, bb, err := rolemerge.Parse(string(raw))
			if err != nil {
				pr.Problem = "the built-in definition: " + err.Error()
			} else {
				m := rolemerge.Merge(bf, bb, layers, rolemerge.RoleLocks(role, string(tree["conf/agent-locked.list"])))
				pr.Fields, pr.Body, pr.Sources, pr.Locked = m.Fields, m.Body, m.Sources, m.Locked
				pr.Base = &PersonRoleDef{Front: bf, Body: bb}
			}
		}
		out.Roles[role] = pr
	}
	pv, _ := bundle.Get("rules")
	plabel := fmt.Sprintf("你的 v%d", out.Version)
	if def, ok := tree["conf/role-rules.default.md"]; ok {
		t, err := rolemerge.MergeRules(string(def), pv, plabel)
		if err != nil {
			t = rolemerge.Table{Rows: []rolemerge.Rule{}, Layers: []rolemerge.RuleLayer{}, Problems: []string{err.Error()}}
		}
		out.Rules = t
	} else {
		// No built-in table to merge into: the person's rows alone, unversioned.
		out.Rules = rolemerge.Table{Rows: []rolemerge.Rule{}, Layers: []rolemerge.RuleLayer{}, Problems: []string{}}
		rows, err := rolemerge.PersonRules(pv)
		if err != nil {
			out.Rules.Problems = append(out.Rules.Problems, "person layer not used: "+err.Error())
		}
		for _, r := range rows {
			r.Source = plabel
			out.Rules.Rows = append(out.Rules.Rows, r)
		}
	}
	writeJSON(w, http.StatusOK, out)
}
