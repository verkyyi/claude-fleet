package store

import (
	"path/filepath"
	"testing"
	"time"
)

func TestPreviewEnrollmentBinding(t *testing.T) {
	for _, change := range []string{"unbind-rebind", "generation", "token", "role", "retire", "login", "host", "owner"} {
		t.Run(change, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "preview.db")
			s, err := Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			p := previewFixture(t, s)
			// The actual legacy shape: a later managed endpoint, but the redeemed
			// rejoin code has no account-operation machine/role binding.
			if _, err = s.write.Exec(`UPDATE fleet_join_codes SET machine='',role='',label='node-alice-rejoin' WHERE endpoint_id=?`, p.Endpoint); err != nil {
				t.Fatal(err)
			}
			if _, err = s.PreviewAuthority(p.Endpoint); err == nil {
				t.Fatal("unbound historical enrollment accepted")
			}
			now := time.Now()
			for _, wrong := range [][4]string{{"gh:other", p.Machine, p.Login, p.Endpoint}, {p.Owner, "other", p.Login, p.Endpoint}, {p.Owner, p.Machine, "root", p.Endpoint}, {p.Owner, p.Machine, p.Login, "other"}} {
				if err = s.BindPreviewEnrollment(wrong[0], wrong[1], wrong[2], wrong[3], "admin", true, now); err == nil {
					t.Fatal("wrong binding accepted", wrong)
				}
			}
			if err = s.BindPreviewEnrollment(p.Owner, p.Machine, p.Login, p.Endpoint, "admin", true, now); err != nil {
				t.Fatal(err)
			}
			authority, err := s.PreviewAuthority(p.Endpoint)
			if err != nil {
				t.Fatal(err)
			}
			p.Generation = authority.Generation
			if err = s.CreatePreview(p, 3, now); err != nil {
				t.Fatal(err)
			}
			peer, err := Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer peer.Close()
			if _, err = peer.Preview(p.ID, now); err != nil {
				t.Fatal("peer did not see binding", err)
			}
			switch change {
			case "unbind-rebind":
				err = s.BindPreviewEnrollment(p.Owner, p.Machine, p.Login, p.Endpoint, "admin", false, now)
				if err != nil {
					t.Fatal(err)
				}
				if _, err = peer.Preview(p.ID, now); err == nil {
					t.Fatal("unbind not visible on replica")
				}
				err = s.BindPreviewEnrollment(p.Owner, p.Machine, p.Login, p.Endpoint, "admin", true, now)
			case "generation":
				principal, _ := s.Principal(p.Owner)
				err = s.AdoptAccount(principal, p.Machine, now.Add(time.Second))
			case "token":
				err = s.RotateEndpointToken(p.Endpoint, "new-token", now, 0)
			case "role":
				err = s.SetEndpointRole(p.Endpoint, NodeRoleClient)
			case "retire":
				_, err = s.write.Exec(`UPDATE endpoints SET retired_at=? WHERE endpoint_id=?`, now.Format(rfc), p.Endpoint)
			case "login":
				_, err = s.write.Exec(`UPDATE endpoints SET os_user='root' WHERE endpoint_id=?`, p.Endpoint)
			case "host":
				_, err = s.write.Exec(`UPDATE endpoints SET enrolled_host='other' WHERE endpoint_id=?`, p.Endpoint)
			case "owner":
				_, err = s.write.Exec(`UPDATE fleet_accounts SET state='removed' WHERE principal_id=?`, p.Owner)
			}
			if err != nil {
				t.Fatal(err)
			}
			if _, err = peer.Preview(p.ID, now); err == nil {
				t.Fatal("revoked permission survived", change)
			}
			if change == "unbind-rebind" {
				// A registration racing the revocation cannot use its stale grant
				// even after a new approval of the same endpoint/account.
				p.ID = "raced-registration"
				if err = s.CreatePreview(p, 3, now); err == nil {
					t.Fatal("old approval revived after rebind")
				}
			}
			var n int
			if err = s.write.QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action='preview_bind' AND actor='admin'`).Scan(&n); err != nil || n < 1 {
				t.Fatal("missing audit", n, err)
			}
		})
	}
}

func previewSessionTask(t *testing.T, s *Store, p Preview) (Preview, FleetTask) {
	t.Helper()
	now := time.Now()
	task, err := s.CreateFleetTask(FleetTask{Owner: p.Owner, Title: "Local Task", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "real-task", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.RecordFleetSnapshot(p.Endpoint, p.Machine, p.Login, "preview-machine", []FleetReport{{FleetID: executionFleet, Name: "preview", State: "up"}}, now); err != nil {
		t.Fatal(err)
	}
	_, err = s.ApplyFleetIDEvents(FleetIDPush{Owner: p.Owner, EndpointID: p.Endpoint, Machine: p.Machine, Login: p.Login, ID: task.FID, Events: []map[string]any{
		{"id": task.FID, "ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "task": task.Ref, "agent": "codex", "key": "scratch-978"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	p.TaskID, p.Worker = task.ID, executionFleet+"/"+task.FID
	return p, task
}

func TestPreviewTaskBinding(t *testing.T) {
	for _, change := range []string{"owner", "session", "endpoint", "fleet", "login", "closed", "generation", "cancel", "attempt", "task-fid"} {
		t.Run("session/"+change, func(t *testing.T) {
			s := taskStore(t)
			p, task := previewSessionTask(t, s, previewFixture(t, s))
			now := time.Now()
			if err := s.CreatePreview(p, 3, now); err != nil {
				t.Fatal(err)
			}
			var err error
			switch change {
			case "owner":
				_, err = s.write.Exec(`UPDATE fleet_tasks SET owner='other' WHERE id=?`, task.ID)
			case "session":
				_, err = s.write.Exec(`UPDATE fleet_ids SET owner='other' WHERE id=?`, task.FID)
			case "endpoint":
				_, err = s.write.Exec(`UPDATE fleet_ids SET endpoint_id='other' WHERE id=?`, task.FID)
			case "fleet":
				_, err = s.write.Exec(`UPDATE fleet_machines SET endpoint_id='other' WHERE machine_id='preview-machine'`)
			case "login":
				_, err = s.write.Exec(`UPDATE fleet_ids SET login='root' WHERE id=?`, task.FID)
			case "closed":
				_, err = s.write.Exec(`UPDATE fleet_ids SET closed_at=1 WHERE id=?`, task.FID)
			case "generation":
				_, err = s.write.Exec(`UPDATE fleet_tasks SET generation=generation+1 WHERE id=?`, task.ID)
			case "cancel":
				_, err = s.write.Exec(`UPDATE fleet_tasks SET cancel_request='stop' WHERE id=?`, task.ID)
			case "attempt":
				_, err = s.write.Exec(`UPDATE fleet_tasks SET attempt_id='other' WHERE id=?`, task.ID)
			case "task-fid":
				_, err = s.write.Exec(`UPDATE fleet_tasks SET fid='other' WHERE id=?`, task.ID)
			}
			if err != nil {
				t.Fatal(err)
			}
			if _, err = s.Preview(p.ID, now); err == nil {
				t.Fatal("changed task binding accepted", change)
			}
		})
	}
	t.Run("execution", func(t *testing.T) {
		s := taskStore(t)
		p := previewFixture(t, s)
		now := time.Now()
		task, err := s.CreateFleetTask(FleetTask{Owner: p.Owner, Title: "Controlled Task", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "execution-preview", now)
		if err != nil {
			t.Fatal(err)
		}
		o := executionOp(task, "execution-preview-start")
		if _, err = s.AuthorizeTaskExecution(o, p.Endpoint); err != nil {
			t.Fatal(err)
		}
		p.TaskID, p.Worker = task.ID, executionWorker
		if err = s.CreatePreview(p, 3, now); err == nil {
			t.Fatal("reservation without session accepted")
		}
		if _, err = s.ClaimTaskExecution(task.ID, p.Owner, o.ID, p.Endpoint, p.Worker, task.Generation, task.AttemptID); err != nil {
			t.Fatal(err)
		}
		if err = s.CreatePreview(p, 3, now); err != nil {
			t.Fatal(err)
		}
		if _, _, err = s.RequestTaskStop(task.ID, p.Owner, "preview-stop", "explicit stop", now); err != nil {
			t.Fatal(err)
		}
		if _, err = s.Preview(p.ID, now); err == nil {
			t.Fatal("stopped execution retained preview")
		}
	})
}
