package store

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
	"time"
)

func TestRepoStartRecoveryReadAndReplay(t *testing.T) {
	s := taskStore(t)
	now := time.Date(2026, 10, 16, 0, 0, 0, 0, time.UTC)
	proof := &RepoNativeIdentity{WorkerID: "fleet/worker", NativeSession: "original", PID: 123, Birth: "birth", Executable: "/bin/codex"}
	run := func(action string) RepoLocalStart {
		t.Helper()
		r, err := s.RepoLocalStart("org/repo", "alice", "node", "original", action, proof.WorkerID, proof, now)
		if err != nil {
			t.Fatal(action, err)
		}
		return r
	}
	for _, action := range []string{"reserve", "begin"} {
		run(action)
	}
	before, err := s.ReadRepoLocalStart("org/repo", "alice", "node", "original")
	if err != nil || before.Phase != "starting" || before.Native != nil {
		t.Fatal("read changed the missing observation", before, err)
	}
	for _, scope := range [][4]string{{"other/repo", "alice", "node", "original"}, {"org/repo", "bob", "node", "original"}, {"org/repo", "alice", "other", "original"}, {"org/repo", "alice", "node", "missing"}} {
		if _, err = s.ReadRepoLocalStart(scope[0], scope[1], scope[2], scope[3]); err == nil {
			t.Fatal("foreign/missing lookup succeeded", scope)
		}
	}
	id := repoStartID("org/repo", "alice", "node", "original")
	var updated string
	if err = s.read.QueryRow(`SELECT updated FROM fleet_operations WHERE id = ?`, id).Scan(&updated); err != nil || updated != now.Format(rfc) {
		t.Fatal("preflight wrote the journal", updated, err)
	}
	ack := run("recover-observe") // Lose this HTTP acknowledgement.
	now = now.Add(time.Hour)
	again := run("recover-observe")
	if !reflect.DeepEqual(ack, again) {
		t.Fatal("lost ack retry changed proof", ack, again)
	}
	var raw, after string
	if err = s.read.QueryRow(`SELECT result,updated FROM fleet_operations WHERE id = ?`, id).Scan(&raw, &after); err != nil || after != updated {
		t.Fatal("exact replay had a journal side effect", after, err)
	}
	var saved RepoLocalStart
	if json.Unmarshal([]byte(raw), &saved) != nil || !reflect.DeepEqual(saved, ack) {
		t.Fatal("different native was persisted", saved)
	}
	for _, field := range []string{"worker", "sid", "pid", "birth", "executable"} {
		bad := *proof
		switch field {
		case "worker":
			bad.WorkerID = "foreign"
		case "sid":
			bad.NativeSession = "another"
		case "pid":
			bad.PID++
		case "birth":
			bad.Birth = "reused"
		case "executable":
			bad.Executable = "/other/codex"
		}
		if _, err = s.RepoLocalStart("org/repo", "alice", "node", "original", "recover-observe", proof.WorkerID, &bad, now); err == nil {
			t.Fatal("changed identity accepted", field)
		}
	}
	run("stopped")
	if _, err = s.RepoLocalStart("org/repo", "alice", "node", "original", "recover-observe", proof.WorkerID, proof, now); err == nil {
		t.Fatal("stopped execution resurrected")
	}
}

func TestRepoStartRecoveryRejectsSuccessor(t *testing.T) {
	for _, stopped := range []bool{false, true} {
		t.Run(fmt.Sprint(stopped), func(t *testing.T) {
			s := taskStore(t)
			now := time.Now().UTC()
			proof := &RepoNativeIdentity{WorkerID: "f/w", NativeSession: "old", PID: 10, Birth: "old", Executable: "/bin/codex"}
			for _, key := range []string{"old", "successor"} {
				for _, action := range []string{"reserve", "begin"} {
					if _, err := s.RepoLocalStart("org/repo", "alice", "node", key, action, proof.WorkerID, proof, now); err != nil {
						t.Fatal(err)
					}
				}
				now = now.Add(time.Second)
			}
			if stopped {
				for _, action := range []string{"observe", "stopped"} {
					if _, err := s.RepoLocalStart("org/repo", "alice", "node", "successor", action, proof.WorkerID, proof, now); err != nil {
						t.Fatal(err)
					}
				}
			}
			if _, err := s.ReadRepoLocalStart("org/repo", "alice", "node", "old"); err == nil {
				t.Fatal("preflight accepted a predecessor")
			}
			if _, err := s.RepoLocalStart("org/repo", "alice", "node", "old", "recover-observe", proof.WorkerID, proof, now); err == nil {
				t.Fatal("recovery accepted a predecessor")
			}
		})
	}
}

func TestRepoStartRecoveryAmbiguousLegacyOrder(t *testing.T) {
	s := taskStore(t)
	now := time.Now().UTC()
	p := &RepoNativeIdentity{WorkerID: "f/w", NativeSession: "native", PID: 10, Birth: "b", Executable: "/bin/codex"}
	run := func(key, action string) {
		t.Helper()
		if _, err := s.RepoLocalStart("org/repo", "alice", "node", key, action, p.WorkerID, p, now); err != nil {
			t.Fatal(err)
		}
		now = now.Add(time.Second)
	}
	run("reserved-first", "reserve")
	run("started-first", "reserve")
	run("started-first", "begin")
	run("reserved-first", "begin")
	run("reserved-first", "observe")
	run("reserved-first", "stopped")
	if _, err := s.ReadRepoLocalStart("org/repo", "alice", "node", "started-first"); err == nil {
		t.Fatal("reservation timestamp is not execution order")
	}
}
