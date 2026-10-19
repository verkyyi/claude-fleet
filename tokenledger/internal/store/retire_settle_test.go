package store

import (
	"strings"
	"testing"
	"time"
)

// claude-fleet#4831: retiring an endpoint settles what only it could have
// closed — its open local starts end retired, its legacy leases go, one audit
// row says so — and a repo started on another endpoint stays byte for byte.
func TestRetireSettlesLocalStarts(t *testing.T) {
	s := taskStore(t)
	now := time.Date(2026, 10, 19, 0, 0, 0, 0, time.UTC)
	for _, ep := range []string{"gone", "other", "old"} {
		if err := s.Enroll(ep, ep, "hash-"+ep); err != nil {
			t.Fatal(err)
		}
	}
	start := func(repo, ep, key string, begin bool) {
		t.Helper()
		if _, err := s.RepoLocalStart(repo, "alice", ep, key, "reserve", "", nil, now); err != nil {
			t.Fatal(key, err)
		}
		if begin {
			if _, err := s.RepoLocalStart(repo, "alice", ep, key, "begin", "f/"+key, nil, now); err != nil {
				t.Fatal(key, err)
			}
		}
	}
	start("org/repo", "gone", "r1", false)
	start("org/repo", "gone", "r2", true)
	start("org/other", "gone", "r3", true)
	start("org/repo", "other", "keep", true)
	start("org/untouched", "other", "u1", true)
	if g, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/repo", Issue: 7, WorkerID: "f/w", FleetID: "f", EndpointID: "gone"}, 5*time.Minute, now); err != nil || !g {
		t.Fatal("lease", g, err)
	}
	opsOf := func(ep string) string {
		t.Helper()
		rows, err := s.read.Query(`SELECT id, status, updated, result FROM fleet_operations WHERE actor = ? ORDER BY id`, "repo-start:"+ep)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var b strings.Builder
		for rows.Next() {
			var id, st, up, res string
			if err := rows.Scan(&id, &st, &up, &res); err != nil {
				t.Fatal(err)
			}
			b.WriteString(id + st + up + res + "\n")
		}
		return b.String()
	}
	before := opsOf("other")
	beforeBlockers, _, err := s.RepoAuthorityBlockers("org/untouched", false)
	if err != nil {
		t.Fatal(err)
	}

	res, err := s.RetireEndpointAs("gone", "operator", "machine gone", now.Add(time.Minute))
	if err != nil || !res.Retired {
		t.Fatal(res, err)
	}
	if res.Settled.Starts != 3 || len(res.Settled.Leases) != 1 || strings.Join(res.Settled.Repos, ",") != "org/other,org/repo" {
		t.Fatalf("settled %+v", res.Settled)
	}
	for _, k := range []string{"r1", "r2"} {
		st, err := s.ReadRepoLocalStart("org/repo", "alice", "gone", k)
		if err != nil || st.Phase != "retired" {
			t.Fatal(k, st, err)
		}
	}
	blockers, _, err := s.RepoAuthorityBlockers("org/repo", false)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(blockers, "\n")
	if strings.Contains(joined, "r1") || strings.Contains(joined, "r2") || strings.Contains(joined, "f/w") ||
		!strings.Contains(joined, "local start retained: keep") {
		t.Fatal("blockers", blockers)
	}
	if after := opsOf("other"); after != before {
		t.Fatalf("another endpoint's starts changed:\n%s\n%s", before, after)
	}
	afterBlockers, _, _ := s.RepoAuthorityBlockers("org/untouched", false)
	if strings.Join(afterBlockers, "\n") != strings.Join(beforeBlockers, "\n") {
		t.Fatal("untouched repo's blockers changed", beforeBlockers, afterBlockers)
	}
	if _, err := s.RepoLocalStart("org/repo", "alice", "gone", "r1", "begin", "f/r1", nil, now); err == nil {
		t.Fatal("a retired start began")
	}
	var n int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'node_retire_settle' AND fleet_id = 'endpoint:gone' AND outcome LIKE 'SETTLED starts=3 leases=1 repos=org/other,org/repo%'`).Scan(&n); err != nil || n != 1 {
		t.Fatal("audit", n, err)
	}

	// A second retire finds nothing open: no change, no audit row.
	res, err = s.RetireEndpointAs("gone", "operator", "", now.Add(2*time.Minute))
	if err != nil || res.Retired || res.Settled.Starts != 0 || len(res.Settled.Leases) != 0 {
		t.Fatal(res, err)
	}
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'node_retire_settle'`).Scan(&n); err != nil || n != 1 {
		t.Fatal("second retire audited", n, err)
	}

	// An endpoint an older hub retired without settling: re-running retire
	// settles it.
	start("org/repo", "old", "o1", true)
	if _, err := s.write.Exec(`UPDATE endpoints SET retired_at = ? WHERE endpoint_id = 'old'`, fmtTime(now)); err != nil {
		t.Fatal(err)
	}
	res, err = s.RetireEndpointAs("old", "cli", "", now.Add(3*time.Minute))
	if err != nil || res.Retired || res.Settled.Starts != 1 {
		t.Fatal(res, err)
	}

	// A merely offline endpoint keeps its start blocking.
	blockers, _, _ = s.RepoAuthorityBlockers("org/repo", false)
	if !strings.Contains(strings.Join(blockers, "\n"), "local start retained: keep") {
		t.Fatal("an unretired endpoint's start was drained", blockers)
	}
}
