package api

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The direct door's book on the hub (claude-fleet#3068, EPIC #3067 C1).
//
// Each person keeps their public keys, one address name and one home (the
// machine + login their address points at) here; the home machine keeps the
// door's key files from it. Nothing here is a credential: a public key is
// public, and a private key pasted by mistake is refused before it is parsed,
// stored or logged.
//
// A person's doors (their session, or an admin's on their own book):
//
//	GET    /v1/fleet/entry/keys            keys · name · home · the homes they may pick
//	POST   /v1/fleet/entry/keys            {public_key, name?}
//	PATCH  /v1/fleet/entry/keys/<id>       {name}       a label (the home sees it with its next list)
//	DELETE /v1/fleet/entry/keys/<id>       revoke
//	PUT    /v1/fleet/entry/name            {name}
//	PUT    /v1/fleet/entry/home            {machine, login?}  only a login with a live fleet
//
// The operator names the person (?principal=) and may read, revoke and move a
// home — never add a key or pick a name for someone.
//
// A machine's doors (its node program's machine token, claude-fleet#2333):
//
//	GET  /v1/node/entry-keys    every login homed on it, with its live keys
//	POST /v1/node/entry-audit   the door's record, sent late when the hub was away
//
// Every change a home machine must hear moves one version up and pushes
// entry_keys {version} to the machines it concerns (CapEntryKeys). With
// fleet.entry off (the default) every door answers 404 and nothing is pushed.

// EntryKey is the hub setting that switches the direct door's book on.
const EntryKey = "fleet.entry"

