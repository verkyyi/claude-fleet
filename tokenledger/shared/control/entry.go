package control

import "time"

// The direct door (claude-fleet#3068, EPIC #3067 C1/C3).

// TypeEntryKeys is the hub's word that the direct door's list for a home
// machine is at Version: sent to a node that listed CapEntryKeys when a
// person whose home it is (or was) adds or revokes a key, changes their
// address name or their home, and on the first heartbeat of each connection.
// The node pulls EntryKeysNodePath with the machine's token; it answers
// nothing. Never sent while the hub's fleet.entry is off.
const TypeEntryKeys = "entry_keys"

// CapEntryKeys is the hello capability a machine program lists when it keeps
// the direct door's key files. An older agent never says it and is never sent
// TypeEntryKeys.
const CapEntryKeys = "entry_keys"

// EntryKeys is TypeEntryKeys' payload.
type EntryKeys struct {
	Version int `json:"version"`
}

// The direct door's HTTP paths.
const (
	// EntryKeysPath is a person's own keys: GET (list), POST (add),
	// PATCH/DELETE EntryKeysPath+"/<id>" (rename / revoke).
	EntryKeysPath = "/v1/fleet/entry/keys"
	// EntryNamePath is PUT {name}: the person's address name.
	EntryNamePath = "/v1/fleet/entry/name"
	// EntryHomePath is PUT {machine, login?}: the person's home.
	EntryHomePath = "/v1/fleet/entry/home"
	// EntryKeysNodePath is GET with the machine's token: every login homed
	// on it and its live keys.
	EntryKeysNodePath = "/v1/node/entry-keys"
	// EntryAuditNodePath is POST {lines:[…]} with the machine's token: the
	// door's record, sent late when the hub was away.
	EntryAuditNodePath = "/v1/node/entry-audit"
)

// EntryNodeKey is one key in EntryNodeList: the authorized_keys line's
// parts, never a comment. Name is the person's label for it — the device the
// home's 看台 says it is (claude-fleet#3071); it never enters the keys file.
type EntryNodeKey struct {
	FP   string `json:"fp"`
	Type string `json:"type"`
	B64  string `json:"b64"`
	Name string `json:"name,omitempty"`
}

// EntryNodeLogin is one login homed on the machine.
type EntryNodeLogin struct {
	Person string         `json:"person"`
	Keys   []EntryNodeKey `json:"keys"`
}

// EntryNodeList is EntryKeysNodePath's answer. Version only goes up.
type EntryNodeList struct {
	Version int                       `json:"version"`
	Logins  map[string]EntryNodeLogin `json:"logins"`
	// DoorCA is the door-session CA's public key (A5SQ) when this hub has a
	// door and a CA: the home's entry sshd trusts it, for each login its own
	// name alone (DoorSessionCert). "" = absent, the list as before.
	DoorCA string `json:"door_ca,omitempty"`
}

// EntryReachNodePath is POST EntryReachReport with the machine's token
// (claude-fleet#3072, EPIC #3067 C6): the home machine says how the outside
// could reach its entry port; the hub dials each address from where it
// stands and answers an EntryReachVerdict.
const EntryReachNodePath = "/v1/node/entry-reach"

// EntryPortMap is what the machine's own router said when asked to forward
// the entry port (NAT-PMP or UPnP; FLEET_ENTRY_PORTMAP=auto|off). Method
// "" = not tried; Error set = tried and refused / no answer.
type EntryPortMap struct {
	Method       string `json:"method,omitempty"`
	ExternalIP   string `json:"external_ip,omitempty"`
	ExternalPort int    `json:"external_port,omitempty"`
	Error        string `json:"error,omitempty"`
}

