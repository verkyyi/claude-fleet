package api

import (
	"database/sql"
	"errors"
	"net/http"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func (s *Server) archiveSession(r *http.Request, args map[string]any) (any, error) {
	if viewAsAsked(r) != "" {
		return nil, fault("FORBIDDEN", "leave view-as before archiving")
	}
	p, err := s.FleetPrincipal(r)
	if err != nil {
		return nil, err
	}
	if err = s.authorize(p, "worker:message", ""); err != nil {
		return nil, err
	}
	ids, ok := archiveIDs(args)
	archived, okB := args["archived"].(bool)
	if !ok || !okB {
		return nil, fault("INVALID_ARGUMENT", "id (or ids) and archived boolean are required")
	}
	for key := range args {
		if key != "id" && key != "ids" && key != "archived" && key != "idempotency_key" {
			return nil, fault("INVALID_ARGUMENT", "unexpected archive argument")
		}
	}
	// Even an administrator's archive preference only changes their own sessions.
	// A session and the sessions it opened go together: all or none.
	err = s.Store.SetSessionsArchived(p.Actor, ids, archived)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fault("NOT_FOUND", "session not found")
	}
	if err != nil {
		return nil, err
	}
	out := map[string]any{"status": "succeeded", "id": ids[0], "archived": archived}
	if _, many := args["ids"]; many {
		out["ids"] = ids
	}
	return out, nil
}

// maxArchiveIDs bounds one archive call (a session tree, never a whole list).
const maxArchiveIDs = 200

// archiveIDs reads `id` (one session) or `ids` (a session and the ones it
// opened), never both; every one a fleet ID, no repeats.
func archiveIDs(args map[string]any) ([]string, bool) {
	one, hasOne := args["id"]
	many, hasMany := args["ids"]
	if hasOne == hasMany {
		return nil, false
	}
	if hasOne {
		id, _ := one.(string)
		return []string{id}, store.IsFleetID(id)
	}
	list, _ := many.([]any)
	if len(list) == 0 || len(list) > maxArchiveIDs {
		return nil, false
	}
	seen := map[string]bool{}
	ids := make([]string, 0, len(list))
	for _, v := range list {
		id, _ := v.(string)
		if !store.IsFleetID(id) || seen[id] {
			return nil, false
		}
		seen[id] = true
		ids = append(ids, id)
	}
	return ids, true
}
