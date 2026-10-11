package control

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
// parts, never a comment.
type EntryNodeKey struct {
	FP   string `json:"fp"`
	Type string `json:"type"`
	B64  string `json:"b64"`
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
}