// EntryReachReport is one home machine's reading, every five minutes.
// The public IPv4 is never the machine's say: it is the address the hub sees
// the report come from.
type EntryReachReport struct {
	// Port is the entry port, HostKey its host key "<type> <base64>" — an
	// address counts only when the sshd answering there shows this key.
	Port    int    `json:"port"`
	HostKey string `json:"host_key"`
	// Listening: the entry sshd is up (someone has their home here).
	Listening bool `json:"listening"`
	// V6 is the machine's global IPv6 addresses; LAN its private IPv4 ones
	// (only for the "open this port to …" hint, never dialled).
	V6      []string      `json:"v6,omitempty"`
	LAN     []string      `json:"lan,omitempty"`
	PortMap *EntryPortMap `json:"portmap,omitempty"`
	// EntryHost / EntryPort are the machine's operator-written entry route
	// (CCQUOTA_FLEET_NODE_ROUTES entry=host:port): the public port the
	// router forwards to the entry port, which need not be Port. The hub
	// dials the source address — and the host's own addresses — on it.
	EntryHost string `json:"entry_host,omitempty"`
	EntryPort int    `json:"entry_port,omitempty"`
	// HeldBy names another listener holding the entry port ("pid N: <command>"),
	// or one an earlier daemon left that answers with the entry's key while the
	// daemon's own entry is not running (claude-fleet T702); "" otherwise.
	HeldBy string `json:"held_by,omitempty"`
}

// Entry reach reasons: why an address did not count.
const (
	ReachTimeout = "timeout" // nothing answered
	ReachRefused = "refused" // the port is closed there
	ReachHostKey = "hostkey" // an sshd answered with another host key
	ReachNotSSH  = "not_ssh" // something answered that is no sshd
	ReachNoRoute = "unreachable"
)

// EntryReachAddr is one address the hub tried.
type EntryReachAddr struct {
	Addr      string     `json:"addr"`
	Family    string     `json:"family"` // "ipv4" | "ipv6"
	Port      int        `json:"port"`
	Via       string     `json:"via"` // "source" | "portmap" | "route" | "ipv6"
	Reachable bool       `json:"reachable"`
	Reason    string     `json:"reason,omitempty"`
	LastOK    *time.Time `json:"last_ok,omitempty"`
}

// EntryReachVerdict is EntryReachNodePath's answer: what the doctor's
// `public` row reads.
type EntryReachVerdict struct {
	CheckedAt time.Time `json:"checked_at"`
	// Source is the address the report came from, as the hub saw it.
	Source string `json:"source,omitempty"`
	// NoPublic says why this machine looks to have no public IPv4 of its
	// own ("cgnat": carrier NAT) — "" when it has, or nobody can tell.
	NoPublic string           `json:"no_public,omitempty"`
	Addrs    []EntryReachAddr `json:"addrs"`
	// Throttled: a report inside the last check's window, answered from it.
	Throttled bool `json:"throttled,omitempty"`
	// HostKeyChanged: this machine's entry host key changed and the hub's
	// alert about it is still open (claude-fleet T743) — the machine's logins
	// each record one error-level message from it (fleet-alerts.sh).
	HostKeyChanged *EntryHostKeyChange `json:"host_key_changed,omitempty"`
	// HostCert is the reported entry host key signed by the hub's host CA
	// (claude-fleet T743), one "<cert type> <base64> host:<machine>" line —
	// the entry sshd shows it (HostCertificate). "" when the hub has no CA.
	HostCert string `json:"host_cert,omitempty"`
}

// EntryHostKeyChange is the old and new fingerprints of a changed entry host
// key and when the hub first saw it.
type EntryHostKeyChange struct {
	Old   string    `json:"old"`
	New   string    `json:"new"`
	Since time.Time `json:"since"`
}

// EntryRoutesNodePath is GET with the door's token (claude-fleet#3549, EPIC
// #3500 C4): the cluster's one public door reads every person whose home is
// their own pod — the login it lets in, with that person's keys, and the pod
// it hands them to. Version is EntryNodeList's: one counter, one push.
const EntryRoutesNodePath = "/v1/node/entry-routes"

