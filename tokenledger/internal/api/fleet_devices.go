package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Registered devices (claude-fleet#1470).
//
// Scanning once registers the computer: the key `fleet login` made is bound
// to the person who confirmed the code. After that, `fleet` renews the
// 12-hour certificate on its own — the device signs a timestamp with its
// private key (POST control.RenewPath), the hub checks the signature against
// the REGISTERED public key (so a certificate that has already run out is no
// obstacle), that the device is not revoked and was used inside the idle
// window, and signs a fresh certificate for the same key. Seven days without a
// use and the next `fleet` shows a QR again. The operator (or the person, for
// their own) revokes a device on the 连接 page; a revoked device's renewal
// fails at once, and the hub's own certificate checks (the relay, the route
// list, the machine pick) refuse its certificate from that moment, even
// though the certificate itself is still inside its 12 hours. Every
// registration, renewal, refusal, revocation and machine pick is an audit row.

// DeviceIdle is how long a device may go unused before it must scan again.
// The operator's decision on #1470: seven days.
const DeviceIdle = 7 * 24 * time.Hour

// renewClockSkew: a renewal's signed timestamp must be this close to the hub's
// clock. Replaying one inside the window only renews the same device's own
// certificate.
const renewClockSkew = 5 * time.Minute

// deviceAudit writes one audit row; a failure is logged, never fatal to the
// request — the audit records what happened, it does not gate it.
func (s *Server) deviceAudit(action, fp, pid, actor, detail string, at time.Time) {
	if err := s.Store.AddDeviceAudit(store.DeviceAudit{At: at, Action: action, Fingerprint: fp,
		PrincipalID: pid, Actor: actor, Detail: detail}); err != nil {
		log.Printf("fleet device audit: %v", err)
	}
}

// registerDevice binds a signed key to the person it was signed for. Called
// after a scan or a web issuance — the two paths where a person proved who
// they are — never after a renewal.
func (s *Server) registerDevice(pid, keyLine, name, via string, now time.Time) {
	key, err := sshca.ParseUserKey(keyLine)
	if err != nil {
		return
	}
	fp := ssh.FingerprintSHA256(key)
	name = cleanDeviceName(name)
	isNew, err := s.Store.RegisterDevice(store.FleetDevice{Fingerprint: fp, PrincipalID: pid,
		PublicKey: strings.TrimSpace(keyLine), Name: name}, now)
	if err != nil {
		log.Printf("fleet: register device %s for %s: %v", fp, pid, err)
		return
	}
	detail := "via " + via
	if !isNew {
		detail += " (already registered — re-bound, revocation cleared)"
	}
	if name != "" {
		detail += ", name " + name
	}
	s.deviceAudit(store.DeviceRegister, fp, pid, pid, detail, now)
}

// cleanDeviceName keeps a device's self-reported name printable and short:
// it is shown on a page, so it is held to the same token rule as a hostname.
func cleanDeviceName(name string) string {
	name = strings.TrimSpace(name)
	if len(name) > 64 {
		name = name[:64]
	}
	if !sshToken(name) {
		return ""
	}
	return name
}

// renewRequest is the body of POST control.RenewPath.
type renewRequest struct {
	PublicKey  string `json:"public_key"`
	TS         int64  `json:"ts"`
	Sig        string `json:"sig"`
	DeviceName string `json:"device_name"`
}

// refuseJSON answers a refusal with a machine-readable code beside the message,
// so the client can tell "scan again" from "try later".
func refuseJSON(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, status, map[string]string{"error": msg, "code": code})
}

