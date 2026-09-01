package api

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

// maxIngestBody caps a single push. A first scan on a busy machine can carry
// tens of thousands of events; beyond this the agent should batch.
const maxIngestBody = 32 << 20

// handleIngest accepts a batch from an enrolled endpoint.
//
// Authentication is the endpoint's own enrollment token, and the endpoint id
// comes from THAT lookup — never from the request body. An agent cannot claim
// to be another endpoint by saying so.
func (s *Server) handleIngest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}

	tok := bearer(r)
	if tok == "" {
		httpError(w, http.StatusUnauthorized, "missing bearer token")
		return
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		// Deliberately vague: distinguishing "unknown token" from "known token,
		// other failure" tells a prober which guesses were close.
		httpError(w, http.StatusUnauthorized, "unrecognised enrollment token")
		return
	}

	var batch model.Batch
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxIngestBody))
	if err := dec.Decode(&batch); err != nil {
		httpError(w, http.StatusBadRequest, "malformed batch: "+err.Error())
		return
	}
	if batch.Identity.AccountUUID == "" {
		httpError(w, http.StatusBadRequest, "batch has no identity.account_uuid")
		return
	}

	resp, err := s.ingest(ep, &batch)
	if err != nil {
		log.Printf("ingest from %s: %v", ep.ID, err)
		httpError(w, http.StatusInternalServerError, "could not store batch")
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) ingest(ep *store.Endpoint, batch *model.Batch) (*model.IngestResponse, error) {
	id := batch.Identity

	// A fingerprint is a guess at identity made from a reset schedule. When a
	// known account's schedule matches it, they are the same subscription — and
	// leaving them apart puts a phantom next to the real account, each holding
	// a slice of the usage. Resolve BEFORE anything is written under the key.
	if resolved, err := s.Store.ResolveFingerprint(id.AccountUUID); err != nil {
		return nil, err
	} else if resolved != id.AccountUUID {
		log.Printf("fingerprint %s is %s (same seven-day reset schedule)", id.AccountUUID, resolved)
		id.AccountUUID = resolved
		// The guessed identity's placeholder fields must not overwrite the real
		// account's; only the uuid was ever worth anything here.
		id.Email, id.DisplayName = "", ""
	}

	if err := s.Store.UpsertAccount(id, id.SubscriptionType, id.RateLimitTier); err != nil {
		return nil, err
	}

	// A scan emits one batch per subscription running on the machine, and
	// several run at once. Only the batch carrying the endpoint's own Claude
	// Code login may move endpoints.account_uuid; the rest are guests.
	//
	// An agent too old to say which is which sends no origin at all. Treat
	// that as a guest: under-recording a real logout is a gap, while trusting
	// it turns every scan cycle into a fabricated switch.
	login := batch.AccountOrigin == model.OriginLogin

	prev, prevWasLogin, err := s.Store.TouchEndpoint(ep.ID, id, batch.AgentVersion, login)
	if err != nil {
		return nil, err
	}
	// Every subscription seen on this endpoint is recorded, concurrently.
	// This is the honest answer to "what is this machine running".
	if err := s.Store.RecordEndpointAccount(ep.ID, id.AccountUUID, batch.AccountOrigin); err != nil {
		return nil, err
	}
	// A machine that logged out and into another account creates a seam:
	// everything already ingested keeps the old attribution. Record it so the
	// UI can show the seam rather than let history quietly misattribute.
	if login && prevWasLogin && prev != "" && prev != id.AccountUUID {
		if err := s.Store.RecordAccountSwitch(ep.ID, prev, id.AccountUUID); err != nil {
			return nil, err
		}
	}
	// Exactly one login at a time. Any other account still seen here is a
	// guest from now on — including the one that just stopped being the login.
	if login {
		if err := s.Store.DemoteEndpointLogin(ep.ID, id.AccountUUID); err != nil {
			return nil, err
		}
	}

	// Stamp identity server-side. The agent reports which account it belongs
	// to, but the endpoint id is whatever the token resolved to.
	//
	// os_user is stamped here rather than trusted per event: it is a property
	// of the reporting agent's process, and an event cannot claim to have been
	// spent under a login other than the one that read it.
	osUser := id.OSUser
	if osUser == "" {
		osUser = ep.OSUser
	}
	for i := range batch.Events {
		batch.Events[i].AccountUUID = id.AccountUUID
		batch.Events[i].EndpointID = ep.ID
		batch.Events[i].OSUser = osUser
	}
	// Price on the hub, not the agent: one pricing table for the whole fleet
	// means a rate correction applies everywhere at once instead of waiting
	// for every endpoint to be upgraded.
	s.Pricing.Apply(batch.Events)

	inserted, deduped, err := s.Store.InsertEvents(batch.Events)
	if inserted > 0 {
		// The headline total just changed. Recomputing here would put a table
		// scan on the ingest path; marking it stale lets the next snapshot pay
		// for it, once, however many endpoints just pushed.
		s.counter.Invalidate()
	}
	if err != nil {
		return nil, err
	}

	// Remember the endpoint's own explanation even when it could not read the
	// limits — it is the only thing that can tell an operator WHICH machine to
	// go fix.
	//
	// Only when this batch actually carries a limits verdict. A large scan is
	// split across many batches and the reading rides on the FIRST one; writing
	// unconditionally let the silent remainder overwrite the real reason with
	// an empty string, which is exactly what happened on a live two-machine
	// hub.
	if batch.Limits != nil || batch.LimitsUnavailable != "" {
		if err := s.Store.RecordLimitsUnavailable(ep.ID, batch.LimitsUnavailable); err != nil {
			return nil, err
		}
	}

	// Like the limits verdict, the attribution report rides on the first chunk
	// of a scan; later chunks must not reset it to zero.
	if batch.Attribution != nil {
		if err := s.Store.RecordAttribution(ep.ID, *batch.Attribution); err != nil {
			return nil, err
		}
	}

	if batch.Limits != nil {
		batch.Limits.AccountUUID = id.AccountUUID
		batch.Limits.EndpointID = ep.ID
		if batch.Limits.ObservedAt.IsZero() {
			batch.Limits.ObservedAt = time.Now().UTC()
		}
		// A reading that contradicts the one before it is not this
		// subscription's, whatever the agent believed when it read it. Storing
		// it would not merely be wrong on a dashboard: `ccquota budget` reads
		// exactly this, and another account's fresh window looks like headroom
		// that does not exist.
		prev, err := s.Store.LatestLimits(id.AccountUUID)
		if err != nil {
			return nil, err
		}
		if bad, why := store.ContradictsPrevious(prev, batch.Limits); bad {
			log.Printf("refusing a limits reading for %s from %s: %s",
				id.AccountUUID, ep.ID, why)
			if err := s.Store.RecordLimitsUnavailable(ep.ID, why); err != nil {
				return nil, err
			}
		} else if err := s.Store.InsertLimits(batch.Limits); err != nil {
			return nil, err
		}
	}

	return &model.IngestResponse{
		Accepted:            inserted,
		Deduped:             deduped,
		EndpointID:          ep.ID,
		LimitsPollIntervalS: s.LimitsPollIntervalS,
	}, nil
}

// Pricing is the hub's rate table type, aliased so the server struct reads
// clearly.
type Pricing = pricing.Table

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}

func httpError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
