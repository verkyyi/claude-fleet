package control

import (
	"crypto/ed25519"
	"strings"
	"testing"
	"time"
)

// pyClusterTicket is bin/fleet_cluster_ticket.py's sign() of the same ticket
// under the same key (seed 00..1f): the hub and the provisioner agree byte for
// byte (claude-fleet#3558) — the pod's one login and UID (#3757) and its join code (#3553) too.
const pyClusterTicket = "c1.eyJvcCI6ImNyZWF0ZS11c2VyLXBvZCIsImNsdXN0ZXIiOiJhY2stc3oiLCJwb2QiOiJ1LWExYjJjMyIsImxpbWl0cyI6ImNwdT0yLG1lbW9yeT02R2ksZGlzaz01MEdpIiwibG9naW4iOiJmbGVldHU3IiwidWlkIjoxMDAwMiwiam9pbiI6ImZqX2FiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6Iiwibm9uY2UiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZiIsImV4cCI6NDEwMjQ0NDgwMH0.XXxcMmDm0vueBEWvhMDaoXLwfnSffVmI0OacerPvkk-o4n2TDHCu92h7AdokiKlkBxk4xsUT4jQJRhRWDVl-Dw"

// pyBindTicket is the same for bind-user-pod (claude-fleet#3553).
const pyBindTicket = "c1.eyJvcCI6ImJpbmQtdXNlci1wb2QiLCJjbHVzdGVyIjoiYWNrLXN6IiwicG9kIjoidS1hMWIyYzMiLCJwcmluY2lwYWwiOiJnaC4xMjM0NSIsIm5vbmNlIjoiZmVkY2JhOTg3NjU0MzIxMGZlZGNiYTk4NzY1NDMyMTAiLCJleHAiOjQxMDI0NDQ4MDB9.j6j0ubkEdF8FHaqAUk7503wLoQPcEoZ41sDg0-wMTVepMIBTMjYqL5QrQwIVPKFY5a0zt2GoNuiIheKKAEMsCA"

// pyJobTicket is the same for create-job with its kind and command
// (claude-fleet#3552).
const pyJobTicket = "c1.eyJvcCI6ImNyZWF0ZS1qb2IiLCJjbHVzdGVyIjoiYWNrLXN6IiwicG9kIjoidS1hMWIyYzMiLCJyZXBvIjoiby9yIiwicmVmIjoiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYiIsImtpbmQiOiJ1bnRydXN0ZWQiLCJjbWQiOiJtYWtlIHRlc3QiLCJub25jZSI6IjAwMTEyMjMzNDQ1NTY2Nzc4ODk5YWFiYmNjZGRlZWZmIiwiZXhwIjo0MTAyNDQ0ODAwfQ.RIAGAEIYQuY7_ak4-CB1pExNo0dYknkp2luG0yMq_KlltkyZHzu9pZEBaAKHsMznwJRusjZhNnm8BvU4bZryAA"

// pySvcRunTicket is the same for create-svc-run (claude-fleet#4005): the run,
// its attempt, the principal's name, the deadline and the Job's key.
const pySvcRunTicket = "c1.eyJvcCI6ImNyZWF0ZS1zdmMtcnVuIiwiY2x1c3RlciI6ImFjay1zeiIsInJ1biI6IlI0MiIsImF0dGVtcHQiOjEsInN2YyI6ImxpdmVwYWdlIiwiZGVhZGxpbmUiOjkwMCwidG9rZW4iOiJmc2pfYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vbmNlIjoiMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYiLCJleHAiOjQxMDI0NDQ4MDB9.c2X_NYB3B2nayo_rW3n-acao1uwTEH1xvRb0_av1p1WXY9u6fUpn9dpKjtazQDcLMLEh7UDwMIOxncYFdxj6DQ"

// pyRollTicket is the same for roll-user-pod (claude-fleet#4174): the pod alone.
const pyRollTicket = "c1.eyJvcCI6InJvbGwtdXNlci1wb2QiLCJjbHVzdGVyIjoiYWNrLXN6IiwicG9kIjoidS1hMWIyYzMiLCJub25jZSI6IjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIiwiZXhwIjo0MTAyNDQ0ODAwfQ.QfRn-QYciYcftq0T15XlzAQhIWH3X5uWk88G5WqHQ9uPY-gNBXZra1H6_d02kUM4RXQTo1O4ZsKTaPiUVDMQAg"

func TestClusterTicketMatchesTheProvisioner(t *testing.T) {
	key := ticketKey()
	got, err := SignClusterTicket(key, ClusterTicket{Op: ClusterCreateUserPod, Cluster: "ack-sz", Pod: "u-a1b2c3",
		Limits: "cpu=2,memory=6Gi,disk=50Gi", Login: "fleetu7", UID: 10002, Join: "fj_abcdefghijklmnopqrstuvwxyz",
		Nonce: "0123456789abcdef0123456789abcdef", Exp: 4102444800})
	if err != nil {
		t.Fatal(err)
	}
	if got != pyClusterTicket {
		t.Fatalf("Go's ticket\n%s\nis not the provisioner's\n%s", got, pyClusterTicket)
	}
	tk, err := VerifyClusterTicket(key.Public().(ed25519.PublicKey), pyClusterTicket, time.Unix(4102444799, 0))
	if err != nil || tk.Pod != "u-a1b2c3" || tk.Op != ClusterCreateUserPod || tk.Cluster != "ack-sz" || tk.Join == "" ||
		tk.Login != "fleetu7" || tk.UID != 10002 {
		t.Fatalf("verify: %+v %v", tk, err)
	}
	bind, err := SignClusterTicket(key, ClusterTicket{Op: ClusterBindUserPod, Cluster: "ack-sz", Pod: "u-a1b2c3",
		Principal: "gh.12345", Nonce: "fedcba9876543210fedcba9876543210", Exp: 4102444800})
	if err != nil || bind != pyBindTicket {
		t.Fatalf("Go's bind ticket\n%s\nis not the provisioner's\n%s (%v)", bind, pyBindTicket, err)
	}
	job, err := SignClusterTicket(key, ClusterTicket{Op: ClusterCreateJob, Cluster: "ack-sz", Pod: "u-a1b2c3",
		Repo: "o/r", Ref: strings.Repeat("b", 40), Kind: "untrusted", Cmd: "make test",
		Nonce: "00112233445566778899aabbccddeeff", Exp: 4102444800})
	if err != nil || job != pyJobTicket {
		t.Fatalf("Go's job ticket\n%s\nis not the provisioner's\n%s (%v)", job, pyJobTicket, err)
	}
	svc, err := SignClusterTicket(key, ClusterTicket{Op: ClusterCreateSvcRun, Cluster: "ack-sz", Run: "R42",
		Attempt: 1, Svc: "livepage", Deadline: 900, Token: "fsj_" + strings.Repeat("a", 52),
		Nonce: "0123456789abcdef0123456789abcdef", Exp: 4102444800})
	if err != nil || svc != pySvcRunTicket {
		t.Fatalf("Go's svc run ticket\n%s\nis not the provisioner's\n%s (%v)", svc, pySvcRunTicket, err)
	}
	roll, err := SignClusterTicket(key, ClusterTicket{Op: ClusterRollUserPod, Cluster: "ack-sz", Pod: "u-a1b2c3",
		Nonce: "0123456789abcdef0123456789abcdef", Exp: 4102444800})
	if err != nil || roll != pyRollTicket {
		t.Fatalf("Go's roll ticket\n%s\nis not the provisioner's\n%s (%v)", roll, pyRollTicket, err)
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
