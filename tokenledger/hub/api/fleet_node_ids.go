package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The ID mirror's node road (EPIC T497 C2; design page §3.3, §7). A node pushes
// each window's ledger ($FLEET_CONF_DIR/ids/<ID>.ndjson — bin/fleet-id.sh push)
// in (ID, seq) order with its own node token; the hub folds it into fleet_ids
// (store.ApplyFleetIDEvents) and answers where it is:
//
//	POST /v1/node/ids        {id, events:[…]} → {id, seq, short}: the last seq the
//	                         hub holds (push from seq+1 next) and the code the ID
//	                         goes by — longer than the node's when another ID of
//	                         the owner shared it (S12); 409 {code: DUPLICATE_ID}
//	                         when another machine registered that full ID (S13)
//	GET  /v1/node/ids        → {ids:[{id, short}]}: every ID of this node's owner,
//	                         what the node's short codes are kept apart from
//	GET  /v1/node/ids/<ID|T-code> → the record; a code two IDs share is 409
//	                         {code: AMBIGUOUS, candidates} — never a pick
//
// A node reads and writes only its owner's IDs (nodeTaskOwner). No hub, no call:
// the node's ledger is the record and this is its mirror.
const NodeIDsPath = "/v1/node/ids"

type nodeIDPush struct {
	ID     string           `json:"id"`
	Events []map[string]any `json:"events"`
}

func (s *Server) handleNodeIDs(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	owner := s.nodeTaskOwner(ep)
	ref := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, NodeIDsPath), "/")
	switch {
	case ref == "" && r.Method == http.MethodPost:
		var in nodeIDPush
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
		dec.UseNumber()
		if err := dec.Decode(&in); err != nil {
			httpError(w, http.StatusBadRequest, "the body is one JSON object {id, events}")
			return
		}
		if !store.IsFleetID(in.ID) {
			httpError(w, http.StatusBadRequest, "id must be a lowercase UUID (a window's @fleet_id)")
			return
		}
		if len(in.Events) == 0 || len(in.Events) > store.IDPushMax {
			httpError(w, http.StatusBadRequest, "events: 1..200 ledger events")
			return
		}
		got, err := s.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: owner, EndpointID: ep.ID,
			Machine: shortNode(ep.Hostname), Login: ep.OSUser, ID: in.ID, Events: in.Events})
		if errors.Is(err, store.ErrIDDuplicate) {
			_ = s.Store.FleetAuditWorker("node:"+ep.ID, "", "", "id", "", "refused:DUPLICATE_ID", in.ID, time.Now())
			writeJSON(w, http.StatusConflict, map[string]any{"code": "DUPLICATE_ID", "id": in.ID,
				"error": "this full ID is already registered by another machine (a cloned machine?) — the window keeps running; open a new window for a new ID"})
			return
		}
		if err != nil {
			log.Printf("fleet ids %s: %v", in.ID, err)
			httpError(w, http.StatusInternalServerError, "could not store the events")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": in.ID, "seq": got.Seq, "short": got.Short})
	case ref == "" && r.Method == http.MethodGet:
		ids, err := s.Store.FleetIDsOf(owner, "")
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ids": ids})
	case ref != "" && r.Method == http.MethodGet:
		id := ref
		if !store.IsFleetID(id) {
			code := store.NormIDCode(ref)
			if code == "" {
				httpError(w, http.StatusBadRequest, "an ID or a short code T-<4+ base32>")
				return
			}
			hits, err := s.Store.FleetIDsOf(owner, code)
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			switch len(hits) {
			case 0:
				httpError(w, http.StatusNotFound, "no ID of this machine's owner answers to "+ref)
				return
			case 1:
				id = hits[0].ID
			default:
				writeJSON(w, http.StatusConflict, map[string]any{"code": "AMBIGUOUS", "candidates": hits,
					"error": ref + " is ambiguous — name it longer"})
				return
			}
		}
		rec, err := s.Store.FleetIDOf(owner, id)
		if errors.Is(err, sql.ErrNoRows) {
			httpError(w, http.StatusNotFound, "no ID "+id+" of this machine's owner")
			return
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, rec)
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "POST "+NodeIDsPath+", GET "+NodeIDsPath+"[/<ID|T-code>]")
	}
}
