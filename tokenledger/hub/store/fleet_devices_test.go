package store

import (
	"errors"
	"testing"
	"time"
)

// Without proof of the private key a registration adds a key or refreshes the
// same person's live one; it never moves a key to another person nor clears
// a revocation. With proof (RebindDevice) it does both.
func TestRegisterDeviceKeepsOwnerAndRevocation(t *testing.T) {
	s := operationStore(t)
	now := time.Now().UTC()
	d := FleetDevice{Fingerprint: "SHA256:k", PrincipalID: "gh:1", PublicKey: "ssh-ed25519 AAAA k", Name: "laptop"}
	if isNew, err := s.RegisterDevice(d, now); err != nil || !isNew {
		t.Fatalf("first registration: %v %v", isNew, err)
	}
	if isNew, err := s.RegisterDevice(d, now.Add(time.Second)); err != nil || isNew {
		t.Fatalf("same person again: %v %v; want refreshed", isNew, err)
	}
	other := d
	other.PrincipalID = "gh:2"
	if _, err := s.RegisterDevice(other, now.Add(2*time.Second)); !errors.Is(err, ErrDeviceBound) {
		t.Fatalf("another person without proof: %v; want ErrDeviceBound", err)
	}
	if ok, _ := s.DeviceBindable(d.Fingerprint, "gh:2"); ok {
		t.Errorf("DeviceBindable for another person = true")
	}
	if ok, _ := s.DeviceBindable("SHA256:new", "gh:2"); !ok {
		t.Errorf("DeviceBindable for an unknown key = false")
	}
	if _, err := s.RevokeDevice(d.Fingerprint, "operator", now.Add(3*time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RegisterDevice(d, now.Add(4*time.Second)); !errors.Is(err, ErrDeviceBound) {
		t.Fatalf("revoked, same person, without proof: %v; want ErrDeviceBound", err)
	}
	got, _ := s.Device(d.Fingerprint)
	if got.PrincipalID != "gh:1" || !got.Revoked() {
		t.Fatalf("after the refusals: %+v; want gh:1, revoked", got)
	}
	if _, err := s.RebindDevice(other, now.Add(5*time.Second)); err != nil {
		t.Fatalf("with proof: %v", err)
	}
	got, _ = s.Device(d.Fingerprint)
	if got.PrincipalID != "gh:2" || got.Revoked() {
		t.Fatalf("after the proven rebind: %+v; want gh:2, live", got)
	}
}
