package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The same node authentication and account scope as task reads. No GitHub
// adapter, inventory inference, or new transport participates in these calls.
func (s *Server) nodeTaskCollaboration(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owner, ref string) bool {
	task, action, found := strings.Cut(ref, "/")
	if !found {
		return false
	}
	t, err := s.nodeOwnTask(owner, task)
	if err != nil {
		httpError(w, 404, "no such task")
		return true
	}
	switch action {
	case "children":
		if r.Method != http.MethodGet {
			httpError(w, 405, "GET only")
			return true
		}
		if t.AuthorityVersion != 1 {
			httpError(w, 409, "legacy task has no authoritative children")
			return true
		}
		rows, err := s.Store.FleetTaskChildren(owner, t.Ref, t.ExecutionOwner, t.Generation)
		if err != nil {
			taskWriteError(w, err)
			return true
		}
		writeJSON(w, 200, map[string]any{"parent": t.Ref, "parent_session": t.ExecutionOwner, "parent_generation": t.Generation, "children": rows})
	case "reports":
		if r.Method == http.MethodGet {
			report, err := s.Store.PendingTaskReport(t)
			if err != nil {
				taskWriteError(w, err)
				return true
			}
			writeJSON(w, 200, map[string]any{"report": report})
			return true
		}
		if r.Method != http.MethodPost {
			httpError(w, 405, "POST only")
			return true
		}
		var report store.TaskReport
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&report) != nil || report.Task != t.Ref || !nodeTaskTokenRE.MatchString(report.EventID) || len(report.Evidence) > 8000 || len(report.Summary) > 2000 {
			httpError(w, 400, "invalid task report")
			return true
		}
		receipt, err := s.Store.RecordFleetTaskReport(owner, ep.ID, report, time.Now())
		if err != nil {
			taskWriteError(w, err)
			return true
		}
		writeJSON(w, 200, receipt)
	default:
		httpError(w, 404, "unknown task action")
	}
	return true
}

// Commit before the relay acknowledgement. A lost ack replays the same journal
// event, and a late generation remains historical without reaching a new owner.
func (s *Server) prepareTaskReportRelay(ep store.Endpoint, r *store.FleetRelay) (bool, error) {
	if r.Kind != control.RelayChildReport {
		return false, nil
	}
	var payload struct {
		Report *store.TaskReport `json:"task_report"`
	}
	if json.Unmarshal([]byte(r.Payload), &payload) != nil {
		return false, fault("INVALID_ARGUMENT", "invalid task report")
	}
	if payload.Report == nil {
		return false, nil
	} // pinned legacy relay
	report := *payload.Report
	_, session, err := fleetid.ParseWorkerID(r.FromWID)
	if err != nil || !fleetid.IsUUID(session) || report.WorkerID != r.FromWID || report.ParentSession != r.ToWID || !nodeTaskTokenRE.MatchString(report.EventID) {
		return false, fault("INVALID_ARGUMENT", "task report identity does not match relay")
	}
	receipt, err := s.Store.RecordFleetTaskReport(s.nodeTaskOwner(&ep), ep.ID, report, time.Now())
	if err != nil {
		return false, err
	}
	if receipt.Disposition != "committed" && receipt.Disposition != "progress" {
		return true, nil
	}
	deliver, err := s.Store.TaskReportDeliverable(report)
	return !deliver, err
}

func (s *Server) taskRelayStillCurrent(r store.FleetRelay) (bool, error) {
	if r.Kind != control.RelayChildReport {
		return true, nil
	}
	var payload struct {
		Report *store.TaskReport `json:"task_report"`
	}
	if json.Unmarshal([]byte(r.Payload), &payload) != nil {
		return false, nil
	}
	if payload.Report == nil {
		return true, nil
	}
	return s.Store.TaskReportDeliverable(*payload.Report)
}
