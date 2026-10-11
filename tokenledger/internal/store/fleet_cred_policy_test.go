package store

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestCredPolicyInstallAndMigration(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "policy.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err = s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	get := func() map[string]string {
		m, e := s.FleetSettings()
		if e != nil {
			t.Fatal(e)
		}
		return m
	}
	if get()["fleet.cred_policy.mode"] != "strict" {
		t.Fatal("new install must default deny")
	}
	if err = s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	if get()["fleet.cred_policy.mode"] != "strict" {
		t.Fatal("reopen reset mode")
	}
	// Simulate the schema of an older installation without a mode marker.
	if err = s.SetFleetSetting("fleet.cred_policy.mode", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err = s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	if get()["fleet.cred_policy.mode"] != "legacy" {
		t.Fatal("upgrade silently denied existing access")
	}
	before := get()
	if err = s.SetFleetSetting("fleet.cred_allow.user.gh:1", "[]", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err = s.ActivateCredPolicy(before, []string{"fleet.cred_allow.node.m4"}, "admin", time.Now()); !errors.Is(err, ErrCredPolicyChanged) {
		t.Fatalf("concurrent change: %v", err)
	}
	after := get()
	if after["fleet.cred_policy.mode"] != "legacy" || after["fleet.cred_allow.node.m4"] != "" {
		t.Fatal("failed activation partially wrote grants")
	}
	if err = s.ActivateCredPolicy(after, []string{"fleet.cred_allow.node.m4"}, "admin", time.Now()); err != nil {
		t.Fatal(err)
	}
	if get()["fleet.cred_policy.mode"] != "strict" {
		t.Fatal("activation missing")
	}
}
