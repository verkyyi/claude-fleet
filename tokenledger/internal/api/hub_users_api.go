package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The people list, on the web and from `fleet users` (claude-fleet#1986,
// EPIC #1982 C4): an admin adds a GitHub username and that account can sign
// in on its next try; removing one refuses their next request and revokes
// their devices' certificates. No deploy file changes either way.
//
//	GET    /v1/fleet/users                     the list (+ the deploy's admins)
//	POST   /v1/fleet/users {login, machine_login?}
//	DELETE /v1/fleet/users?login=<name>        (or a {login} body)
//
// Adding asks GitHub's public API for the name's ID at once and pins it
// (EPIC #1982 rule 4): a name GitHub does not know is refused, never added.
// The deploy's admins (CCQUOTA_GITHUB_ADMINS) are read-only here — they are
// listed, never added, changed into users or removed.

// githubLoginRE is a GitHub username's shape: letters, digits and single
// hyphens, at most 39, not starting with a hyphen.
var githubLoginRE = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$`)

// hubUserView is one row of GET /v1/fleet/users.
type hubUserView struct {
	store.HubUser
	Principal string `json:"principal"`
	// Deploy marks an admin CCQUOTA_GITHUB_ADMINS names: read-only here.
	Deploy bool `json:"deploy,omitempty"`
}

// deployAdminView is one name of CCQUOTA_GITHUB_ADMINS and whether it is
// pinned to a GitHub ID yet.
type deployAdminView struct {
	Login    string `json:"login"`
	GitHubID int64  `json:"github_id,omitempty"`
	Pinned   bool   `json:"pinned"`
}

func (s *Server) handleFleetUsers(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if s.Store == nil {
		httpError(w, http.StatusServiceUnavailable, "no database")
		return
	}
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		s.writeFleetUsers(w, http.StatusOK, nil)
	case http.MethodPost:
		s.addFleetUser(w, r)
	case http.MethodDelete:
		s.removeFleetUser(w, r)
	default:
		w.Header().Set("Allow", "GET, POST, DELETE")
		httpError(w, http.StatusMethodNotAllowed, "GET, POST or DELETE")
	}
}

// writeFleetUsers answers with the whole list; extra fields join the body.
func (s *Server) writeFleetUsers(w http.ResponseWriter, status int, extra map[string]any) {
	users, err := s.Store.HubUsers()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]hubUserView, 0, len(users))
	for _, u := range users {
		v := hubUserView{HubUser: u, Principal: githubPrincipal(u.GitHubID)}
		if role, err := s.githubRole(u.GitHubID); err == nil && role == roleAdmin {
			v.Deploy = true
		}
		out = append(out, v)
	}
	admins := []deployAdminView{}
	for _, name := range s.githubAdmins() {
		a := deployAdminView{Login: strings.TrimSpace(name)}
		if id, ok, err := s.Store.PinnedID(a.Login); err == nil && ok {
			a.GitHubID, a.Pinned = id, true
		}
		admins = append(admins, a)
	}
	body := map[string]any{"users": out, "admins": admins}
	for k, v := range extra {
		body[k] = v
	}
	writeJSON(w, status, body)
}

// githubAdmins is CCQUOTA_GITHUB_ADMINS, nil without GitHub sign-in.
func (s *Server) githubAdmins() []string {
	if s.GitHub == nil {
		return nil
	}
	return s.GitHub.Admins
}

// userRequest reads {login, machine_login} from the body, or login from the
// query string.
func userRequest(w http.ResponseWriter, r *http.Request) (login, machineLogin string, ok bool) {
	var body struct {
		Login        string `json:"login"`
		MachineLogin string `json:"machine_login"`
	}
	if r.Body != nil {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
			httpError(w, http.StatusBadRequest, "body must be {\"login\": \"<GitHub username>\"}")
			return "", "", false
		}
	}
	login = strings.TrimPrefix(strings.TrimSpace(body.Login), "@")
	if login == "" {
		login = strings.TrimPrefix(strings.TrimSpace(r.URL.Query().Get("login")), "@")
	}
	if !githubLoginRE.MatchString(login) {
		httpError(w, http.StatusBadRequest, fmt.Sprintf("%q is not a GitHub username", login))
		return "", "", false
	}
	return login, strings.TrimSpace(body.MachineLogin), true
}

func (s *Server) addFleetUser(w http.ResponseWriter, r *http.Request) {
	login, machineLogin, ok := userRequest(w, r)
	if !ok {
		return
	}
	actor, now := actorOf(r), time.Now()
	if s.GitHub.isAdminName(login) {
		httpError(w, http.StatusConflict, login+" is an admin the deploy names (CCQUOTA_GITHUB_ADMINS) — read-only here")
		return
	}
	id, canonical, err := s.githubLookup(r.Context(), login)
	if err != nil {
		if strings.Contains(err.Error(), "HTTP 404") {
			_ = s.Store.HubAudit(actor, "user.add", login, "refused", "no such GitHub user", now)
			httpError(w, http.StatusBadRequest, "GitHub has no user named "+login+" — nobody was added")
			return
		}
		httpError(w, http.StatusBadGateway, "could not ask GitHub who "+login+" is: "+err.Error())
		return
	}
	target := canonical + " (" + githubPrincipal(id) + ")"
	if role, err := s.githubRole(id); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if role == roleAdmin {
		httpError(w, http.StatusConflict, canonical+" is an admin the deploy names — read-only here")
		return
	}
	for _, name := range []string{login, canonical} {
		if err := s.pinName(name, id, actor, now); err != nil {
			if errors.Is(err, store.ErrPinConflict) {
				pinned, _, _ := s.Store.PinnedID(name)
				_ = s.Store.HubAudit(actor, "user.add", target, "refused",
					fmt.Sprintf("username %s is pinned to GitHub ID %d", name, pinned), now)
				httpError(w, http.StatusConflict, fmt.Sprintf("the username %s already means GitHub ID %d here — not added", name, pinned))
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	existing, err := s.Store.HubUserByID(id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	created := existing == nil
	row := store.HubUser{GitHubID: id, Login: canonical, Role: roleUser, AddedBy: actor, AddedAt: now}
	if existing != nil {
		row = *existing
		row.Login, row.Role = canonical, roleUser
	}
	if err := s.Store.UpsertHubUser(row); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if created {
		_ = s.Store.HubAudit(actor, "user.add", target, "ok", "as user", now)
		log.Printf("hub users: %s added by %s", target, actor)
	}
	if machineLogin != "" {
		if code, why := s.putHubSetting(actor, machineLoginSettingKey(githubPrincipal(id)), machineLogin, now); code != http.StatusOK {
			httpError(w, code, "added "+canonical+", but the machine login was refused: "+why)
			return
		}
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	s.writeFleetUsers(w, status, map[string]any{"added": canonical, "github_id": id, "created": created})
}

func (s *Server) removeFleetUser(w http.ResponseWriter, r *http.Request) {
	login, _, ok := userRequest(w, r)
	if !ok {
		return
	}
	actor, now := actorOf(r), time.Now()
	id, known, err := s.Store.PinnedID(login)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !known {
		// A row whose name was never pinned under this spelling: find it by
		// the username it carries.
		users, err := s.Store.HubUsers()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		for _, u := range users {
			if strings.EqualFold(u.Login, login) {
				id, known = u.GitHubID, true
				break
			}
		}
	}
	if !known {
		httpError(w, http.StatusNotFound, login+" is not on the list")
		return
	}
	target := login + " (" + githubPrincipal(id) + ")"
	if role, err := s.githubRole(id); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if role == roleAdmin || s.GitHub.isAdminName(login) {
		_ = s.Store.HubAudit(actor, "user.remove", target, "refused", "an admin the deploy names", now)
		httpError(w, http.StatusForbidden, login+" is an admin the deploy names (CCQUOTA_GITHUB_ADMINS) — read-only here")
		return
	}
	removed, err := s.Store.DeleteHubUser(id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !removed {
		httpError(w, http.StatusNotFound, login+" is not on the list")
		return
	}
	revoked := s.revokePersonDevices(githubPrincipal(id), actor, now)
	_ = s.Store.HubAudit(actor, "user.remove", target, "ok", fmt.Sprintf("%d device(s) revoked", revoked), now)
	log.Printf("hub users: %s removed by %s (%d device(s) revoked)", target, actor, revoked)
	s.writeFleetUsers(w, http.StatusOK, map[string]any{"removed": login, "github_id": id, "devices_revoked": revoked})
}

// revokePersonDevices revokes every device registered to principal, so its
// certificate stops renewing and the hub's doors refuse it at once. The
// number revoked; without the fleet module there are no devices.
func (s *Server) revokePersonDevices(principal, actor string, now time.Time) int {
	if !s.Fleet {
		return 0
	}
	devs, err := s.Store.Devices(principal, 0)
	if err != nil {
		log.Printf("hub users: devices of %s: %v", principal, err)
		return 0
	}
	n := 0
	for _, d := range devs {
		if d.Revoked() {
			continue
		}
		changed, err := s.Store.RevokeDevice(d.Fingerprint, actor, now)
		if err != nil {
			log.Printf("hub users: revoke %s of %s: %v", d.Fingerprint, principal, err)
			continue
		}
		if changed {
			n++
			s.deviceAudit(store.DeviceRevoke, d.Fingerprint, principal, actor, "taken off the list; name "+d.Name, now)
		}
	}
	return n
}
