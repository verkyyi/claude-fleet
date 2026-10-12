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
const pyClusterTicket = "c1.eyJvcCI6ImNyZWF0ZS11c2VyLXBvZCIsImNsdXN0ZXIiOiJhY2stc3oiLCJwb2QiOiJ1LWExYjJjMyIsImxpbWl0cyI6ImNwdT0yLG1lbW9yeT02R2ksZGlzaz01MEdpIiwiam9pbiI6ImZqX2FiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6Iiwibm9uY2UiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZiIsImV4cCI6NDEwMjQ0NDgwMH0.8ntWNtBuq0lt9mdZx7PFBcQar8RNTLUxyGVgoAPUn0rWUraBjoWh6NepVzwnlk9c1iTyZg4SZ8IUBLcRD7Q1Bg"

// pyBindTicket is the same for bind-user-pod (claude-fleet#3553).
const pyBindTicket = "c1.eyJvcCI6ImJpbmQtdXNlci1wb2QiLCJjbHVzdGVyIjoiYWNrLXN6IiwicG9kIjoidS1hMWIyYzMiLCJwcmluY2lwYWwiOiJnaC4xMjM0NSIsIm5vbmNlIjoiZmVkY2JhOTg3NjU0MzIxMGZlZGNiYTk4NzY1NDMyMTAiLCJleHAiOjQxMDI0NDQ4MDB9.j6j0ubkEdF8FHaqAUk7503wLoQPcEoZ41sDg0-wMTVepMIBTMjYqL5QrQwIVPKFY5a0zt2GoNuiIheKKAEMsCA"

func TestClusterTicketMatchesTheProvisioner(t *testing.T) {
	key := ticketKey()
	got, err := SignClusterTicket(key, ClusterTicket{Op: ClusterCreateUserPod, Cluster: "ack-sz", Pod: "u-a1b2c3",
		Limits: "cpu=2,memory=6Gi,disk=50Gi", Join: "fj_abcdefghijklmnopqrstuvwxyz", Nonce: "0123456789abcdef0123456789abcdef", Exp: 4102444800})
	if err != nil {
		t.Fatal(err)
	}
	if got != pyClusterTicket {
		t.Fatalf("Go's ticket\n%s\nis not the provisioner's\n%s", got, pyClusterTicket)
	}
	tk, err := VerifyClusterTicket(key.Public().(ed25519.PublicKey), pyClusterTicket, time.Unix(4102444799, 0))
	if err != nil || tk.Pod != "u-a1b2c3" || tk.Op != ClusterCreateUserPod || tk.Cluster != "ack-sz" || tk.Join == "" {
		t.Fatalf("verify: %+v %v", tk, err)
	}
	bind, err := SignClusterTicket(key, ClusterTicket{Op: ClusterBindUserPod, Cluster: "ack-sz", Pod: "u-a1b2c3",
		Principal: "gh.12345", Nonce: "fedcba9876543210fedcba9876543210", Exp: 4102444800})
	if err != nil || bind != pyBindTicket {
		t.Fatalf("Go's bind ticket\n%s\nis not the provisioner's\n%s (%v)", bind, pyBindTicket, err)
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
