package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The old T records onto IDs, and the switch (EPIC T497 C6; design page §5,
// §5.1; bin/fleet-id.sh migrate | switch). The rule is store.ClassifyIDMigration;
// this is the road a node's token takes to it:
//
//	POST /v1/node/ids/migrate {apply?, only?:["T351",…]} → {apply, counts, items}
//	                         every record not yet migrated (the operator's
//	                         machines: everyone's), settled by the §5 table. A
//	                         record that names a worker asks that worker's
//	                         machine ONCE, read-only, over its control link
//	                         (the `id_presence` read: every fleet's windows and
//	                         their @fleet_id); a machine that does not answer
//	                         keeps every one of its records where it is (wait).
//	                         Dry by default — apply writes each record's end and
//	                         its fleet_operations row (action id_migrate).
//	GET  /v1/node/ids/switch → {on}
//	POST /v1/node/ids/switch {on} → {on}: the operator's machines only; audited
//
// Nothing here forces an end: a record is closed only on the record's own word
// or its machine's.
const (
	nodeIDMigrateRef = "migrate"
	nodeIDSwitchRef  = "switch"
)

// idPresenceTimeout bounds one machine's answer: it lists every fleet's windows.
const idPresenceTimeout = 30 * time.Second

func (s *Server) nodeIDsAdmin(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owner, ref string) bool {
	switch ref {
	case nodeIDSwitchRef:
		s.nodeIDSwitch(w, r, ep, owner)
	case nodeIDMigrateRef:
		s.nodeIDMigrate(w, r, ep, owner)
	default:
		return false
	}
	return true
}

func (s *Server) nodeIDSwitch(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owner string) {
	switch r.Method {
	case http.MethodGet:
	case http.MethodPost:
		if owner != "operator" {
			httpError(w, http.StatusForbidden, "the ID switch is the operator's: run it from one of the operator's machines")
			return
		}
		var in struct {
			On *bool `json:"on"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&in); err != nil || in.On == nil {
			httpError(w, http.StatusBadRequest, `the body is {"on": true|false}`)
			return
		}
		now := time.Now()
		if err := s.Store.SetIDSwitch(*in.On, now); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		_ = s.Store.FleetAudit("node:"+ep.ID, "id_switch", "", map[bool]string{true: "on", false: "off"}[*in.On], "", now)
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST "+NodeIDsPath+"/"+nodeIDSwitchRef)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"on": s.Store.IDSwitchOn()})
}

func (s *Server) nodeIDMigrate(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owner string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST "+NodeIDsPath+"/"+nodeIDMigrateRef)
		return
	}
	var in struct {
		Apply bool     `json:"apply"`
		Only  []string `json:"only"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "the body is one JSON object {apply?, only?}")
		return
	}
	for _, ref := range in.Only {
		if store.ParseTaskRef(ref) == 0 {
			httpError(w, http.StatusBadRequest, "only: task numbers T<n> ("+ref+")")
			return
		}
	}
	scope := owner
	if owner == "operator" {
		scope = ""
	}
	tasks, err := s.Store.IDMigrateCandidates(scope, in.Only)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	pres := s.idPresence(r.Context(), tasks)
	now := time.Now()
	operator := "node:" + ep.ID + " " + shortNode(ep.Hostname) + "/" + ep.OSUser
	counts := map[string]int{}
	items := make([]store.IDMigrateItem, 0, len(tasks))
	for _, t := range tasks {
		fleet, _ := store.IDMigWorker(t)
		it := store.ClassifyIDMigration(t, pres[fleet])
		if in.Apply && it.Verdict != store.IDMigWait {
			switch err := s.Store.ApplyIDMigration(t, it, operator, now); {
			case err == nil:
				it.Applied = true
			case errors.Is(err, store.ErrTaskConflict):
				it.Evidence += "（已被另一次迁移收过）"
			default:
				httpError(w, http.StatusInternalServerError, t.Ref+": "+err.Error())
				return
			}
		}
		counts[it.Verdict]++
		items = append(items, it)
	}
	writeJSON(w, http.StatusOK, map[string]any{"apply": in.Apply, "switch": s.Store.IDSwitchOn(), "counts": counts, "items": items})
}

// idPresence asks each machine that holds a worker of tasks, once and in
// parallel, which windows it has; the answer per fleet UUID. A fleet the hub
// does not know, or whose machine does not answer, maps to an unanswered
// presence — never to «no window».
func (s *Server) idPresence(ctx context.Context, tasks []store.FleetTask) map[string]*store.IDPresence {
	out := map[string]*store.IDPresence{}
	byEP := map[string][]store.FleetRow{}
	for _, t := range tasks {
		fleet, _ := store.IDMigWorker(t)
		if fleet == "" || out[fleet] != nil {
			continue
		}
		row, err := s.Store.Fleet(fleet)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			out[fleet] = &store.IDPresence{Evidence: "hub 不认识这个 fleet（" + fleet + "）"}
			continue
		case err != nil:
			out[fleet] = &store.IDPresence{Evidence: "hub 读不出这个 fleet：" + err.Error()}
			continue
		}
		out[fleet] = &store.IDPresence{Evidence: "还没问"}
		byEP[row.EndpointID] = append(byEP[row.EndpointID], row)
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for epID, rows := range byEP {
		wg.Add(1)
		go func(epID string, rows []store.FleetRow) {
			defer wg.Done()
			got := s.askIDPresence(ctx, epID, rows)
			mu.Lock()
			for f, p := range got {
				out[f] = p
			}
			mu.Unlock()
		}(epID, rows)
	}
	wg.Wait()
	return out
}

// idPresenceAnswer is fleet_control.py's `id_presence`.
type idPresenceAnswer struct {
	ObservedAt any `json:"observed_at"`
	Fleets     []struct {
		FleetID    string `json:"fleet_id"`
		Name       string `json:"name"`
		State      string `json:"state"`
		Error      string `json:"error"`
		ObservedAt any    `json:"observed_at"`
		Windows    []struct {
			Identity string `json:"identity"`
			Key      string `json:"key"`
			Window   string `json:"window_id"`
		} `json:"windows"`
	} `json:"fleets"`
}

func (s *Server) askIDPresence(ctx context.Context, epID string, rows []store.FleetRow) map[string]*store.IDPresence {
	out := map[string]*store.IDPresence{}
	host := rows[0].Hostname + "/" + rows[0].OSUser
	silent := func(why string) map[string]*store.IDPresence {
		for _, r := range rows {
			out[r.FleetID] = &store.IDPresence{Evidence: host + " " + why}
		}
		return out
	}
	ctx, cancel := context.WithTimeout(ctx, idPresenceTimeout)
	defer cancel()
	raw, _, err := s.NodeRead(ctx, epID, "id_presence", map[string]any{})
	if err != nil {
		return silent("没有回答（" + err.Error() + "）")
	}
	var ans idPresenceAnswer
	if json.Unmarshal(raw, &ans) != nil {
		return silent("的回答读不懂")
	}
	for _, r := range rows {
		p := &store.IDPresence{Answered: true, Gone: true,
			Evidence: fmt.Sprintf("%s 回答：这台机器已不运行 fleet %s（它有 %d 个 fleet，%v）", host, r.FleetID, len(ans.Fleets), ans.ObservedAt)}
		for _, f := range ans.Fleets {
			if f.FleetID != r.FleetID {
				continue
			}
			switch {
			case f.Error != "":
				p = &store.IDPresence{Evidence: host + " 读不出 fleet " + f.Name + " 的窗口：" + f.Error}
			case f.State != "running":
				p = &store.IDPresence{Evidence: host + " 的 fleet " + f.Name + " tmux 不在（" + f.State + "）——不当成证据"}
			default:
				wins := map[string]string{}
				for _, w := range f.Windows {
					where := f.Name + ":" + w.Window
					if w.Identity != "" {
						wins[w.Identity] = where
					}
					if w.Key != "" {
						wins[w.Key] = where
					}
				}
				p = &store.IDPresence{Answered: true, Windows: wins,
					Evidence: fmt.Sprintf("%s · fleet %s tmux 正常 · %d 个窗口 · %v", host, f.Name, len(f.Windows), f.ObservedAt)}
			}
		}
		out[r.FleetID] = p
	}
	return out
}
