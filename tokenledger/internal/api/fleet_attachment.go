package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A writing area's attachments (claude-fleet#2393, EPIC #2482 C1).
//
// The files a person drops into the client's writing area live on THEIR
// computer; the session the task starts runs on one of the fleet's machines.
// So the client sends each file's bytes with its signed place request
// (`attachments`: name · from · sha256 · base64 data), the hub checks and
// keeps them in fleet_attachments, and the worker_start it sends names them
// (id · name · sha256 · size · from) — the bytes never ride the control
// channel or the journal. The chosen node's agent downloads each one with its
// own token (GET /v1/node/attachment/<id>: only the endpoint the start went
// to) into the directory its claude-fleet named, and claude-fleet writes that
// machine's path into the text where the client's path stood. A node that
// cannot take them (no CapAttach) is sent none, and the answer says so: the
// client tells the person the files did not go, never leaves them a path the
// session cannot read.

const (
	// attachFileMax bounds one attachment; attachTotalMax all of a start's;
	// attachCountMax how many. The client checks the same numbers first.
	attachFileMax  = 10 << 20
	attachTotalMax = 10 << 20
	attachCountMax = 5
	// clientPlaceBodyMax bounds a place request: base64 of attachTotalMax,
	// plus the text, the signature and the envelope's own escaping.
	clientPlaceBodyMax = 16 << 20
	// clientPlaceSmallMax is what a place request without attachments was
	// held to before them, and still is.
	clientPlaceSmallMax = 32 << 10
)

var attachIDRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

// clientAttachment is one file in a place request.
type clientAttachment struct {
	Name   string `json:"name"`
	From   string `json:"from"` // the path on the client, as the text names it
	SHA256 string `json:"sha256"`
	Data   string `json:"data"` // base64
}

// heldAttachment is one checked attachment, ready to store and name.
type heldAttachment struct {
	rec  store.FleetAttachment
	from string
	data []byte
}

// checkAttachName is a file name the node may create as is: one path
// element, printable, not hidden-dot tricks.
func checkAttachName(name string) error {
	if name == "" || len(name) > 200 || !utf8.ValidString(name) || name == "." || name == ".." ||
		strings.ContainsAny(name, `/\`) {
		return fault("INVALID_ARGUMENT", "an attachment's name is one file name (1–200 bytes, no slash)")
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return fault("INVALID_ARGUMENT", "an attachment's name has no control character")
		}
	}
	return nil
}

// checkAttachments decodes and checks a place request's attachments. Each
// id is derived from the asker, the request's key and the file, so a
// repeated request names (and stores) the same ones.
func checkAttachments(actor, idem string, in []clientAttachment, now time.Time) ([]heldAttachment, error) {
	if len(in) > attachCountMax {
		return nil, fault("INVALID_ARGUMENT", "at most "+strconv.Itoa(attachCountMax)+" attachments")
	}
	var out []heldAttachment
	total := 0
	for _, a := range in {
		if err := checkAttachName(a.Name); err != nil {
			return nil, err
		}
		if a.From == "" || len(a.From) > 1024 || strings.ContainsFunc(a.From, unicode.IsControl) {
			return nil, fault("INVALID_ARGUMENT", "an attachment's from is the client's path (1–1024 bytes)")
		}
		data, err := base64.StdEncoding.DecodeString(a.Data)
		if err != nil {
			return nil, fault("INVALID_ARGUMENT", "an attachment's data is base64")
		}
		if len(data) > attachFileMax {
			return nil, fault("INVALID_ARGUMENT", a.Name+": an attachment is at most "+strconv.Itoa(attachFileMax>>20)+" MiB")
		}
		if total += len(data); total > attachTotalMax {
			return nil, fault("INVALID_ARGUMENT", "a start's attachments are at most "+strconv.Itoa(attachTotalMax>>20)+" MiB together")
		}
		sum := sha256.Sum256(data)
		hexSum := hex.EncodeToString(sum[:])
		if a.SHA256 != "" && a.SHA256 != hexSum {
			return nil, fault("INVALID_ARGUMENT", a.Name+": the attachment's sha256 does not match its data")
		}
		idSum := sha256.Sum256([]byte(actor + "\x00" + idem + "\x00" + a.Name + "\x00" + a.From + "\x00" + hexSum))
		out = append(out, heldAttachment{
			rec: store.FleetAttachment{ID: hex.EncodeToString(idSum[:16]), Actor: actor, Name: a.Name,
				SHA256: hexSum, Size: int64(len(data)), Created: now},
			from: a.From, data: data})
	}
	return out, nil
}

// canAttach reports whether the node behind endpointID takes attachments.
func (s *Server) canAttach(ctx context.Context, endpointID string) bool {
	if c := s.nodes.get(endpointID); c != nil {
		return c.canAttach
	}
	if peer, ok := s.peerOf(ctx, endpointID); ok {
		return peer.HasCap(control.CapAttach) // another replica's link (claude-fleet#2124)
	}
	return false
}

// attachArgs binds held to endpointID and is the start's `attachments`.
func (s *Server) attachArgs(held []heldAttachment, endpointID string) ([]any, error) {
	var out []any
	for _, h := range held {
		if err := s.Store.BindFleetAttachment(h.rec.ID, endpointID); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"id": h.rec.ID, "name": h.rec.Name, "sha256": h.rec.SHA256,
			"size": float64(h.rec.Size), "from": h.from})
	}
	return out, nil
}

// handleNodeAttachment serves GET /v1/node/attachment/<id> to the endpoint
// the start naming it was sent to; to anyone else it does not exist.
func (s *Server) handleNodeAttachment(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/v1/node/attachment/")
	if !attachIDRE.MatchString(id) {
		httpError(w, http.StatusNotFound, "no such attachment")
		return
	}
	a, b, err := s.Store.FleetAttachmentData(id)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && a.TargetEndpoint != ep.ID) {
		httpError(w, http.StatusNotFound, "no such attachment")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Attachment-Sha256", a.SHA256)
	w.Header().Set("Content-Length", strconv.Itoa(len(b)))
	_, _ = io.Copy(w, bytes.NewReader(b))
}

var attachSHARE = regexp.MustCompile(`^[0-9a-f]{64}$`)

// checkAttachList checks a worker_start's `attachments` (what attachArgs
// wrote) and is it, field for field.
func checkAttachList(v any) ([]any, error) {
	bad := fault("INVALID_ARGUMENT", "attachments is a list of {id, name, sha256, size, from}")
	in, ok := v.([]any)
	if !ok || len(in) == 0 || len(in) > attachCountMax {
		return nil, bad
	}
	var out []any
	for _, e := range in {
		m, ok := e.(map[string]any)
		if !ok || len(m) != 5 {
			return nil, bad
		}
		id, _ := m["id"].(string)
		name, _ := m["name"].(string)
		sum, _ := m["sha256"].(string)
		from, _ := m["from"].(string)
		size, isNum := m["size"].(float64)
		if !attachIDRE.MatchString(id) || !attachSHARE.MatchString(sum) || !isNum || size < 0 || size > attachFileMax ||
			size != float64(int64(size)) || from == "" || len(from) > 1024 || strings.ContainsFunc(from, unicode.IsControl) {
			return nil, bad
		}
		if err := checkAttachName(name); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"id": id, "name": name, "sha256": sum, "size": size, "from": from})
	}
	return out, nil
}
