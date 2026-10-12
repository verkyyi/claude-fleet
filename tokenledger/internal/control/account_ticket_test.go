package control

import (
	"crypto/ed25519"
	"strings"
	"testing"
	"time"
)

// pyTicket is bin/fleet_admin_ticket.py's encoding of the same ticket under the
// same key (seed 00..1f): ed25519 is deterministic and the payload bytes are
// Go's json.Marshal of AccountTicket, so the hub and the machine's verifier
// agree byte for byte (claude-fleet#3557).
const pyTicket = "v1.eyJvcCI6InJlbW92ZSIsImxvZ2luIjoiYWxpY2UiLCJtYWNoaW5lIjoibWFjLWEiLCJub25jZSI6IjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIiwiZXhwIjo0MTAyNDQ0ODAwfQ.9qry3jCBx_1_1X2-CDhw9Gmj0_TP0-crsbCyR6XriMmH148rBKjxDodlGuKWlFS38dZNAboZVenlkjcCJcjKCQ"

func ticketKey() ed25519.PrivateKey {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	return ed25519.NewKeyFromSeed(seed)
}

func TestAccountTicketMatchesTheMachineVerifier(t *testing.T) {
	key := ticketKey()
	got, err := SignAccountTicket(key, AccountTicket{Op: AccountRemove, Login: "alice", Machine: "mac-a",
		Nonce: "0123456789abcdef0123456789abcdef", Exp: 4102444800})
	if err != nil {
		t.Fatal(err)
	}
	if got != pyTicket {
		t.Fatalf("Go's ticket\n%s\nis not the Python verifier's\n%s", got, pyTicket)
	}
	tk, err := VerifyAccountTicket(key.Public().(ed25519.PublicKey), pyTicket, time.Unix(4102444799, 0))
	if err != nil || tk.Login != "alice" || tk.Op != AccountRemove || tk.Machine != "mac-a" {
		t.Fatalf("verify: %+v %v", tk, err)
	}
}

// fleetadmin-forged-op's hub half: a ticket not signed by the key, tampered
// with, past its exp, or not a ticket at all is refused.
func TestAccountTicketRefusesForgedExpiredMalformed(t *testing.T) {
	key := ticketKey()
	pub := key.Public().(ed25519.PublicKey)
	now := time.Unix(4102444799, 0)
	_, other, _ := ed25519.GenerateKey(nil)
	forged, _ := SignAccountTicket(other, AccountTicket{Op: AccountRemove, Login: "alice", Machine: "mac-a",
		Nonce: "0123456789abcdef0123456789abcdef", Exp: 4102444800})
	p64, s64, _ := strings.Cut(strings.TrimPrefix(pyTicket, "v1."), ".")
	tampered := "v1.X" + p64[1:] + "." + s64
	cases := map[string]struct {
		t   string
		now time.Time
	}{
		"forged":    {forged, now},
		"tampered":  {tampered, now},
		"expired":   {pyTicket, time.Unix(4102444800, 0)},
		"empty":     {"", now},
		"no prefix": {strings.TrimPrefix(pyTicket, "v1."), now},
		"no sig":    {"v1." + p64, now},
	}
	for name, c := range cases {
		if _, err := VerifyAccountTicket(pub, c.t, c.now); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := SignAccountTicket(nil, AccountTicket{}); err == nil {
		t.Error("signed with no key")
	}
}
