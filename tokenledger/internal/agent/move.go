package agent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// The agent half of moving a session between machines (claude-fleet#1426,
// EPIC #1419 C7). The hub sends the target a journalled worker_move_in naming
// a transcript bundle the source uploaded; the bundle is far bigger than a
// control frame, so this agent downloads it — with its own token, the only
// one the hub serves it to — into claude-fleet's move-in directory
// (`<movein>/<move_id>.tar`), and only then hands the write to
// fleet-control.py, which unpacks it. Downloading first keeps a failed fetch
// a clean refusal: nothing was journalled, nothing ran.

// moveFetchTimeout bounds one bundle download: the hub waits moveWriteWait
// (120 s) for the whole write.
const moveFetchTimeout = 100 * time.Second

var moveBundleIDRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

// fetchMoveBundle downloads a worker_move_in's bundle; any other write is
// left alone. It answers a fault code and message, or "" when the write may
// go on.
func (a *Agent) fetchMoveBundle(ctx context.Context, envelope json.RawMessage) (string, string) {
	var env struct {
		Action string `json:"action"`
		Params struct {
			MoveID string `json:"move_id"`
		} `json:"params"`
	}
	if json.Unmarshal(envelope, &env) != nil || env.Action != "worker_move_in" {
		return "", ""
	}
	if a.moveIn == "" {
		return "UNAVAILABLE", "this node's claude-fleet cannot take a moved session"
	}
	id := env.Params.MoveID
	if !moveBundleIDRE.MatchString(id) {
		return "INVALID_ARGUMENT", "move_id must be 32 lowercase hex digits"
	}
	dest := filepath.Join(a.moveIn, id+".tar")
	if _, err := os.Stat(dest); err == nil {
		return "", "" // a retried write: already here
	}
	if err := os.MkdirAll(a.moveIn, 0o700); err != nil {
		return "UNAVAILABLE", "move-in directory: " + err.Error()
	}
	fctx, cancel := context.WithTimeout(ctx, moveFetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(fctx, http.MethodGet, a.cfg.HubURL+"/v1/node/move/bundle/"+id, nil)
	if err != nil {
		return "UNAVAILABLE", err.Error()
	}
	req.Header.Set("Authorization", "Bearer "+a.cfg.Token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "UNAVAILABLE", "download the transcript bundle: " + err.Error()
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "UNAVAILABLE", fmt.Sprintf("download the transcript bundle: hub answered HTTP %d", resp.StatusCode)
	}
	tmp, err := os.CreateTemp(a.moveIn, ".fetch-*")
	if err != nil {
		return "UNAVAILABLE", "move-in directory: " + err.Error()
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(tmp, h), resp.Body)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return "UNAVAILABLE", "download the transcript bundle: " + err.Error()
	}
	if want := resp.Header.Get("X-Bundle-Sha256"); want != "" && want != hex.EncodeToString(h.Sum(nil)) {
		return "UNAVAILABLE", "the transcript bundle arrived corrupted (sha256 mismatch)"
	}
	if err := os.Rename(tmp.Name(), dest); err != nil {
		return "UNAVAILABLE", "move-in directory: " + err.Error()
	}
	return "", ""
}
