package control

import (
	"crypto/ed25519"
	"strings"
	"testing"
	"time"
)

// pyClusterTicket is bin/fleet_cluster_ticket.py's sign() of the same ticket
// under the same key (seed 00..1f): the hub and the provisioner agree byte for
// byte (claude-fleet#3558).
const pyClusterTicket = "c1.eyJvcCI6ImNyZWF0ZS11c2VyLXBvZCIsImNsdXN0ZXIiOiJhY2stc3oiLCJwb2QiOiJ1LWExYjJjMyIsImxpbWl0cyI6ImNwdT0yLG1lbW9yeT02R2ksZGlzaz01MEdpIiwibm9uY2UiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZiIsImV4cCI6NDEwMjQ0NDgwMH0.-narw2lc_C2W7LuL6Jcr6QBjWhji0qIiVnCvLH2E9N68w93q8gFJ0_bEMzTXdr6LJC-j_n-21FkJgPlgIicJDg"

func TestClusterTicketMatchesTheProvisioner(t *testing.T) {
	key := ticketKey()
	got, err := SignClusterTicket(key, ClusterTicket{Op: ClusterCreateUserPod, Cluster: "ack-sz", Pod: "u-a1b2c3",
		Limits: "cpu=2,memory=6Gi,disk=50Gi", Nonce: "0123456789abcdef0123456789abcdef", Exp: 4102444800})
	if err != nil {
		t.Fatal(err)
	}
	if got != pyClusterTicket {
		t.Fatalf("Go's ticket\n%s\nis not the provisioner's\n%s", got, pyClusterTicket)
	}
	tk, err := VerifyClusterTicket(key.Public().(ed25519.PublicKey), pyClusterTicket, time.Unix(4102444799, 0))
	if err != nil || tk.Pod != "u-a1b2c3" || tk.Op != ClusterCreateUserPod || tk.Cluster != "ack-sz" {
		t.Fatalf("verify: %+v %v", tk, err)
	}
}

// provisioner-off-template's hub half: a ticket not the key's, tampered,
// expired, an account ticket offered as a cluster one, or an op the
// provisioner has not got, is refused.
func TestClusterTicketRefusesForgedExpiredCrossDomain(t *testing.T) {
	key := ticketKey()
	pub := key.Public().(ed25519.PublicKey)
	now := time.Unix(4102444799, 0)
	_, other, _ := ed25519.GenerateKey(nil)
	forged, _ := SignClusterTicket(other, ClusterTicket{Op: ClusterDestroyUserPod, Cluster: "ack-sz",
		Pod: "u-a1b2c3", Nonce: "0123456789abcdef0123456789abcdef", Exp: 4102444800})
	p64, s64, _ := strings.Cut(strings.TrimPrefix(pyClusterTicket, "c1."), ".")
	cases := map[string]struct {
		t   string
		now time.Time
	}{
		"forged":         {forged, now},
		"tampered":       {"c1.X" + p64[1:] + "." + s64, now},
		"expired":        {pyClusterTicket, time.Unix(4102444800, 0)},
		"account ticket": {pyTicket, now},
		"account body":   {"c1." + strings.TrimPrefix(pyTicket, "v1."), now},
		"empty":          {"", now},
	}
	for name, c := range cases {
		if _, err := VerifyClusterTicket(pub, c.t, c.now); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := SignClusterTicket(key, ClusterTicket{Op: "create-pod", Cluster: "x", Nonce: "n", Exp: 1}); err == nil {
		t.Error("signed an op the provisioner has not got")
	}
}
