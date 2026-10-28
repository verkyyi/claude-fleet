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
	id, _ := args["id"].(string)
	archived, ok := args["archived"].(bool)
	if !store.IsFleetID(id) || !ok {
		return nil, fault("INVALID_ARGUMENT", "id and archived boolean are required")
	}
	for key := range args {
		if key != "id" && key != "archived" && key != "idempotency_key" {
			return nil, fault("INVALID_ARGUMENT", "unexpected archive argument")
		}
	}
	// Even an administrator's archive preference only changes their own sessions.
	err = s.Store.SetSessionArchived(p.Actor, id, archived)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fault("NOT_FOUND", "session not found")
	}
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "succeeded", "id": id, "archived": archived}, nil
}
