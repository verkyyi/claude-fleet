package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A worker's evidence and history, handed to the hub by the machine that
// reaped it (claude-fleet#1609, EPIC #1645 C9).
//
// A member the hub placed on another machine captured its 改动前 / 改动后 and
// was reaped THERE: the machine that ran the EPIC read 无证据 for it and had no
// /fleet-history row. Now the reaping node uploads what the worker left —
// every evidence file and its history ledger row — with its own enrollment
// token, keyed by the worker_id (claude-fleet#1646), and any node of the same
// owner reads them back by repo + issue or EPIC. The rails:
//
//   - a node speaks only for its own workers: the worker_id's fleet must be one
//     this node reports (the relay rule, fleet_relay.go);
//   - a reader sees only its owner's records (relayOwner — the operator's
//     logins with each other, a person's with each other, never across);
//   - text first, images shrunk on the node; one file at most
//     workerRecordMaxFile, one upload at most workerRecordMaxBody;
//   - kept store.WorkerRecordTTL (30 days), then gone.

const (
	workerRecordMaxFile    = 2 << 20
	workerRecordMaxBody    = 24 << 20
	workerRecordMaxRecords = 200
)

var (
	workerRecordKinds = map[string]bool{"evidence": true, "history": true}
	workerRecordName  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+=@,-]{0,199}$`)
	workerRecordRepo  = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$`)
	workerRecordKey   = regexp.MustCompile(`^(issue|scratch)-[1-9][0-9]{0,9}$`)
)

// WorkerRecordsUpload is the body of POST /v1/node/worker-records.
type WorkerRecordsUpload struct {
	WorkerID  string `json:"worker_id"`
	OriginWID string `json:"origin_wid"`
	Repo      string `json:"repo"`
	Issue     int    `json:"issue"`
	Key       string `json:"key"`
	Epic      int    `json:"epic"`
	Records   []struct {
		Kind    string `json:"kind"`
		Name    string `json:"name"`
		Stage   string `json:"stage"`
		TS      string `json:"ts"`
		Note    string `json:"note"`
		Content []byte `json:"content"` // base64
	} `json:"records"`
}

// workerRecordOwner is who a node belongs to, for "only your own".
func (s *Server) workerRecordOwner(ep *store.Endpoint) string {
	host, user := s.peerSelf(ep)
	return s.relayOwner(ep.ID, host, user, s.activeAccounts())
}

// handleNodeWorkerRecords serves POST (upload) and GET (read) of
// /v1/node/worker-records, authenticated by a node's enrollment token.
//
//	GET ?repo=o/r[&issue=N][&epic=E][&kind=evidence|history][&worker_id=W][&content=0]
func (s *Server) handleNodeWorkerRecords(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodPost:
		s.putWorkerRecords(w, r, ep)
	case http.MethodGet:
		s.getWorkerRecords(w, r, ep)
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

func (s *Server) putWorkerRecords(w http.ResponseWriter, r *http.Request, ep *store.Endpoint) {
	var in WorkerRecordsUpload
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, workerRecordMaxBody)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object of at most 24 MiB")
		return
	}
	fid, _, err := fleetid.ParseWorkerID(in.WorkerID)
	if err != nil {
		httpError(w, http.StatusBadRequest, "worker_id: "+err.Error())
		return
	}
	if in.OriginWID != "" {
		if _, _, err := fleetid.ParseWorkerID(in.OriginWID); err != nil {
			httpError(w, http.StatusBadRequest, "origin_wid: "+err.Error())
			return
		}
	}
	if !workerRecordRepo.MatchString(in.Repo) {
		httpError(w, http.StatusBadRequest, "repo must be owner/name")
		return
	}
	if in.Key != "" && !workerRecordKey.MatchString(in.Key) {
		httpError(w, http.StatusBadRequest, "key must be issue-<N> or scratch-<N>")
		return
	}
	if in.Issue < 0 || in.Epic < 0 {
		httpError(w, http.StatusBadRequest, "issue and epic are positive numbers")
		return
	}
	if len(in.Records) == 0 || len(in.Records) > workerRecordMaxRecords {
		httpError(w, http.StatusBadRequest, fmt.Sprintf("1 to %d records", workerRecordMaxRecords))
		return
	}
	f, err := s.Store.Fleet(fid)
	if err != nil || f.EndpointID != ep.ID {
		// A node speaks only for its own workers.
		httpError(w, http.StatusForbidden, "worker_id names a fleet this node does not report")
		return
	}
	now := time.Now()
	owner := s.workerRecordOwner(ep)
	recs := make([]store.FleetWorkerRecord, 0, len(in.Records))
	for _, x := range in.Records {
		if !workerRecordKinds[x.Kind] {
			httpError(w, http.StatusBadRequest, "kind must be evidence or history")
			return
		}
		if !workerRecordName.MatchString(x.Name) {
			httpError(w, http.StatusBadRequest, "a record name is 1-200 of A-Za-z0-9._+=@,- (not starting with a dot)")
			return
		}
		if len(x.Content) > workerRecordMaxFile {
			httpError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("%s: over %d bytes — shrink it on the node", x.Name, workerRecordMaxFile))
			return
		}
		sum := sha256.Sum256([]byte(in.WorkerID + "\x00" + x.Kind + "\x00" + x.Name))
		recs = append(recs, store.FleetWorkerRecord{
			ID: hex.EncodeToString(sum[:16]), WorkerID: in.WorkerID, FleetID: fid, OriginWID: in.OriginWID,
			Owner: owner, EndpointID: ep.ID, Node: shortNode(f.Hostname), Repo: in.Repo, Issue: in.Issue,
			Key: in.Key, Epic: in.Epic, Kind: x.Kind, Name: x.Name, Stage: clip(x.Stage, 40),
			TS: clip(x.TS, 40), Note: clip(x.Note, 1000), Content: x.Content, CreatedAt: now,
		})
	}
	if n, err := s.Store.ExpireWorkerRecords(store.WorkerRecordTTL, now); err == nil && n > 0 {
		log.Printf("fleet worker records: %d expired after %s", n, store.WorkerRecordTTL)
	}
	if err := s.Store.PutWorkerRecords(recs); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	_ = s.Store.FleetAudit("node:"+ep.ID, "worker-records", fid, "stored", in.WorkerID, now)
	writeJSON(w, http.StatusOK, map[string]any{"stored": len(recs)})
}

func (s *Server) getWorkerRecords(w http.ResponseWriter, r *http.Request, ep *store.Endpoint) {
	q := r.URL.Query()
	repo := q.Get("repo")
	if !workerRecordRepo.MatchString(repo) {
		httpError(w, http.StatusBadRequest, "repo must be owner/name")
		return
	}
	issue, _ := strconv.Atoi(q.Get("issue"))
	epic, _ := strconv.Atoi(q.Get("epic"))
	kind := q.Get("kind")
	if kind != "" && !workerRecordKinds[kind] {
		httpError(w, http.StatusBadRequest, "kind must be evidence or history")
		return
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	out, err := s.Store.WorkerRecords(store.WorkerRecordQuery{
		Owner: s.workerRecordOwner(ep), Repo: repo, Issue: issue, Epic: epic, Kind: kind,
		WorkerID: q.Get("worker_id"), Content: q.Get("content") != "0", Limit: limit,
	})
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"records": out})
}

func clip(s string, n int) string {
	s = strings.Map(func(r rune) rune {
		if r == '\t' || r == '\n' || r == '\r' {
			return ' '
		}
		return r
	}, s)
	if len(s) > n {
		return s[:n]
	}
	return s
}
