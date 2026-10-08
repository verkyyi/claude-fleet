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
	"strings"
	"time"
)

// The agent half of a writing area's attachments (claude-fleet#2393, EPIC
// #2482 C1). A worker_start from the client's writing area names the files
// the person dropped in (id · name · sha256 · size · from); the hub keeps
// their bytes, and this agent downloads each — with its own token, the only
// one the hub serves it to — into claude-fleet's attachment directory
// (`<attach>/<id>/<name>`) before it hands the write to fleet-control.py,
// which writes those paths into the text. Downloading first keeps a failed
// fetch a clean refusal, as a move's bundle is (move.go).

// attachFetchTimeout bounds all of one start's downloads: the hub waits
// fleetWriteWait for the node to take the write.
const attachFetchTimeout = 25 * time.Second

var attachIDRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

type startAttachment struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

// fetchAttachments downloads a worker_start's attachments; any other write,
// or a start naming none, is left alone. It answers a fault code and
// message, or "" when the write may go on.
func (a *Agent) fetchAttachments(ctx context.Context, envelope json.RawMessage) (string, string) {
	var env struct {
		Action string `json:"action"`
		Params struct {
			Attachments []startAttachment `json:"attachments"`
		} `json:"params"`
	}
	if json.Unmarshal(envelope, &env) != nil || env.Action != "worker_start" || len(env.Params.Attachments) == 0 {
		return "", ""
	}
	if a.attachDir == "" {
		return "UNAVAILABLE", "this node's claude-fleet cannot take attachments"
	}
	fctx, cancel := context.WithTimeout(ctx, attachFetchTimeout)
	defer cancel()
	for _, at := range env.Params.Attachments {
		if code, msg := a.fetchAttachment(fctx, at); code != "" {
			return code, msg
		}
	}
	return "", ""
}

func (a *Agent) fetchAttachment(ctx context.Context, at startAttachment) (string, string) {
	if !attachIDRE.MatchString(at.ID) || at.Name == "" || at.Name == "." || at.Name == ".." ||
		strings.ContainsAny(at.Name, `/\`+"\x00") || len(at.Name) > 200 {
		return "INVALID_ARGUMENT", "an attachment names an id and one file name"
	}
	dir := filepath.Join(a.attachDir, at.ID)
	dest := filepath.Join(dir, at.Name)
	if fileSHA256(dest) == at.SHA256 {
		return "", "" // a retried write: already here
	}
	if err := mkdirOwned(dir, 0o700); err != nil {
		return "UNAVAILABLE", "attachment directory: " + err.Error()
	}
	// The directory is the login's: never follow a link it put there.
	for _, d := range []string{a.attachDir, dir} {
		if fi, err := os.Lstat(d); err != nil || fi.Mode()&os.ModeSymlink != 0 || !fi.IsDir() {
			return "UNAVAILABLE", "attachment directory " + d + " is not a plain directory"
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.cfg.HubURL+"/v1/node/attachment/"+at.ID, nil)
	if err != nil {
		return "UNAVAILABLE", err.Error()
	}
	req.Header.Set("Authorization", "Bearer "+a.cfg.Token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "UNAVAILABLE", "download attachment " + at.Name + ": " + err.Error()
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "UNAVAILABLE", fmt.Sprintf("download attachment %s: hub answered HTTP %d", at.Name, resp.StatusCode)
	}
	tmp, err := os.CreateTemp(dir, ".fetch-*")
	if err != nil {
		return "UNAVAILABLE", "attachment directory: " + err.Error()
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(tmp, h), io.LimitReader(resp.Body, at.Size+1))
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return "UNAVAILABLE", "download attachment " + at.Name + ": " + err.Error()
	}
	if hex.EncodeToString(h.Sum(nil)) != at.SHA256 {
		return "UNAVAILABLE", "attachment " + at.Name + " arrived corrupted (sha256 mismatch)"
	}
	_ = os.Chmod(tmp.Name(), 0o600)
	ownPath(tmp.Name())
	if err := os.Rename(tmp.Name(), dest); err != nil {
		return "UNAVAILABLE", "attachment directory: " + err.Error()
	}
	return "", ""
}

// fileSHA256 is a regular file's sha256 in hex, "" when it is not one.
func fileSHA256(path string) string {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return ""
	}
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}
