package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"html/template"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"rsc.io/qr"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Connection certificates (claude-fleet#1412).
//
// The hub is the fleet's SSH certificate authority. A person who has signed in
// with GitHub gets a 12-hour user certificate for their own key, whose only
// principal is their login (the one C4 opened for them on every machine), and
// every machine trusts the CA (the admin agent installs it, node_sshca.go).
// So nobody's key is copied to any machine, and a certificate that runs out
// is simply refused — scan again to get the next one.
//
// Two ways to get one:
//
//   - `fleet login` (bin/fleet-login.py): the device-code
//     flow. The client generates its key, POSTs the public half to
//     /v1/fleet/login/start, draws the returned QR in the terminal, and polls
//     /v1/fleet/login/poll. Scanning the QR opens /fleet/login on
//     the hub, which signs the person in and asks them to confirm the code
//     their terminal shows; the next poll carries the certificate.
//   - the 连接 page (/connect): paste a public key, download the certificate.
//
// Either way the hub records the issuance (store.fleet_certs) BEFORE it hands
// the certificate out. The CA private key comes from a file
// (CCQUOTA_FLEET_SSH_CA_KEY, a separate k8s Secret) and never touches the
// database. No CA configured: these routes answer 404 and admin nodes are
// sent nothing.

// The fixed client-side contract — C7's `fleet connect` reads the same paths.
const (
	// FleetKeyPath is the person's private key; its .pub is what is signed.
	FleetKeyPath = "~/.ssh/fleet-cert"
	// FleetCertPath is where the certificate goes (OpenSSH's <key>-cert.pub,
	// so `ssh -i ~/.ssh/fleet-cert` finds it without CertificateFile).
	FleetCertPath = "~/.ssh/fleet-cert-cert.pub"
	// FleetSSHConfigPath is the generated ssh_config snippet.
	FleetSSHConfigPath = "~/.ssh/fleet-ssh-config"
	// FleetSSHConfigVersion heads the snippet; bump it when its shape changes.
	FleetSSHConfigVersion = "fleet-ssh-config v1"
)

// FleetMachine is one machine people connect to, and the ways to reach it
// (CCQUOTA_FLEET_ROUTES). Hostname is the roster's name for it — what
// accounts are keyed on; Alias is what people type (`ssh m4`).
type FleetMachine struct {
	Hostname string       `json:"hostname"`
	Alias    string       `json:"alias,omitempty"`
	Routes   []FleetRoute `json:"routes"`
}

// FleetRoute is one way in: LAN, tailnet, public port. The first route is the
// default; `fleet connect` (claude-fleet#1414) measures them all, plus the
// relay, and picks. A node's heartbeat adds its own (fleet_routes.go).
type FleetRoute struct {
	Name string `json:"name"`
	Host string `json:"host"`
	Port int    `json:"port,omitempty"`
}

func (m FleetMachine) alias() string {
	if m.Alias != "" {
		return m.Alias
	}
	return m.Hostname
}

// ParseFleetRoutes reads CCQUOTA_FLEET_ROUTES: a JSON array of FleetMachine.
// Every name that ends up in the generated ssh config is checked to be a
// plain token — it is a config file other programs parse.
func ParseFleetRoutes(s string) ([]FleetMachine, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	var ms []FleetMachine
	if err := json.Unmarshal([]byte(s), &ms); err != nil {
		return nil, fmt.Errorf("CCQUOTA_FLEET_ROUTES: %w", err)
	}
	for _, m := range ms {
		if !sshToken(m.Hostname) || (m.Alias != "" && !sshToken(m.Alias)) {
			return nil, fmt.Errorf("CCQUOTA_FLEET_ROUTES: bad machine name %q/%q", m.Hostname, m.Alias)
		}
		for _, r := range m.Routes {
			if !sshToken(r.Name) || !sshToken(r.Host) || r.Port < 0 || r.Port > 65535 {
				return nil, fmt.Errorf("CCQUOTA_FLEET_ROUTES: bad route %+v on %s", r, m.Hostname)
			}
		}
	}
	return ms, nil
}

// sshToken: letters, digits and . - _ : only — safe as an ssh_config word.
func sshToken(s string) bool {
	if s == "" || len(s) > 253 {
		return false
	}
	for _, c := range s {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '.' || c == '-' || c == '_' || c == ':':
		default:
			return false
		}
	}
	return s[0] != '-'
}

// errNoAccount: the person has no active login anywhere yet, so a
// certificate would admit them nowhere.
var errNoAccount = errors.New("no active login on any machine yet — ask the operator to open one")

// noAccountErr is errNoAccount with the reason the person can act on
// (claude-fleet#2094): mapped to a login the hub holds under someone else, or
// one no machine has reported yet. errors.Is(err, errNoAccount) still holds.
type noAccountErr struct{ why string }

func (e *noAccountErr) Error() string        { return e.why }
func (e *noAccountErr) Is(target error) bool { return target == errNoAccount }

