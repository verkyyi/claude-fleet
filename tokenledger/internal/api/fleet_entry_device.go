package api

import (
	"log"
	"time"
)

// A computer's own key on its person's door list (claude-fleet#3075, EPIC
// #3067 C9). `fleet login` makes ~/.ssh/fleet-cert and the hub registers it as
// a device; with the direct door on, the same public key is put on the
// person's entry keys as an ordinary key — the keys page shows it as
// 「<device> · fleet」 — so `fleet connect`'s `entry` route lets that computer in
// at its home's entry port with no Tailscale and no relay. Revoking the device
// revokes that key too. The door is off ⇒ nothing here runs.

// entryDeviceSuffix marks a key the hub put there for a device.
const entryDeviceSuffix = " · fleet"

// entryDeviceLabel is the name a device's key carries on the keys page.
func entryDeviceLabel(device string) string {
	if device == "" {
		device = "这台电脑"
	}
	return entryLabel(device + entryDeviceSuffix)
}

// entryDeviceKey puts a device's public key on pid's door list. proof is a
// scan or a web issuance — the person just proved who they are, so a key they
// once revoked on the keys page comes back; a renewal (proof=false) adds it
// only when the list never held it, so a key the person took off stays off.
// Best effort: a refusal is logged, never fatal to the sign-in.
func (s *Server) entryDeviceKey(pid, keyLine, device string, proof bool, now time.Time) {
	if s.Store == nil || !s.entryOn() || pid == "" {
		return
	}
	_, _, fp, _, err := parseEntryKey(keyLine)
	if err != nil {
		return // a key the door does not take (an RSA under 3072 bits): the relay and the tailnet still work
	}
	keys, err := s.Store.EntryKeys(pid, true)
	if err != nil {
		log.Printf("entry: keys of %s: %v", pid, err)
		return
	}
	for _, k := range keys {
		if k.FP == fp && (k.RevokedAt == nil || !proof) {
			return // live already, or taken off by the person and this is no fresh proof
		}
	}
	if _, _, _, err := s.entryAdd(entryCaller{actor: pid, person: pid}, keyLine, entryDeviceLabel(device), now); err != nil {
		log.Printf("entry: device %s of %s: %v", fp, pid, err)
	}
}

// entryDeviceRevoke revokes every live door key of pid's with the device's
// fingerprint fp — the same key, however it got on the list.
func (s *Server) entryDeviceRevoke(pid, fp, actor string, now time.Time) {
	if s.Store == nil || !s.entryOn() || pid == "" || fp == "" {
		return
	}
	keys, err := s.Store.EntryKeys(pid, false)
	if err != nil {
		log.Printf("entry: keys of %s: %v", pid, err)
		return
	}
	for _, k := range keys {
		if k.FP != fp {
			continue
		}
		if _, _, err := s.entryRevoke(entryCaller{actor: actor, person: pid}, k.ID, now); err != nil {
			log.Printf("entry: revoke device key %s of %s: %v", fp, pid, err)
		}
	}
}