// entryNameRE is an address name: 3–20 of a-z 0-9 -, no dash at either end.
var entryNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$`)

// entryNameReserved are names nobody gets.
var entryNameReserved = map[string]bool{"ssh": true, "www": true, "hub": true, "admin": true, "api": true, "fleet": true, "root": true}

// entryKeyMax bounds one pasted key; a 16384-bit RSA key fits.
const entryKeyMax = 16 << 10

// entryAuditMax is how many lines one late batch may carry.
const entryAuditMax = 500

var (
	errEntryPrivate = errors.New("这是一把私钥：私钥从不离开你的设备，请贴它的公钥（.pub 那一行）。刚才贴的内容没有保存")
	errEntryOptions = errors.New("只贴一行公钥：<种类> <内容> [备注]，不要带 command= 之类的选项")
)

// entryOn reports whether the direct door's book is switched on.
func (s *Server) entryOn() bool { return s.settingOn(EntryKey) }

// entryLooksPrivate is a pasted private key, in any of the common shapes.
func entryLooksPrivate(text string) bool {
	u := strings.ToUpper(text)
	return strings.Contains(u, "PRIVATE KEY") || strings.Contains(u, "PUTTY-USER-KEY-FILE") ||
		strings.Contains(u, "BEGIN OPENSSH") || strings.Contains(u, "SSH2 ENCRYPTED")
}

// parseEntryKey checks one authorized_keys line: ed25519, ecdsa, or rsa of at
// least 3072 bits; no options, no certificate, one key. It returns the
// key's type, its base64 body, its SHA256 fingerprint and its comment.
func parseEntryKey(line string) (typ, b64, fp, comment string, err error) {
	line = strings.TrimSpace(line)
	if entryLooksPrivate(line) {
		return "", "", "", "", errEntryPrivate
	}
	if line == "" {
		return "", "", "", "", errors.New("贴一行公钥")
	}
	if len(line) > entryKeyMax {
		return "", "", "", "", errors.New("公钥太长")
	}
	pub, comment, opts, rest, perr := ssh.ParseAuthorizedKey([]byte(line))
	if perr != nil {
		return "", "", "", "", errors.New("看不懂这一行：贴 ssh-ed25519 / ecdsa-sha2-… / ssh-rsa 开头的一整行公钥")
	}
	if len(opts) > 0 {
		return "", "", "", "", errEntryOptions
	}
	if len(strings.TrimSpace(string(rest))) > 0 {
		return "", "", "", "", errors.New("一次只贴一把钥匙")
	}
	if _, cert := pub.(*ssh.Certificate); cert {
		return "", "", "", "", errors.New("这是一张证书，不是钥匙：贴公钥本身")
	}
	switch pub.Type() {
	case ssh.KeyAlgoED25519, ssh.KeyAlgoECDSA256, ssh.KeyAlgoECDSA384, ssh.KeyAlgoECDSA521:
	case ssh.KeyAlgoRSA:
		cpk, ok := pub.(ssh.CryptoPublicKey)
		rk, ok2 := (*rsa.PublicKey)(nil), false
		if ok {
			rk, ok2 = cpk.CryptoPublicKey().(*rsa.PublicKey)
		}
		if !ok2 || rk.N.BitLen() < 3072 {
			return "", "", "", "", errors.New("RSA 钥匙至少 3072 位；更好的是 ed25519")
		}
	default:
		return "", "", "", "", fmt.Errorf("不收 %s：用 ed25519、ecdsa 或 3072 位以上的 RSA", pub.Type())
	}
	return pub.Type(), base64.StdEncoding.EncodeToString(pub.Marshal()), ssh.FingerprintSHA256(pub), strings.TrimSpace(comment), nil
}

// entryLabel cleans a key's label: one line, at most 40 characters.
func entryLabel(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 40 {
		s = string(r[:40])
	}
	return s
}

// entryNameCheck says why name cannot be an address, "" when it can.
func entryNameCheck(name string) string {
	switch {
	case !entryNameRE.MatchString(name):
		return "名字是 3–20 个小写字母、数字或「-」，不以「-」开头或结尾"
	case entryNameReserved[name]:
		return "「" + name + "」留作他用，换一个"
	}
	return ""
}

// entrySuggestName turns a sign-in name into an address name, "" when it
// cannot be one.
func entrySuggestName(login string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(login) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	n := strings.Trim(b.String(), "-")
	if len(n) > 20 {
		n = strings.TrimRight(n[:20], "-")
	}
	if entryNameCheck(n) != "" {
		return ""
	}
	return n
}

func entryID(prefix string) string {
	b := make([]byte, 9)
	_, _ = rand.Read(b)
	return prefix + hex.EncodeToString(b)
}

// entryCaller is who is asking and whose book it is.
type entryCaller struct {
	actor    string
	operator bool
	person   string
}

// entryCallerOf authenticates a person's door and resolves whose book: the
// caller's own, or for the operator the one ?principal= names. ok=false has
// answered already.
func (s *Server) entryCallerOf(w http.ResponseWriter, r *http.Request) (entryCaller, bool) {
	w.Header().Set("Cache-Control", "no-store")
	if !s.entryOn() {
		httpError(w, http.StatusNotFound, "the direct door is off on this hub ("+EntryKey+")")
		return entryCaller{}, false
	}
	id, ok := s.sshRelayHTTPIdentity(r)
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "sign in first")
		return entryCaller{}, false
	}
	want := strings.TrimSpace(r.URL.Query().Get("principal"))
	c := entryCaller{actor: id.Actor, person: id.Principal}
	if id.Admin && (want == "" || strings.EqualFold(want, id.Actor)) {
		c.person = id.Actor // an admin's own book is theirs as anyone's is
	} else if id.Operator {
		if want == "" {
			httpError(w, http.StatusBadRequest, "the operator names the person: ?principal=<id>")
			return entryCaller{}, false
		}
		c.operator, c.person = true, want
	} else if want != "" {
		// Someone else's book does not exist for this caller.
		if q, err := s.Store.Principal(want); err != nil || !strings.EqualFold(q.ID, id.Principal) {
			httpError(w, http.StatusNotFound, "no such person")
			return entryCaller{}, false
		}
	}
	p, err := s.Store.Principal(c.person)
	switch {
	case errors.Is(err, store.ErrNoPrincipal):
		httpError(w, http.StatusNotFound, "no such person")
		return entryCaller{}, false
	case err != nil:
		httpError(w, http.StatusInternalServerError, err.Error())
		return entryCaller{}, false
	}
	c.person = p.ID
	return c, true
}

func (s *Server) entryAudit(a store.EntryAudit) {
	if a.ID == "" {
		a.ID = entryID("ea_")
	}
	if _, err := s.Store.AddEntryAudit([]store.EntryAudit{a}); err != nil {
		log.Printf("entry audit: %v", err)
	}
}

// EntryHomeChoice is one (machine, login) a person may make their home.
type EntryHomeChoice struct {
	Machine string `json:"machine"`
	Login   string `json:"login"`
	Online  bool   `json:"online"`
}

// EntryView is GET EntryKeysPath's answer.
type EntryView struct {
	Person        string            `json:"person"`
	Name          string            `json:"name,omitempty"`
	SuggestedName string            `json:"suggested_name,omitempty"`
	Home          *store.EntryHome  `json:"home"`
	HomeChoices   []EntryHomeChoice `json:"home_choices"`
	Keys          []store.EntryKey  `json:"keys"`
	Version       int               `json:"version"`
}

// entryHomeChoices is every (machine, login) of person's that has a live
// fleet on it right now: an active login of theirs on that machine, the
// fleet registered there, its node not lost. A fleet admin's login never is.
func (s *Server) entryHomeChoices(person string, now time.Time) ([]EntryHomeChoice, error) {
	_, _, byHost, err := s.managedLoginsOf(person)
	if err != nil {
		return nil, err
	}
	rows, err := s.Store.Fleets()
	if err != nil {
		return nil, err
	}
	avail := s.nodeAvailability(now)
	seen := map[string]bool{}
	out := []EntryHomeChoice{}
	for _, r := range rows {
		if !r.Present || r.OSUser == "" || s.isFleetAdmin(r.OSUser) {
			continue
		}
		a := avail[r.EndpointID]
		if a == "" || a == "lost" {
			continue
		}
		for h, login := range byHost {
			if login != r.OSUser || !sameMachine(r.Hostname, h) {
				continue
			}
			k := strings.ToLower(r.Hostname) + "\x00" + login
			if seen[k] {
				continue
			}
			seen[k] = true
			out = append(out, EntryHomeChoice{Machine: r.Hostname, Login: login, Online: a == "online" || a == "maintenance"})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Machine != out[j].Machine {
			return out[i].Machine < out[j].Machine
		}
		return out[i].Login < out[j].Login
	})
	return out, nil
}

// entryEnsureHome gives person a first home when they have none: the
// machine `fleet` would enter (homePick) when it is one of their live
// fleets, else the first of those. None live → still none. After this a
// home only moves by hand.
func (s *Server) entryEnsureHome(person string, choices []EntryHomeChoice, now time.Time) (*store.EntryHome, error) {
	if h, ok, err := s.Store.EntryHomeOf(person); err != nil || ok {
		if ok {
			return &h, nil
		}
		return nil, err
	}
	if len(choices) == 0 {
		return nil, nil
	}
	pick := choices[0]
	if hp, err := s.homePick(person, "", now); err == nil && hp.Machine != nil {
		for _, c := range choices {
			if sameMachine(c.Machine, hp.Machine.Hostname) {
				pick = c
				break
			}
		}
	}
	h := store.EntryHome{Person: person, Machine: pick.Machine, Login: pick.Login, SetBy: "auto", SetAt: now.UTC()}
	v, err := s.Store.SetEntryHome(h)
	if err != nil {
		return nil, err
	}
	if v > 0 {
		s.entryAudit(store.EntryAudit{At: now, Kind: "home_set", Person: person, Login: h.Login, Machine: h.Machine, Result: "auto", Actor: "hub"})
		s.broadcastEntry(v, h.Machine)
	}
	return &h, nil
}

func (s *Server) writeEntryView(w http.ResponseWriter, c entryCaller, now time.Time) {
	choices, err := s.entryHomeChoices(c.person, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	home, err := s.entryEnsureHome(c.person, choices, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := EntryView{Person: c.person, Home: home, HomeChoices: choices}
	if out.Keys, err = s.Store.EntryKeys(c.person, c.operator); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, ok, err := s.Store.EntryName(c.person); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if ok {
		out.Name = n.Name
	} else {
		out.SuggestedName = s.entrySuggestedName(c.person)
	}
	out.Version, _ = s.Store.EntryVersion()
	writeJSON(w, http.StatusOK, out)
}

// entrySuggestedName is the name a first visit offers: the GitHub login,
// else the principal's login, made into an address name — "" when neither
// fits or someone else has it.
func (s *Server) entrySuggestedName(person string) string {
	var cands []string
	if gid, ok := githubIDOf(person); ok {
		if u, err := s.Store.HubUserByID(gid); err == nil && u != nil {
			cands = append(cands, u.Login)
		}
	}
	if p, err := s.Store.Principal(person); err == nil {
		cands = append(cands, p.Login)
	}
	names, _ := s.Store.EntryNames(time.Now())
	for _, c := range cands {
		n := entrySuggestName(c)
		if n == "" {
			continue
		}
		free := true
		for _, en := range names {
			if en.Name == n && en.Person != person {
				free = false
			}
		}
		if free {
			return n
		}
	}
	return ""
}

// EntryKeyRequest is POST EntryKeysPath / PATCH …/<id>.
type EntryKeyRequest struct {
	PublicKey string `json:"public_key"`
	Name      string `json:"name"`
}

// handleEntryKeys serves EntryKeysPath and EntryKeysPath+"/<id>".
func (s *Server) handleEntryKeys(w http.ResponseWriter, r *http.Request) {
	c, ok := s.entryCallerOf(w, r)
	if !ok {
		return
	}
	now := time.Now()
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, control.EntryKeysPath), "/")
	switch {
	case id == "" && r.Method == http.MethodGet:
		s.writeEntryView(w, c, now)
	case id == "" && r.Method == http.MethodPost:
		if c.operator {
			httpError(w, http.StatusForbidden, "a key is added by its owner alone")
			return
		}
		s.addEntryKey(w, r, c, now)
	case id != "" && r.Method == http.MethodPatch:
		if c.operator {
			httpError(w, http.StatusForbidden, "a key's name is its owner's")
			return
		}
		var req EntryKeyRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "body must be JSON {name}")
			return
		}
		k, err := s.Store.RenameEntryKey(c.person, id, entryLabel(req.Name))
		if errors.Is(err, store.ErrEntryKeyNotFound) {
			httpError(w, http.StatusNotFound, "no such key")
			return
		} else if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, k)
	case id != "" && r.Method == http.MethodDelete:
		k, v, err := s.Store.RevokeEntryKey(c.person, id, now)
		if errors.Is(err, store.ErrEntryKeyNotFound) {
			httpError(w, http.StatusNotFound, "no such key")
			return
		} else if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if v > 0 {
			s.entryAudit(store.EntryAudit{At: now, Kind: "key_revoke", Person: c.person, FP: k.FP, Result: "ok", Actor: c.actor})
			s.entryPushPerson(c.person, v)
		}
		writeJSON(w, http.StatusOK, k)
	default:
		w.Header().Set("Allow", "GET, POST, PATCH, DELETE")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST "+control.EntryKeysPath+"; PATCH or DELETE "+control.EntryKeysPath+"/<id>")
	}
}

func (s *Server) addEntryKey(w http.ResponseWriter, r *http.Request, c entryCaller, now time.Time) {
	var req EntryKeyRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, entryKeyMax+4096)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "body must be JSON {public_key, name?}")
		return
	}
	typ, b64, fp, comment, err := parseEntryKey(req.PublicKey)
	req.PublicKey = "" // nothing below this line holds what was pasted
	if err != nil {
		result := "refused"
		if errors.Is(err, errEntryPrivate) {
			result = "refused: private key"
		}
		s.entryAudit(store.EntryAudit{At: now, Kind: "key_add", Person: c.person, Result: result, Actor: c.actor})
		httpError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	name := entryLabel(req.Name)
	if name == "" {
		name = entryLabel(comment)
	}
	k, added, v, err := s.Store.AddEntryKey(store.EntryKey{ID: entryID("k_"), Person: c.person, FP: fp, Type: typ, B64: b64, Name: name, Created: now.UTC()})
	if errors.Is(err, store.ErrEntryKeyTaken) {
		s.entryAudit(store.EntryAudit{At: now, Kind: "key_add", Person: c.person, FP: fp, Result: "refused: another person's key", Actor: c.actor})
		httpError(w, http.StatusConflict, "这把钥匙已经登记在别人名下：每个人用自己的钥匙")
		return
	} else if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if added {
		s.entryAudit(store.EntryAudit{At: now, Kind: "key_add", Person: c.person, FP: fp, Result: "ok", Actor: c.actor})
		s.entryPushPerson(c.person, v)
		writeJSON(w, http.StatusCreated, k)
		return
	}
	writeJSON(w, http.StatusOK, k)
}

// EntryNameRequest is PUT EntryNamePath.
type EntryNameRequest struct {
	Name string `json:"name"`
}

// handleEntryName serves EntryNamePath.
func (s *Server) handleEntryName(w http.ResponseWriter, r *http.Request) {
	c, ok := s.entryCallerOf(w, r)
	if !ok {
		return
	}
	if r.Method != http.MethodPut {
		w.Header().Set("Allow", "PUT")
		httpError(w, http.StatusMethodNotAllowed, "PUT {name}")
		return
	}
	if c.operator {
		httpError(w, http.StatusForbidden, "an address name is its owner's to pick")
		return
	}
	var req EntryNameRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "body must be JSON {name}")
		return
	}
	name := strings.ToLower(strings.TrimSpace(req.Name))
	if why := entryNameCheck(name); why != "" {
		httpError(w, http.StatusUnprocessableEntity, why)
		return
	}
	now := time.Now()
	v, err := s.Store.SetEntryName(c.person, name, now)
	if errors.Is(err, store.ErrEntryNameTaken) {
		httpError(w, http.StatusConflict, "「"+name+"」已经有人用了，换一个")
		return
	} else if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if v > 0 {
		s.entryAudit(store.EntryAudit{At: now, Kind: "name_set", Person: c.person, Result: name, Actor: c.actor})
		s.entryPushPerson(c.person, v)
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "version": v})
}

// EntryHomeRequest is PUT EntryHomePath.
type EntryHomeRequest struct {
	Machine string `json:"machine"`
	Login   string `json:"login,omitempty"`
}

// handleEntryHome serves EntryHomePath: GET the home and the choices, PUT
// one of the choices.
func (s *Server) handleEntryHome(w http.ResponseWriter, r *http.Request) {
	c, ok := s.entryCallerOf(w, r)
	if !ok {
		return
	}
	now := time.Now()
	switch r.Method {
	case http.MethodGet:
		s.writeEntryView(w, c, now)
		return
	case http.MethodPut:
	default:
		w.Header().Set("Allow", "GET, PUT")
		httpError(w, http.StatusMethodNotAllowed, "GET or PUT {machine, login?}")
		return
	}
	var req EntryHomeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil || strings.TrimSpace(req.Machine) == "" {
		httpError(w, http.StatusBadRequest, "body must be JSON {machine, login?}")
		return
	}
	choices, err := s.entryHomeChoices(c.person, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	want := strings.TrimSpace(req.Machine)
	aliases := map[string]string{} // hostname → its routes alias
	for _, m := range s.fleetMachines() {
		aliases[strings.ToLower(m.Hostname)] = m.alias()
	}
	var pick *EntryHomeChoice
	for i, ch := range choices {
		named := sameMachine(ch.Machine, want) || (aliases[strings.ToLower(ch.Machine)] != "" && strings.EqualFold(aliases[strings.ToLower(ch.Machine)], want))
		if named && (req.Login == "" || req.Login == ch.Login) {
			if pick != nil && req.Login == "" {
				httpError(w, http.StatusConflict, "you have more than one login there with a live fleet — name the login")
				return
			}
			pick = &choices[i]
		}
	}
	if pick == nil {
		httpError(w, http.StatusUnprocessableEntity, "只能换到你有登录、且上面有在用的 fleet 的机器")
		return
	}
	old, hadOld, err := s.Store.EntryHomeOf(c.person)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h := store.EntryHome{Person: c.person, Machine: pick.Machine, Login: pick.Login, SetBy: c.actor, SetAt: now.UTC()}
	v, err := s.Store.SetEntryHome(h)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if v > 0 {
		s.entryAudit(store.EntryAudit{At: now, Kind: "home_set", Person: c.person, Login: h.Login, Machine: h.Machine, Result: "ok", Actor: c.actor})
		// Both the new home and the one it left hear it.
		hosts := []string{h.Machine}
		if hadOld {
			hosts = append(hosts, old.Machine)
		}
		s.broadcastEntry(v, hosts...)
	} else {
		h = old
	}
	writeJSON(w, http.StatusOK, map[string]any{"home": h, "version": v})
}

// entryPushPerson pushes v to person's home machine — none when they have
// no home yet.
func (s *Server) entryPushPerson(person string, v int) {
	if h, ok, err := s.Store.EntryHomeOf(person); err == nil && ok {
		s.broadcastEntry(v, h.Machine)
	}
}

// nodeHost is the machine a connected endpoint is on.
func (s *Server) nodeHost(endpointID string) string {
	ep, err := s.Store.EndpointByID(endpointID)
	if err != nil || ep == nil {
		return ""
	}
	host, _ := s.peerSelf(ep)
	if host == "" {
		host = s.endpointHost(*ep)
	}
	return host
}

// pushEntry tells one connection the version v (0 = the current one) when it
// has not heard it yet. Off, no capability, or nothing ever changed → no
// message. A failed write is not recorded: the next beat tries again.
func (s *Server) pushEntry(endpointID string, nc *nodeConn, v int) {
	if !nc.canEntryKeys || !s.entryOn() {
		return
	}
	if v <= 0 {
		cur, err := s.Store.EntryVersion()
		if err != nil {
			log.Printf("node %s: read the entry version: %v", endpointID, err)
			return
		}
		v = cur
	}
	if v <= 0 || nc.entrySent.Load() >= int64(v) {
		return
	}
	msg, err := control.New(control.TypeEntryKeys, control.EntryKeys{Version: v})
	if err != nil {
		return
	}
	wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if s.nodes.get(endpointID) != nc {
		return // a newer link took over; it hears the version on its own first beat
	}
	if err := s.SendNodeWrite(wctx, endpointID, msg); err != nil {
		return
	}
	nc.entrySent.Store(int64(v))
}

// broadcastEntry pushes v to every connection with CapEntryKeys on one of
// hosts — and to no other machine.
func (s *Server) broadcastEntry(v int, hosts ...string) {
	if !s.entryOn() || len(hosts) == 0 {
		return
	}
	s.nodes.each(func(id string, c *nodeConn) {
		if !c.canEntryKeys {
			return
		}
		go func() {
			host := s.nodeHost(id)
			if host == "" {
				return
			}
			for _, h := range hosts {
				if h != "" && (sameMachine(host, h) || sameMachine(h, host)) {
					s.pushEntry(id, c, v)
					return
				}
			}
		}()
	})
}

// entryMachineOf authenticates a machine's own door: the bearer must be the
// machine program's token (its link says CapMachine, or the endpoint is
// root's). It returns the machine's name; "" has answered already.
func (s *Server) entryMachineOf(w http.ResponseWriter, r *http.Request) string {
	w.Header().Set("Cache-Control", "no-store")
	tok := bearer(r)
	if tok == "" {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "the machine's node token is required")
		return ""
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil || ep == nil {
		httpError(w, http.StatusUnauthorized, "unrecognised node token")
		return ""
	}
	if !s.entryOn() {
		httpError(w, http.StatusNotFound, "the direct door is off on this hub ("+EntryKey+")")
		return ""
	}
	host, user := s.peerSelf(ep)
	machine := user == "root"
	if c := s.nodes.get(ep.ID); c != nil && c.machineLink {
		machine = true
	}
	if !machine {
		httpError(w, http.StatusForbidden, "only the machine's node program (ccquota agent --machine) reads the door's list")
		return ""
	}
	if host == "" {
		host = s.endpointHost(*ep)
	}
	if host == "" {
		httpError(w, http.StatusConflict, "this machine has not said its name yet — wait for its first heartbeat")
		return ""
	}
	return host
}

// handleNodeEntryKeys serves EntryKeysNodePath.
func (s *Server) handleNodeEntryKeys(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	host := s.entryMachineOf(w, r)
	if host == "" {
		return
	}
	out, err := s.entryNodeList(host)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// entryNodeList is host's list: every login homed on it — never a fleet
// admin's — with its owner's live keys.
func (s *Server) entryNodeList(host string) (control.EntryNodeList, error) {
	out := control.EntryNodeList{Logins: map[string]control.EntryNodeLogin{}}
	// The version first: a change racing this read makes the node pull again.
	v, err := s.Store.EntryVersion()
	if err != nil {
		return out, err
	}
	out.Version = v
	homes, err := s.Store.EntryHomes()
	if err != nil {
		return out, err
	}
	for _, h := range homes {
		if !sameMachine(host, h.Machine) && !sameMachine(h.Machine, host) {
			continue
		}
		if s.isFleetAdmin(h.Login) || !control.ValidExistingLogin(h.Login) {
			continue
		}
		if prev, dup := out.Logins[h.Login]; dup {
			log.Printf("entry: %s on %s is home to %s and %s; keeping %s", h.Login, host, prev.Person, h.Person, prev.Person)
			continue
		}
		keys, err := s.Store.EntryKeys(h.Person, false)
		if err != nil {
			return out, err
		}
		l := control.EntryNodeLogin{Person: h.Person, Keys: []control.EntryNodeKey{}}
		for _, k := range keys {
			l.Keys = append(l.Keys, control.EntryNodeKey{FP: k.FP, Type: k.Type, B64: k.B64, Name: k.Name})
		}
		out.Logins[h.Login] = l
	}
	return out, nil
}

// EntryAuditLine is one line a machine sends: Machine is the hub's to fill.
type EntryAuditLine struct {
	ID       string    `json:"id"`
	At       time.Time `json:"at"`
	Kind     string    `json:"kind,omitempty"`
	Person   string    `json:"person,omitempty"`
	Login    string    `json:"login,omitempty"`
	FP       string    `json:"fp,omitempty"`
	SourceIP string    `json:"source_ip,omitempty"`
	Result   string    `json:"result,omitempty"`
}

// EntryAuditRequest is POST EntryAuditNodePath.
type EntryAuditRequest struct {
	Lines []EntryAuditLine `json:"lines"`
}

var entryAuditIDRE = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,80}$`)