// noAccountReason is why pid has no active login, as precisely as the hub
// knows: errNoAccount itself when nobody mapped them.
func (s *Server) noAccountReason(pid string) error {
	login, ok := s.mappedLoginFor(pid)
	if !ok || login == noneValue {
		return errNoAccount
	}
	if owner, err := s.Store.PrincipalByLogin(login); err == nil && !strings.EqualFold(owner.ID, pid) {
		if _, gh := githubIDOf(owner.ID); gh {
			return &noAccountErr{fmt.Sprintf("you are mapped to machine login %s, but the hub has it as another GitHub person's, %s — ask the operator to fix the mapping",
				login, s.personName(owner.ID))}
		}
		return &noAccountErr{fmt.Sprintf("you are mapped to machine login %s, but the hub still has it under the old identity %s and could not move it to you — ask the operator to run: fleet hub accounts rekey %s %s",
			login, s.personName(owner.ID), owner.ID, pid)}
	}
	if p, err := s.Store.Principal(pid); err == nil && p.Login != login {
		return &noAccountErr{fmt.Sprintf("you are mapped to machine login %s, but the hub recorded you as %s before the mapping — ask the operator to forget that record (fleet hub accounts forget %s)",
			login, p.Login, p.ID)}
	}
	return &noAccountErr{fmt.Sprintf("you are mapped to machine login %s, but no machine has reported it active yet — it becomes yours once a fleet agent runs as %s on a machine",
		login, login)}
}

// CertResponse is a signed certificate and everything the client writes.
type CertResponse struct {
	Certificate string    `json:"certificate"` // the content of FleetCertPath
	Serial      string    `json:"serial"`
	KeyID       string    `json:"key_id"`
	Principals  []string  `json:"principals"`
	ValidAfter  time.Time `json:"valid_after"`
	ValidBefore time.Time `json:"valid_before"`
	// SSHConfig is the snippet for FleetSSHConfigPath.
	SSHConfig string `json:"ssh_config"`
	Hub       string `json:"hub"`
	// Machines names every machine the snippet covers, the hub's hostname
	// beside the alias people type (claude-fleet#1719): a node's `fleet login`
	// writes a peer-certificate Match per machine from it, and
	// fleet-peer-cert.sh turns any of the names back into the hostname.
	Machines []CertMachine `json:"machines,omitempty"`
	// Node is the machine's node pass (claude-fleet#1627): present only when
	// the scan was `fleet node join` (purpose=node), never on a plain login.
	Node *NodeJoinResponse `json:"node,omitempty"`
}

// fleetLoginsOf is the principals a certificate for pid may carry: the
// distinct logins of their ACTIVE accounts, and the machines they are on.
func (s *Server) fleetLoginsOf(pid string) (*store.Principal, []string, map[string]bool, error) {
	p, err := s.Store.Principal(pid)
	if errors.Is(err, store.ErrNoPrincipal) {
		return nil, nil, nil, s.noAccountReason(pid)
	}
	if err != nil {
		return nil, nil, nil, err
	}
	accts, err := s.Store.FleetAccounts(pid)
	if err != nil {
		return nil, nil, nil, err
	}
	seen, hosts := map[string]bool{}, map[string]bool{}
	var logins []string
	for _, a := range accts {
		if a.State != store.AccountActive || !a.Managed() || !control.ValidExistingLogin(a.Login) {
			continue
		}
		hosts[a.Hostname] = true
		if !seen[a.Login] {
			seen[a.Login] = true
			logins = append(logins, a.Login)
		}
	}
	if len(logins) == 0 {
		return p, nil, hosts, s.noAccountReason(pid)
	}
	sort.Strings(logins)
	return p, logins, hosts, nil
}

// issueCert signs key for pid, records it, and builds the response.
func (s *Server) issueCert(r *http.Request, pid, keyLine, via string) (*CertResponse, error) {
	key, err := sshca.ParseUserKey(keyLine)
	if err != nil {
		return nil, err
	}
	p, logins, hosts, err := s.fleetLoginsOf(pid)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	iss, err := s.SSHCA.Sign(sshca.Request{Key: key, PrincipalID: pid, Logins: logins}, now)
	if err != nil {
		return nil, err
	}
	serial := strconv.FormatUint(iss.Serial, 10)
	if err := s.Store.RecordCert(store.FleetCert{
		Serial: serial, PrincipalID: pid, KeyID: iss.KeyID, Principals: iss.Principals,
		KeyFingerprint: iss.KeyFingerprint, Via: via, IssuedAt: now,
		ValidAfter: iss.ValidAfter, ValidBefore: iss.ValidBefore,
	}); err != nil {
		return nil, fmt.Errorf("record certificate: %w", err)
	}
	log.Printf("fleet: issued ssh certificate %s to %s (%s) via %s, key %s, until %s",
		serial, pid, strings.Join(iss.Principals, ","), via, iss.KeyFingerprint, iss.ValidBefore.UTC().Format(time.RFC3339))
	return &CertResponse{
		Certificate: iss.Line + "\n",
		Serial:      serial,
		KeyID:       iss.KeyID,
		Principals:  iss.Principals,
		ValidAfter:  iss.ValidAfter,
		ValidBefore: iss.ValidBefore,
		SSHConfig:   s.sshConfigFor(p.Login, hosts),
		Machines:    s.certMachines(hosts),
		Hub:         s.hubURL(r),
	}, nil
}

