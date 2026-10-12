// Package dns is the hub's one writer of address records (claude-fleet#3073,
// EPIC #3067 C7 and 共同约定 6): every person's <name>.cf.24haowan.com points
// at their home machine's reachable address, and only the hub writes it.
//
// A Provider is the zone's records as the hub may touch them: List answers
// only the records this loop made (DNSPod's remark carries Marker — a
// record without it is someone else's and is never listed, changed or
// removed), Upsert makes or changes one, Delete removes one. DNSPod is the
// real one (the legacy token API at dnsapi.cn, the same token ACME's DNS-01
// already holds), Fake the tests'.
package dns

import (
	"context"
	"os"
	"strings"
)

// Marker is the remark on every record the hub made; List answers only those.
const Marker = "fleet"

// TTL is every address record's time to live: DNSPod's free plan minimum
// (EPIC #3067 decision 2) — a changed address answers within ten minutes.
// It is the floor: claude-fleet#3337 asked for a few minutes, and 600 s is
// as low as the plan goes.
const TTL = 600

// Record is one address record. Name is the host relative to the zone
// ("verky.cf" under 24haowan.com); Type is A or AAAA — or TXT on "*.cf",
// the unclaimed-name guard (claude-fleet#3337).
type Record struct {
	ID    string `json:"id,omitempty"`
	Name  string `json:"name"`
	Type  string `json:"type"`
	Value string `json:"value"`
	TTL   int    `json:"ttl"`
}

// Provider is the zone as the hub may touch it.
type Provider interface {
	// List is every record this loop made (marked) in the zone.
	List(ctx context.Context) ([]Record, error)
	// Upsert makes r (ID empty) or changes the record r.ID to r; it
	// answers the record as it now stands.
	Upsert(ctx context.Context, r Record) (Record, error)
	// Delete removes the record id.
	Delete(ctx context.Context, id string) error
}

// Config is where the records live and with what to write them, read from
// the hub's environment:
//
//	CCQUOTA_DNS_DP_ID / CCQUOTA_DNS_DP_KEY   the DNSPod token (both, or off)
//	CCQUOTA_DNS_DOMAIN                       the zone (24haowan.com)
//	CCQUOTA_DNS_SUBDOMAIN                    the label every address sits under (cf)
//	CCQUOTA_DNS_CONTACT                      the contact DNSPod's User-Agent names
//	                                         (an e-mail; unset: none — issue #3577)
//
// The token is the whole DNSPod account's and ACME's too: it is read here,
// held in memory and sent only to dnsapi.cn — never logged, never written.
type Config struct {
	ID, Key   string
	Domain    string
	Subdomain string
	Contact   string
}

// FromEnv reads Config; ok=false when any part is missing — then the loop
// makes no call at all.
func FromEnv() (Config, bool) {
	c := Config{
		ID:        strings.TrimSpace(os.Getenv("CCQUOTA_DNS_DP_ID")),
		Key:       strings.TrimSpace(os.Getenv("CCQUOTA_DNS_DP_KEY")),
		Domain:    strings.Trim(strings.ToLower(strings.TrimSpace(os.Getenv("CCQUOTA_DNS_DOMAIN"))), "."),
		Subdomain: strings.Trim(strings.ToLower(strings.TrimSpace(os.Getenv("CCQUOTA_DNS_SUBDOMAIN"))), "."),
		Contact:   strings.TrimSpace(os.Getenv("CCQUOTA_DNS_CONTACT")),
	}
	return c, c.ID != "" && c.Key != "" && c.Domain != "" && c.Subdomain != ""
}

// Host is name's record host under sub: "verky" + "cf" → "verky.cf".
func Host(name, sub string) string { return name + "." + sub }

// NameOf is the address name a host under sub carries, "" when the host is
// not one ("verky.cf" → "verky"; "www" → "").
func NameOf(host, sub string) string {
	n, ok := strings.CutSuffix(strings.ToLower(host), "."+sub)
	if !ok || n == "" || strings.Contains(n, ".") {
		return ""
	}
	return n
}