// EntryRoute is one row of the door's table: Login is the name the door's
// sshd lets in (only with Principal's own keys), Service the pod's Service
// in the door's namespace (u-<nonce>) — the one place it may go.
type EntryRoute struct {
	Login     string `json:"login"`
	Principal string `json:"principal"`
	Service   string `json:"service"`
	// PodLogin is the login the door logs in as on the pod when it is not
	// Login: a person's second pod, reached as <login>.<repo>
	// (claude-fleet#3562). "" = Login.
	PodLogin string `json:"pod_login,omitempty"`
}

// EntryRouteList is EntryRoutesNodePath's answer: Routes the table, Logins
// the same keys shape a home machine's list has (the door converges it the
// same way).
type EntryRouteList struct {
	Version int                       `json:"version"`
	Routes  []EntryRoute              `json:"routes"`
	Logins  map[string]EntryNodeLogin `json:"logins"`
	// Homes is every person whose home is a machine of their own (not a pod)
	// — the door's one address, routed by username (A5SQ): only when the
	// door's pull asked ?home=1, else absent, so an older door reads the
	// list byte for byte.
	Homes []EntryHomeRoute `json:"homes,omitempty"`
}

// EntryHomeRoute is one person the door takes home (A5SQ): Login is the
// username they give the door and the login on their home, Keys theirs. The
// door terminates their SSH with these keys; the hop to the home is a
// DoorSessionCert the hub signs only for a signature of theirs.
type EntryHomeRoute struct {
	Principal string         `json:"principal"`
	Login     string         `json:"login"`
	Keys      []EntryNodeKey `json:"keys"`
}

// DoorHomePath is the door's stream to a person's home (A5SQ): a websocket,
// GET ?principal=<person> with the door's own machine token. The hub finds
// that person's home — a machine, never a pod — and splices the stream onto
// the home's entry port through its agent (TypeSSHRelayOpen, Target
// SSHRelayTargetEntry). The stream reaches only a handshake: the home's entry
// sshd logs the person in only with a DoorSessionCert for its own login.
const DoorHomePath = "/v1/node/door-home"

// DoorSessionPath is POST with the door's machine token (A5SQ): the door
// hands the hub what a person signed to log in to the door, and the hub —
// having checked the signature against that person's registered key and
// that this session was never presented before — signs a short-lived
// certificate for the door's one-off key, admitting only that person's home
// login. The door holds no key into any home: without a fresh signature of
// the person's, there is no certificate.
const DoorSessionPath = "/v1/node/door-session"

// DoorSessionRequest is DoorSessionPath's body. The hub rebuilds the signed
// data itself (RFC 4252 §7) from SessionID, User and Key: the door cannot
// hand it anything else to verify.
type DoorSessionRequest struct {
	// Key is the person's public key as they offered it (authorized_keys form).
	Key string `json:"key"`
	// User is the username they gave the door (their home login).
	User string `json:"user"`
	// SessionID is the SSH session identifier of their connection to the door, base64.
	SessionID string `json:"session_id"`
	// Algo is the public key algorithm named in their request (ssh-ed25519, rsa-sha2-256, …).
	Algo string `json:"algo"`
	// Sig is their signature, the SSH wire form (string format, string blob), base64.
	Sig string `json:"sig"`
	// DoorKey is the door's one-off key for this hop (authorized_keys form).
	DoorKey string `json:"door_key"`
}

// DoorSessionCert is DoorSessionPath's answer.
type DoorSessionCert struct {
	// Cert is the user certificate for DoorKey (authorized_keys form).
	Cert      string `json:"cert"`
	Principal string `json:"principal"`
	Login     string `json:"login"`
	Machine   string `json:"machine"`
	// HostKeys are the home entry sshd's host keys as the home reported them:
	// the door checks the hop against these, never trusting on first use.
	HostKeys    []string  `json:"host_keys"`
	ValidBefore time.Time `json:"valid_before"`
}

// DoorSessionTTL is how long a door-session certificate lives: one login.
const DoorSessionTTL = 2 * time.Minute

// DoorSessionKeyIDPrefix starts every door-session certificate's key id:
// "door:<person>:<session hash>" — what the home's sshd logs on the login.
const DoorSessionKeyIDPrefix = "door:"