// CertMachine is one machine of CertResponse.Machines.
type CertMachine struct {
	Hostname string `json:"hostname"`
	Alias    string `json:"alias"`
}

// certMachines is the machines the snippet is for (every one when hosts is
// nil), each name held to sshToken — it goes into an ssh config.
func (s *Server) certMachines(hosts map[string]bool) []CertMachine {
	var out []CertMachine
	for _, m := range s.fleetMachines() {
		if (hosts != nil && !hosts[m.Hostname]) || !sshToken(m.Hostname) || !sshToken(m.alias()) {
			continue
		}
		out = append(out, CertMachine{Hostname: m.Hostname, Alias: m.alias()})
	}
	return out
}

// hubURL is the address people know the hub by.
func (s *Server) hubURL(r *http.Request) string {
	if s.FleetPublicURL != "" {
		return strings.TrimRight(s.FleetPublicURL, "/")
	}
	scheme := "http"
	if isHTTPS(r) {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

// sshConfigFor renders the snippet: one Host block per machine where login is
// active (every machine when hosts is nil — the operator's view), the first
// route as the plain alias and every route as <alias>-<route>. The format is
// a contract (FleetSSHConfigVersion): C7's `fleet connect` reads it.
func (s *Server) sshConfigFor(login string, hosts map[string]bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s — generated by the fleet hub; `fleet login` rewrites this file.\n", FleetSSHConfigVersion)
	b.WriteString("# Your own entries in ~/.ssh/config come first and win.\n")
	for _, m := range s.fleetMachines() {
		if hosts != nil && !hosts[m.Hostname] {
			continue
		}
		if len(m.Routes) == 0 {
			continue
		}
		a := m.alias()
		for i, rt := range m.Routes {
			names := "fleet-" + a + "-" + rt.Name
			if i == 0 {
				names = a + " fleet-" + a + " " + names
			}
			fmt.Fprintf(&b, "\nHost %s\n  HostName %s\n", names, rt.Host)
			if rt.Port > 0 {
				fmt.Fprintf(&b, "  Port %d\n", rt.Port)
			}
			if login != "" {
				fmt.Fprintf(&b, "  User %s\n", login)
			}
			fmt.Fprintf(&b, "  IdentityFile %s\n  CertificateFile %s\n", FleetKeyPath, FleetCertPath)
		}
	}
	return b.String()
}

// ── the 连接 page's API ──────────────────────────────────────────────────

// ConnectInfo is the body of GET /v1/fleet/connect.
type ConnectInfo struct {
	Hub           string         `json:"hub"`
	CAEnabled     bool           `json:"ca_enabled"`
	CAFingerprint string         `json:"ca_fingerprint,omitempty"`
	CertTTLSec    int            `json:"cert_ttl_sec"`
	Login         string         `json:"login,omitempty"`
	Signed        bool           `json:"signed_in"` // a signed-in person, not an operator door
	Machines      []FleetMachine `json:"machines"`
	SSHConfig     string         `json:"ssh_config"`
	KeyPath       string         `json:"key_path"`
	CertPath      string         `json:"cert_path"`
	ConfigPath    string         `json:"config_path"`
	// Problem says why a signed-in person cannot get a certificate yet.
	Problem string            `json:"problem,omitempty"`
	Recent  []store.FleetCert `json:"recent_certs"`
	// InstallCommand is the one line a colleague runs (claude-fleet#1470);
	// InstallReady says whether this hub serves it (a CA and GitHub sign-in).
	InstallCommand string `json:"install_command"`
	InstallReady   bool   `json:"install_ready"`
}

func (s *Server) handleFleetConnect(w http.ResponseWriter, r *http.Request) {
	out := ConnectInfo{
		Hub: s.hubURL(r), CAEnabled: s.SSHCA != nil, CertTTLSec: int(sshca.TTL.Seconds()),
		KeyPath: FleetKeyPath, CertPath: FleetCertPath, ConfigPath: FleetSSHConfigPath,
		Machines: []FleetMachine{}, Recent: []store.FleetCert{},
		InstallCommand: s.InstallCommand(r), InstallReady: s.installReady(),
	}
	if s.SSHCA != nil {
		out.CAFingerprint = s.SSHCA.Fingerprint()
	}
	var hosts map[string]bool
	if pid := s.ensurePerson(r); pid != "" {
		out.Signed = true
		p, _, h, err := s.fleetLoginsOf(pid)
		switch {
		case errors.Is(err, errNoAccount):
			out.Problem = err.Error()
		case err != nil:
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if p != nil {
			out.Login = p.Login
		}
		hosts = h
		if hosts == nil {
			hosts = map[string]bool{}
		}
		if out.Recent, err = s.Store.FleetCerts(pid, 5); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	for _, m := range s.fleetMachines() {
		if hosts == nil || hosts[m.Hostname] {
			out.Machines = append(out.Machines, m)
		}
	}
	out.SSHConfig = s.sshConfigFor(out.Login, hosts)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// handleFleetCert signs a pasted public key for the signed-in person.
func (s *Server) handleFleetCert(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if s.SSHCA == nil {
		http.NotFound(w, r)
		return
	}
	pid := s.ensurePerson(r)
	if pid == "" {
		httpError(w, http.StatusForbidden, "a certificate is issued to a person: sign in with GitHub")
		return
	}
	var req struct {
		PublicKey string `json:"public_key"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request")
		return
	}
	resp, err := s.issueCert(r, pid, req.PublicKey, "web")
	if err != nil {
		httpError(w, certErrStatus(err), err.Error())
		return
	}
	s.registerDevice(pid, req.PublicKey, "", "web", time.Now())
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

func certErrStatus(err error) int {
	if errors.Is(err, errNoAccount) {
		return http.StatusConflict
	}
	if strings.HasPrefix(err.Error(), "record certificate") {
		return http.StatusInternalServerError
	}
	return http.StatusBadRequest
}

// handleSSHCAPub serves the CA public key: public material, no credential.
func (s *Server) handleSSHCAPub(w http.ResponseWriter, r *http.Request) {
	if s.SSHCA == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(s.SSHCA.PublicKey() + "\n"))
}

// ── the device-code flow (`fleet login`) ─────────────────────────────────

const (
	deviceTTL      = 10 * time.Minute
	devicePoll     = 3 * time.Second
	deviceMax      = 256                    // pending logins held at once; start refuses past it
	userCodeAlpha  = "BCDFGHJKLMNPQRSTVWXZ" // no vowels: no words, no 0/O 1/I
	loginCookie    = "ccquota_fleet_login"
	loginCookieTTL = 10 * time.Minute
)

type deviceState int

const (
	devicePending deviceState = iota
	deviceApproved
	deviceDenied
)

type deviceLogin struct {
	deviceCode string
	userCode   string
	keyLine    string
	keyFP      string
	name       string // the client's own hostname, for the device record (#1470)
	purpose    string // "" fleet login · "node" fleet node join: the scan also adds a node (#1627)
	osUser     string // the login the node's agent runs as (purpose=node)
	expires    time.Time
	state      deviceState
	issued     *CertResponse
	err        string
	code       string // why it was denied, for the poll (no_machine_login, claude-fleet#2090)
}

// deviceLogins is in memory on purpose: a pending login lives ten minutes,
// and a restart costs the person one more scan. With two hub replicas only
// the state holder keeps them — the other proxies start, poll and the
// confirmation to it (replica_state.go, claude-fleet#2190) — so a certificate
// and a node pass never enter the database.
type deviceLogins struct {
	mu     sync.Mutex
	byCode map[string]*deviceLogin // device code → login
	byUser map[string]*deviceLogin // user code → login
}

func (d *deviceLogins) gc(now time.Time) {
	for k, l := range d.byCode {
		if now.After(l.expires) {
			delete(d.byCode, k)
			delete(d.byUser, l.userCode)
		}
	}
}

func (d *deviceLogins) add(l *deviceLogin, now time.Time) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.byCode == nil {
		d.byCode, d.byUser = map[string]*deviceLogin{}, map[string]*deviceLogin{}
	}
	d.gc(now)
	if len(d.byCode) >= deviceMax {
		return errors.New("too many logins in progress; try again in a few minutes")
	}
	if _, dup := d.byUser[l.userCode]; dup {
		return errors.New("code collision; try again")
	}
	d.byCode[l.deviceCode] = l
	d.byUser[l.userCode] = l
	return nil
}

// withUser runs f on the pending login for userCode, under the lock.
func (d *deviceLogins) withUser(userCode string, now time.Time, f func(*deviceLogin)) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.gc(now)
	l, ok := d.byUser[userCode]
	if !ok {
		return false
	}
	f(l)
	return true
}

// take returns the login for deviceCode; a finished one is removed, so a
// certificate is handed out exactly once.
func (d *deviceLogins) take(deviceCode string, now time.Time) (deviceLogin, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.gc(now)
	l, ok := d.byCode[deviceCode]
	if !ok {
		return deviceLogin{}, false
	}
	if l.state != devicePending {
		delete(d.byCode, deviceCode)
		delete(d.byUser, l.userCode)
	}
	return *l, true
}

func randomUserCode() (string, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	out := make([]byte, 0, 9)
	for i, c := range b {
		if i == 4 {
			out = append(out, '-')
		}
		out = append(out, userCodeAlpha[int(c)%len(userCodeAlpha)])
	}
	return string(out), nil
}

// validUserCode: XXXX-XXXX from the alphabet — the only shape that ever
// reaches a lookup, a cookie or a redirect.
func validUserCode(s string) bool {
	if len(s) != 9 || s[4] != '-' {
		return false
	}
	for i, c := range s {
		if i != 4 && !strings.ContainsRune(userCodeAlpha, c) {
			return false
		}
	}
	return true
}

// DeviceStart is the body of POST /v1/fleet/login/start.
type DeviceStart struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURI string `json:"verification_uri"`
	ExpiresIn       int    `json:"expires_in"`
	Interval        int    `json:"interval"`
	KeyFingerprint  string `json:"key_fingerprint"`
	// QR is the verification URI as a QR matrix, one string per row, '#' a
	// dark module — no quiet zone. The client draws it; no QR library there.
	QR []string `json:"qr"`
}

// handleDeviceStart opens a pending login for a public key. No credential:
// this is what a person runs BEFORE they have one. It grants nothing — the
// certificate is signed only when a signed-in person confirms the code.
func (s *Server) handleDeviceStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if s.SSHCA == nil || !s.GitHub.ready() {
		http.NotFound(w, r)
		return
	}
	var req struct {
		PublicKey string `json:"public_key"`
		// DeviceName is the client's own hostname — display only (#1470).
		DeviceName string `json:"device_name"`
		// Purpose "node" makes the confirmation add this machine as a node
		// and the poll carry its node pass (claude-fleet#1627).
		Purpose string `json:"purpose"`
		// OSUser is the login the node's agent will run as (purpose=node).
		OSUser string `json:"os_user"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request")
		return
	}
	if req.Purpose != "" && req.Purpose != purposeNode {
		httpError(w, http.StatusBadRequest, "purpose: empty or node")
		return
	}
	key, err := sshca.ParseUserKey(req.PublicKey)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	var dc [32]byte
	if _, err := rand.Read(dc[:]); err != nil {
		httpError(w, http.StatusInternalServerError, "no randomness")
		return
	}
	uc, err := randomUserCode()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "no randomness")
		return
	}
	now := time.Now()
	l := &deviceLogin{
		deviceCode: hex.EncodeToString(dc[:]), userCode: uc,
		keyLine: strings.TrimSpace(req.PublicKey), keyFP: ssh.FingerprintSHA256(key),
		name:    cleanDeviceName(req.DeviceName),
		purpose: req.Purpose,
		osUser:  sanitizeJoinField(req.OSUser),
		expires: now.Add(deviceTTL),
	}
	if err := s.devices.add(l, now); err != nil {
		httpError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	uri := s.hubURL(r) + "/fleet/login?code=" + url.QueryEscape(uc)
	writeJSON(w, http.StatusOK, DeviceStart{
		DeviceCode: l.deviceCode, UserCode: uc, VerificationURI: uri,
		ExpiresIn: int(deviceTTL.Seconds()), Interval: int(devicePoll.Seconds()),
		KeyFingerprint: l.keyFP, QR: qrMatrix(uri),
	})
}

// handleDevicePoll answers the client's wait: 202 pending, 200 with the
// certificate (exactly once), 403 denied, 410 expired or unknown.
func (s *Server) handleDevicePoll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	var req struct {
		DeviceCode string `json:"device_code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request")
		return
	}
	l, ok := s.devices.take(req.DeviceCode, time.Now())
	w.Header().Set("Cache-Control", "no-store")
	switch {
	case !ok:
		httpError(w, http.StatusGone, "expired_token")
	case l.state == devicePending:
		writeJSON(w, http.StatusAccepted, map[string]string{"status": "authorization_pending"})
	case l.state == deviceDenied:
		msg := "access_denied"
		if l.err != "" {
			msg += ": " + l.err
		}
		if l.code != "" {
			// A login the hub could not issue at all (claude-fleet#2090):
			// the terminal prints the reason and stops, not waits ten minutes.
			writeJSON(w, http.StatusForbidden, map[string]string{"error": msg, "code": l.code, "reason": l.err})
			return
		}
		httpError(w, http.StatusForbidden, msg)
	default:
		writeJSON(w, http.StatusOK, l.issued)
	}
}

// handleFleetLoginPage is what the QR opens. It sits behind viewerOnly; a
// browser that is not signed in yet is sent to /signin by viewerOnly, and the
// code rides a short cookie so the GitHub callback can bring it back here. A
// browser that IS signed in never passes the callback again, so the person is placed here too
// (ensurePerson, claude-fleet#1472) — before the page reads their logins.
func (s *Server) handleFleetLoginPage(w http.ResponseWriter, r *http.Request) {
	if s.SSHCA == nil {
		http.NotFound(w, r)
		return
	}
	code := strings.ToUpper(strings.TrimSpace(r.FormValue("code")))
	pid := s.ensurePerson(r)
	loc := s.pageLocale(w, r)
	page := loginPage{pageView: newPageView(r, loc), Code: code}
	now := time.Now()

	if r.Method == http.MethodPost {
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-origin form")
			return
		}
		if (pid == "" && r.FormValue("approve_code") == "") || !validUserCode(code) {
			httpError(w, http.StatusBadRequest, "nothing to confirm")
			return
		}
		approve := r.FormValue("action") == "approve"
		var devName, purpose string
		s.devices.withUser(code, now, func(l *deviceLogin) {
			if l.state == devicePending {
				devName, purpose = l.name, l.purpose
			}
		})
		page.setPurpose(purpose, devName)
		var resp *CertResponse
		var err error
		switch {
		case approve && r.FormValue("approve_code") != "":
			// A drill's code (claude-fleet#2010): the login is the drill
			// person's, whoever is signed in on this browser.
			_, resp, _, err = s.approveWithCode(r, code, strings.TrimSpace(r.FormValue("approve_code")), now)
		case approve:
			resp, _, err = s.approveDeviceLogin(r, pid, code, now)
		default:
			if !s.devices.withUser(code, now, func(l *deviceLogin) {
				if l.state == devicePending {
					l.state = deviceDenied
				} else {
					err = errLoginGone
				}
			}) {
				err = errLoginGone
			}
		}
		switch {
		case errors.Is(err, errLoginGone):
			page.Error = pageT(loc, "login.err.gone")
		case errors.Is(err, store.ErrDrillCode):
			page.Error = pageT(loc, "login.err.drill")
		case err != nil:
			page.Error = i18n.Interpolate(pageT(loc, "login.err.issue"), map[string]string{"err": err.Error()})
		case !approve:
			page.Done, page.Denied = true, true
		default:
			page.Done, page.Login, page.Until = true, strings.Join(resp.Principals, ","), resp.ValidBefore.Local().Format("01-02 15:04")
		}
		renderLoginPage(w, page)
		return
	}

	// GET: show what is being confirmed.
	if pid == "" {
		page.Error = pageT(loc, "login.err.noperson")
		renderLoginPage(w, page)
		return
	}
	if !validUserCode(code) || !s.devices.withUser(code, now, func(l *deviceLogin) {
		if l.state == devicePending {
			page.KeyFP = l.keyFP
			page.setPurpose(l.purpose, l.name)
		}
	}) || page.KeyFP == "" {
		page.Error = pageT(loc, "login.err.gone")
		renderLoginPage(w, page)
		return
	}
	p, logins, _, err := s.fleetLoginsOf(pid)
	if p != nil {
		page.Who = p.DisplayName
		if page.Who == "" {
			page.Who = p.ID
		}
	}
	if errors.Is(err, errNoAccount) {
		// Nothing the person can do here will issue it (claude-fleet#2090):
		// deny the pending login with the reason, so the terminal's next
		// poll prints it and stops instead of waiting out the ten minutes.
		why := s.noMachineLoginReason(r, pid, p, loc)
		s.devices.withUser(code, now, func(l *deviceLogin) {
			if l.state == devicePending {
				l.state, l.err, l.code = deviceDenied, why, codeNoMachineLogin
			}
		})
		page.Error = i18n.Interpolate(pageT(loc, "login.err.nomachine"), map[string]string{"why": why})
		renderLoginPage(w, page)
		return
	}
	if err != nil {
		page.Error = i18n.Interpolate(pageT(loc, "login.err.notyet"), map[string]string{"err": err.Error()})
		renderLoginPage(w, page)
		return
	}
	page.Login = strings.Join(logins, ",")
	page.Confirm = true
	renderLoginPage(w, page)
}

// codeNoMachineLogin is the poll's code for a login denied because the
// person has no machine login to sign for (claude-fleet#2090).
const codeNoMachineLogin = "no_machine_login"

// noMachineLoginReason says who must do what when pid has no active login:
// no machine login on record → an admin sets one on the 使用者 page; a login
// on record but open on no machine yet → it is still being opened.
func (s *Server) noMachineLoginReason(r *http.Request, pid string, p *store.Principal, loc string) string {
	who := ""
	if sess := sessionOf(r.Context()); sess != nil {
		who = sess.Name
	}
	if who == "" && p != nil {
		who = p.DisplayName
	}
	if who == "" {
		who = pid
	}
	if login, ok := s.mappedLoginFor(pid); ok {
		return i18n.Interpolate(pageT(loc, "login.why.notopen"), map[string]string{"who": who, "login": login})
	}
	return i18n.Interpolate(pageT(loc, "login.why.nologin"), map[string]string{"who": who})
}

// approveDeviceLogin confirms the pending login under code as pid: the
// certificate, the node pass for a `fleet node join` scan, and the device
// record (#1470). errLoginGone when nothing is pending under code; on an
// issuance error the login is denied with it and resp is nil.
func (s *Server) approveDeviceLogin(r *http.Request, pid, code string, now time.Time) (*CertResponse, string, error) {
	var keyLine, devName, purpose, osUser string
	s.devices.withUser(code, now, func(l *deviceLogin) {
		if l.state == devicePending {
			keyLine, devName, purpose, osUser = l.keyLine, l.name, l.purpose, l.osUser
		}
	})
	if keyLine == "" {
		return nil, purpose, errLoginGone
	}
	resp, err := s.issueCert(r, pid, keyLine, "device")
	if err == nil && purpose == purposeNode {
		// Same eligibility as the certificate (an active login), then
		// the node pass the old join code used to buy (#1627).
		var node *NodeJoinResponse
		fp := ""
		if k, kerr := sshca.ParseUserKey(keyLine); kerr == nil {
			fp = ssh.FingerprintSHA256(k)
		}
		if node, err = s.enrollDeviceNode(r, fp, devName, osUser); err == nil {
			resp.Node = node
			// 登录即认人 (claude-fleet#2212): the scanned computer's login is theirs
			s.recordLoginAccount(pid, fp, node, osUser, now)
			log.Printf("fleet: %s added node %s (%s) by scan", pid, node.Label, node.EndpointID)
		}
	}
	s.devices.withUser(code, now, func(l *deviceLogin) {
		if l.state != devicePending {
			return
		}
		if err != nil {
			l.state, l.err = deviceDenied, err.Error()
			return
		}
		l.state, l.issued = deviceApproved, resp
	})
	if err != nil {
		return nil, purpose, err
	}
	// The scan is the proof: this computer is now a registered
	// device that renews without one (#1470).
	s.registerDevice(pid, keyLine, devName, "device", now)
	return resp, purpose, nil
}

// rememberLoginCode is mounted in front of viewerOnly on /fleet/login: a
// signed-out browser is about to be sent to /signin and loses the query string
// on the way back, so the code waits in a short host-only cookie.
func (s *Server) rememberLoginCode(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if code := strings.ToUpper(r.URL.Query().Get("code")); validUserCode(code) {
			http.SetCookie(w, &http.Cookie{
				Name: loginCookie, Value: code, Path: "/",
				HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
				MaxAge: int(loginCookieTTL.Seconds()),
			})
		}
		next.ServeHTTP(w, r)
	})
}

// loginReturn is where the GitHub callback sends the browser after sign-in: back to the
// confirmation page when a fleet login is waiting, else "/". Only a fixed
// path and a validated code — not a redirect target anyone can choose.
func loginReturn(w http.ResponseWriter, r *http.Request) string {
	c, err := r.Cookie(loginCookie)
	if err != nil {
		return "/"
	}
	http.SetCookie(w, &http.Cookie{Name: loginCookie, Value: "", Path: "/", MaxAge: -1})
	code := strings.ToUpper(c.Value)
	if !validUserCode(code) {
		return "/"
	}
	return "/fleet/login?code=" + code
}

// sameOrigin: a form POST must come from this host. SameSite=Lax already keeps
// the session cookie off a cross-site POST; this is the second lock.
func sameOrigin(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" || o == "null" {
		ref := r.Header.Get("Referer")
		if ref == "" {
			return true // a non-browser client; the session cookie still has to be there
		}
		o = ref
	}
	u, err := url.Parse(o)
	return err == nil && strings.EqualFold(u.Host, r.Host)
}

type loginPage struct {
	pageView
	Title   string // 领取连接证书, or 把 <机器名> 加为节点 (#1627)
	Node    string // the machine being added, purpose=node only
	Code    string
	KeyFP   string
	Who     string
	Login   string
	Until   string
	Error   string
	Confirm bool
	Done    bool
	Denied  bool
}

var loginTmpl = template.Must(template.New("login").Funcs(pageFuncs(i18n.EN)).Parse(`<!doctype html>
<html lang="{{.Lang}}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{.Title}}</title>
<style>
:root{--bg:#fff;--fg:#1f2328;--mut:#59636e;--card:#f6f8fa;--line:#d1d9e0;--ok:#1a7f37;--bad:#cf222e;--btn:#1f6feb;--ink:var(--fg);--ink-2:var(--mut)}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mut:#9198a1;--card:#151b23;--line:#3d444d;--ok:#3fb950;--bad:#f85149;--btn:#388bfd}}
body{background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px}
:lang(zh) body{font-family:-apple-system,"PingFang SC","Hiragino Sans GB","Noto Sans SC","Microsoft YaHei",system-ui,sans-serif;line-height:1.75}
main{max-width:460px;margin:0 auto}
.top{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin:0 0 16px}
h1{font-size:20px;margin:0;line-height:1.3}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin:12px 0;overflow-wrap:anywhere}
.code{font:600 28px/1.2 ui-monospace,Menlo,monospace;letter-spacing:2px}
.mut{color:var(--mut);font-size:14px}
code{font-family:ui-monospace,Menlo,monospace;font-size:13px;word-break:break-all}
.row{display:flex;gap:12px;margin-top:16px}
button{flex:1;font-size:16px;padding:12px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}
button.go{background:var(--btn);border-color:var(--btn);color:#fff}
.ok{color:var(--ok)}.bad{color:var(--bad)}
` + langSwitchCSS + `</style></head><body><main>
<div class="top"><h1>{{.Title}}</h1>` + langSwitch + `</div>
{{if .Error}}<div class="card bad">{{.Error}}</div>
{{else if .Done}}{{if .Denied}}<div class="card">{{t "login.denied"}}</div>
{{else}}<div class="card ok">{{.DoneHTML}}</div>{{end}}
{{else if .Confirm}}
<p>{{t "login.confirm.lead"}}</p>
<div class="card"><div class="mut">{{t "login.code"}}</div><div class="code">{{.Code}}</div></div>
<div class="card"><div class="mut">{{t "login.for"}}</div><div>{{.Who}} · {{t "login.account"}} <b>{{.Login}}</b></div>
<div class="mut" style="margin-top:8px">{{t "login.keyfp"}}</div><code>{{.KeyFP}}</code>
<div class="mut" style="margin-top:8px">{{t "login.validity"}}</div>
{{if .Node}}<div class="mut" style="margin-top:8px">{{.NodeNoteHTML}}</div>{{end}}</div>
<form method="post" action="/fleet/login"><input type="hidden" name="code" value="{{.Code}}">
<div class="row"><button name="action" value="deny">{{t "login.btn.deny"}}</button><button class="go" name="action" value="approve">{{t "login.btn.approve"}}</button></div></form>
{{end}}
</main></body></html>`))

// purposeNode is the device-flow purpose of `fleet node join` (#1627).
const purposeNode = "node"

// setPurpose titles the page for what the scan does: the only difference
// between the login page and the add-a-node page (#1627).
func (p *loginPage) setPurpose(purpose, machine string) {
	if purpose != purposeNode {
		return
	}
	if machine == "" {
		machine = pageT(p.Lang, "login.this.machine")
	}
	p.Node = machine
	p.Title = i18n.Interpolate(pageT(p.Lang, "login.title.node"), map[string]string{"machine": machine})
}

// DoneHTML is the confirmation's closing sentence, its values bolded and
// escaped.
func (p loginPage) DoneHTML() template.HTML {
	key := "login.done"
	if p.Node != "" {
		key = "login.done.node"
	}
	return boldIn(p.Lang, key, map[string]string{"node": p.Node, "login": p.Login, "until": p.Until}, "until")
}

// NodeNoteHTML says what confirming a node scan does, the machine bolded.
func (p loginPage) NodeNoteHTML() template.HTML {
	return boldIn(p.Lang, "login.node.note", map[string]string{"node": p.Node})
}

// boldIn fills key's placeholders with escaped values, bolding each one
// except those named in plain.
func boldIn(loc, key string, vars map[string]string, plain ...string) template.HTML {
	out := make(map[string]string, len(vars))
	for k, v := range vars {
		out[k] = "<b>" + html.EscapeString(v) + "</b>"
	}
	for _, k := range plain {
		out[k] = html.EscapeString(vars[k])
	}
	return template.HTML(i18n.Interpolate(html.EscapeString(pageT(loc, key)), out))
}

func renderLoginPage(w http.ResponseWriter, p loginPage) {
	if p.Lang == "" {
		p.pageView = newPageView(nil, i18n.EN)
	}
	if p.Title == "" {
		p.Title = pageT(p.Lang, "login.title")
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Language", p.Lang)
	if c, err := loginTmpl.Clone(); err == nil {
		_ = c.Funcs(pageFuncs(p.Lang)).Execute(w, p)
	}
}

// qrMatrix encodes s as rows of '#' (dark) and '.' (light).
func qrMatrix(s string) []string {
	c, err := qr.Encode(s, qr.M)
	if err != nil {
		return nil
	}
	rows := make([]string, c.Size)
	for y := 0; y < c.Size; y++ {
		var b strings.Builder
		for x := 0; x < c.Size; x++ {
			if c.Black(x, y) {
				b.WriteByte('#')
			} else {
				b.WriteByte('.')
			}
		}
		rows[y] = b.String()
	}
	return rows
}

// ── the admin node's half: send the CA ──────────────────────────────────

// sendSSHCA tells an admin node to trust the CA. Idempotent on the node, so it
// goes out on every admin connect; the answer lands in sshCAStatus.
func (s *Server) sendSSHCA(epID string) {
	if s.SSHCA == nil {
		return
	}
	msg, err := control.New(control.TypeSSHCA, control.SSHCA{PublicKey: s.SSHCA.PublicKey()})
	if err != nil {
		return
	}
	s.setSSHCAStatus(epID, "sent")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.SendNodeWrite(ctx, epID, msg); err != nil {
		s.setSSHCAStatus(epID, "not sent: "+err.Error())
	}
}

func (s *Server) setSSHCAStatus(epID, st string) {
	s.sshCAMu.Lock()
	defer s.sshCAMu.Unlock()
	if s.sshCAStatus == nil {
		s.sshCAStatus = map[string]string{}
	}
	s.sshCAStatus[epID] = st
}

func (s *Server) sshCAStatusOf(epID string) string {
	s.sshCAMu.Lock()
	defer s.sshCAMu.Unlock()
	return s.sshCAStatus[epID]
}

// applySSHCAResult records an admin node's answer.
func (s *Server) applySSHCAResult(epID string, nc *nodeConn, m control.Message) {
	if !nc.admin {
		return
	}
	var res control.SSHCAResult
	if err := json.Unmarshal(m.Payload, &res); err != nil {
		return
	}
	st := "trusted"
	if !res.OK {
		st = "failed"
		if res.RolledBack {
			st = "failed (rolled back)"
		}
	}
	if res.Detail != "" {
		st += ": " + truncate(res.Detail, 300)
	}
	s.setSSHCAStatus(epID, st)
	log.Printf("node %s: ssh CA %s", epID, st)
}