// handleDeviceRenew serves control.RenewPath. No credential but the device's
// own signature: this is what `fleet` runs every time, before anything else.
//
//	200 CertResponse        renewed
//	401 bad_signature       the signature is not by this key, or the clock is off
//	404 unknown_device      never registered (or the hub has no CA): scan
//	403 device_revoked      revoked by the operator: scan
//	403 device_idle         unused for DeviceIdle: scan
//	409 no_account          the person has no active login any more
func (s *Server) handleDeviceRenew(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if s.SSHCA == nil {
		http.NotFound(w, r)
		return
	}
	var req renewRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request")
		return
	}
	key, err := sshca.ParseUserKey(req.PublicKey)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	now := time.Now()
	fp := ssh.FingerprintSHA256(key)
	if d := now.Sub(time.Unix(req.TS, 0)); d > renewClockSkew || d < -renewClockSkew {
		refuseJSON(w, http.StatusUnauthorized, "bad_signature",
			"the signed timestamp is too far from the hub's clock — check this computer's time")
		return
	}
	if err := verifySSHSig(key, []byte(req.Sig), []byte(control.RenewSigMessage(req.TS)), control.RenewSigNamespace); err != nil {
		refuseJSON(w, http.StatusUnauthorized, "bad_signature", "renewal signature refused: "+err.Error())
		return
	}
	// The signature is good: whoever sent this holds the private key. From
	// here every refusal is about the DEVICE, and is audited as such.
	dev, err := s.Store.Device(fp)
	switch {
	case errors.Is(err, store.ErrNoDevice):
		s.deviceAudit(store.DeviceRenewRefused, fp, "", "", "unknown device", now)
		refuseJSON(w, http.StatusNotFound, "unknown_device", "this computer is not registered — scan to sign in")
		return
	case err != nil:
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	case dev.Revoked():
		s.deviceAudit(store.DeviceRenewRefused, fp, dev.PrincipalID, dev.PrincipalID,
			fmt.Sprintf("revoked %s by %s", dev.RevokedAt.UTC().Format(time.RFC3339), dev.RevokedBy), now)
		refuseJSON(w, http.StatusForbidden, "device_revoked", "this device was revoked — scan to sign in again")
		return
	case now.Sub(dev.LastUsedAt) > DeviceIdle:
		s.deviceAudit(store.DeviceRenewRefused, fp, dev.PrincipalID, dev.PrincipalID,
			fmt.Sprintf("idle since %s (> %s)", dev.LastUsedAt.UTC().Format(time.RFC3339), DeviceIdle), now)
		refuseJSON(w, http.StatusForbidden, "device_idle",
			fmt.Sprintf("this device has not been used for %d days — scan to sign in again", int(DeviceIdle.Hours()/24)))
		return
	}
	resp, err := s.issueCert(r, dev.PrincipalID, req.PublicKey, "renew")
	if err != nil {
		s.deviceAudit(store.DeviceRenewRefused, fp, dev.PrincipalID, dev.PrincipalID, err.Error(), now)
		code := "issue_failed"
		if errors.Is(err, errNoAccount) {
			code = "no_account"
		}
		refuseJSON(w, certErrStatus(err), code, err.Error())
		return
	}
	if err := s.Store.TouchDevice(fp, now, "", true); err != nil {
		log.Printf("fleet: touch device %s: %v", fp, err)
	}
	if name := cleanDeviceName(req.DeviceName); name != "" && name != dev.Name {
		// The device's name is its own word; keep the newest.
		_, _ = s.Store.RegisterDevice(store.FleetDevice{Fingerprint: fp, PrincipalID: dev.PrincipalID,
			PublicKey: strings.TrimSpace(req.PublicKey), Name: name}, dev.RegisteredAt)
		_ = s.Store.TouchDevice(fp, now, "", false)
	}
	s.deviceAudit(store.DeviceRenew, fp, dev.PrincipalID, dev.PrincipalID,
		"serial "+resp.Serial+", until "+resp.ValidBefore.UTC().Format(time.RFC3339), now)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

// deviceOfCert names the device behind a connection certificate: the
// fingerprint of the key it certifies.
func deviceOfCert(certLine string) string {
	pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(certLine))
	if err != nil {
		return ""
	}
	c, ok := pub.(*ssh.Certificate)
	if !ok {
		return ""
	}
	return ssh.FingerprintSHA256(c.Key)
}

// DevicesResponse is the body of GET /v1/fleet/devices.
type DevicesResponse struct {
	// Mine is true when the list is one person's own (a WeCom session), false
	// for the operator's view of everyone's.
	Mine    bool                `json:"mine"`
	IdleSec int                 `json:"idle_sec"`
	Devices []store.FleetDevice `json:"devices"`
	Audit   []store.DeviceAudit `json:"audit"`
}

// handleFleetDevices serves GET /v1/fleet/devices (behind viewerOnly): a
// signed-in person sees their own devices and audit, the operator's doors see
// everyone's.
func (s *Server) handleFleetDevices(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	pid := principalOf(r.Context())
	devs, err := s.Store.Devices(pid, 200)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	audit, err := s.Store.DeviceAuditLog(pid, 100)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for i := range devs {
		devs[i].PublicKey = "" // the fingerprint identifies it; the key line is noise on a page
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, DevicesResponse{Mine: pid != "", IdleSec: int(DeviceIdle.Seconds()), Devices: devs, Audit: audit})
}

// handleFleetDeviceRevoke serves POST /v1/fleet/devices/revoke
// {fingerprint} (behind viewerOnly): the operator revokes any device, a
// person only their own. Idempotent: revoking twice answers 200 with
// changed=false.
func (s *Server) handleFleetDeviceRevoke(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	var req struct {
		Fingerprint string `json:"fingerprint"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil || req.Fingerprint == "" {
		httpError(w, http.StatusBadRequest, "body must be {\"fingerprint\": \"SHA256:…\"}")
		return
	}
	dev, err := s.Store.Device(req.Fingerprint)
	if errors.Is(err, store.ErrNoDevice) {
		httpError(w, http.StatusNotFound, "no such device")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	pid := principalOf(r.Context())
	actor := "operator"
	if pid != "" {
		if dev.PrincipalID != pid {
			httpError(w, http.StatusForbidden, "not your device")
			return
		}
		actor = pid
	} else if v := viewerOf(r.Context()); v != "" {
		actor = v
	}
	now := time.Now()
	changed, err := s.Store.RevokeDevice(req.Fingerprint, actor, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if changed {
		s.deviceAudit(store.DeviceRevoke, req.Fingerprint, dev.PrincipalID, actor, "name "+dev.Name, now)
		log.Printf("fleet: device %s (%s, %s) revoked by %s", req.Fingerprint, dev.Name, dev.PrincipalID, actor)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"changed": changed, "fingerprint": req.Fingerprint})
}
