package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
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
//	GET  /v1/node/ids?parent=<ID>[&id=<ID>…] → {parent, ids:[record…]}: the IDs it
//	                         spawned, the given ones (its members), and every ID
//	                         that continued one of them down `prev` — an EPIC
//	                         driver's members and their redos (C5)
//	GET  /v1/node/ids?since=<cursor> → {ids:[record…], cursor, more}: the owner's
//	                         records changed after the cursor ("" = all), a page
//	                         at a time — the node's ID cache (EPIC T644 C7,
//	                         bin/fleet-id.sh pull), so every home's panel reads
//	                         the same records
//	GET  /v1/node/ids/<ID|T-code> → the record; a code two IDs share is 409
//	                         {code: AMBIGUOUS, candidates} — never a pick
//
//	POST /v1/node/ids/live   {ids:[…], dry} → {closed, reopened, kept, live, open}:
//	                         the IDs this node's windows carry now (task BCYB,
//	                         store.ReconcileFleetIDs): the hub closes this
//	                         endpoint's open IDs it leaves out (quiet past
//	                         IDLiveGrace) and the reserved IDs of ended tasks,
//	                         reopens one of its own closes the list names again;
//	                         `open` is the owner's open IDs per machine after it
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
	if s.nodeIDsAdmin(w, r, ep, owner, ref) { // migrate · switch (EPIC T497 C6)
		return
	}
	switch {
	case ref == "capabilities" && r.Method == http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{"named": true})
	case ref == "live" && r.Method == http.MethodPost:
		s.nodeIDsLive(w, r, ep, owner)
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
	case ref == "" && r.Method == http.MethodGet && r.URL.Query().Has("parent"):
		parent := r.URL.Query().Get("parent")
		if !store.IsFleetID(parent) {
			httpError(w, http.StatusBadRequest, "parent must be a full ID (a window's @fleet_id)")
			return
		}
		seeds := r.URL.Query()["id"]
		if len(seeds) > store.IDFamilyMax {
			seeds = seeds[:store.IDFamilyMax]
		}
		fam, err := s.Store.FleetIDFamily(owner, parent, seeds)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		line, err := s.Store.FleetIDLineage(owner, parent)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"parent": parent, "lineage": line, "ids": fam})
	case ref == "" && r.Method == http.MethodGet && r.URL.Query().Has("since"):
		recs, cursor, more, err := s.Store.FleetIDsSince(owner, r.URL.Query().Get("since"), store.IDSyncMax)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ids": recs, "cursor": cursor, "more": more})
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
			if lc := store.LegacyIDCode(ref); code == "" && lc != "" {
				code = "T-" + lc // the old `T-…` (compat-1v: 下一批删): FleetIDsOf reads it as such
			}
			if code == "" {
				httpError(w, http.StatusBadRequest, "an ID or a short code (K3F9: Crockford base32, letter first, 4+)")
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

type nodeIDLive struct {
	IDs []string `json:"ids"`
	Dry bool     `json:"dry"`
}

// nodeIDsLive is POST /v1/node/ids/live (task BCYB): one node's live IDs.
func (s *Server) nodeIDsLive(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owner string) {
	var in nodeIDLive
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in); err != nil || in.IDs == nil {
		httpError(w, http.StatusBadRequest, "the body is one JSON object {ids:[…], dry}")
		return
	}
	if len(in.IDs) > store.IDLiveMax {
		httpError(w, http.StatusBadRequest, "ids: at most 2000")
		return
	}
	got, err := s.Store.ReconcileFleetIDs(owner, ep.ID, in.IDs, time.Now(), store.IDLiveGrace, !in.Dry)
	if err != nil {
		log.Printf("fleet ids live %s: %v", ep.ID, err)
		httpError(w, http.StatusInternalServerError, "could not reconcile the IDs")
		return
	}
	open, err := s.Store.FleetIDOpenCount(owner)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !in.Dry && len(got.Closed)+len(got.Reopened) > 0 {
		_ = s.Store.FleetAuditWorker("node:"+ep.ID, "", "", "id", "", "reconcile",
			fmt.Sprintf("closed %d · reopened %d", len(got.Closed), len(got.Reopened)), time.Now())
	}
	writeJSON(w, http.StatusOK, map[string]any{"closed": got.Closed, "reopened": got.Reopened, "kept": got.Kept,
		"live": got.Live, "open": open, "dry": in.Dry})
}