// handleNodeEntryAudit serves EntryAuditNodePath: lines already recorded
// (the same id) are skipped, so a node resends its backlog freely.
func (s *Server) handleNodeEntryAudit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST {lines:[…]}")
		return
	}
	host := s.entryMachineOf(w, r)
	if host == "" {
		return
	}
	var req EntryAuditRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "body must be JSON {lines:[…]}")
		return
	}
	if len(req.Lines) > entryAuditMax {
		httpError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("at most %d lines a request", entryAuditMax))
		return
	}
	now := time.Now()
	lines := make([]store.EntryAudit, 0, len(req.Lines))
	for _, l := range req.Lines {
		if !entryAuditIDRE.MatchString(l.ID) {
			httpError(w, http.StatusBadRequest, "every line needs an id (letters, digits, . _ : -, at most 80)")
			return
		}
		at := l.At
		if at.IsZero() || at.After(now.Add(time.Hour)) {
			at = now
		}
		kind := clip(l.Kind, 40)
		if kind == "" {
			kind = "enter"
		}
		// The machine's own name, never what the line says; the id is the
		// machine's own too, so two machines never collide.
		lines = append(lines, store.EntryAudit{ID: "n:" + clip(strings.ToLower(firstLabel(host)), 60) + ":" + l.ID, At: at,
			Kind: kind, Person: clip(l.Person, 200), Login: clip(l.Login, 64), FP: clip(l.FP, 120),
			Machine: host, SourceIP: clip(l.SourceIP, 64), Result: clip(l.Result, 200), Actor: "node"})
	}
	n, err := s.Store.AddEntryAudit(lines)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, l := range lines {
		if l.Person != "" && l.FP != "" && (l.Result == "ok" || l.Result == "accepted") {
			if err := s.Store.TouchEntryKey(l.Person, l.FP, l.At); err != nil {
				log.Printf("entry audit: last used: %v", err)
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]int{"stored": n, "skipped": len(lines) - n})
}
