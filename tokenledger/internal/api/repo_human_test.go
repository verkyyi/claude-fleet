package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func humanStep(fragment, ord int, owner, kind, id string, fragmentAgeDays int) model.RepoHumanStep {
	return model.RepoHumanStep{
		Fragment: fragment, Ord: ord, Owner: owner, OwnerKind: kind, OwnerID: id,
		Title:      "建 Secret new-deploy/repo-progress-ship",
		FragmentAt: time.Now().UTC().AddDate(0, 0, -fragmentAgeDays),
	}
}

type humanDebtResp struct {
	Repo  string                   `json:"repo"`
	Since string                   `json:"since"`
	Until string                   `json:"until"`
	Steps []store.RepoHumanStepRow `json:"steps"`
	Days  []model.RepoHumanDay     `json:"days"`
}

func TestRepoHumanDebt_ServesOwedStepsAndTheRatio(t *testing.T) {
	h := newHarness(t)
	done := humanStep(5157, 2, "发起人", model.RepoOwnerPerson, "wose1234", 6)
	doneAt := time.Now().UTC().AddDate(0, 0, -1)
	done.Done, done.DoneAt, done.DoneBy = true, &doneAt, "易良慧"
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		HumanSteps: []model.RepoHumanStep{
			humanStep(6995, 1, "Verky Yi", model.RepoOwnerPerson, "wose1234", 5),
			humanStep(5699, 1, "agent", model.RepoOwnerNotAPerson, "", 9),
			done,
		},
		HumanDays: []model.RepoHumanDay{
			{Day: time.Now().UTC().Format(model.RepoDayLayout), Fragments: 51, WithHuman: 2, Steps: 3, StepsDone: 1},
		},
	})

	var got humanDebtResp
	h.getJSON(t, "/v1/repo/human-debt?repo=o/r", &got)
	if len(got.Steps) != 2 {
		t.Fatalf("want the 2 still owed (the finished one is not owed), got %d: %+v", len(got.Steps), got.Steps)
	}
	// Longest wait first: the agent step's fragment is the oldest.
	if got.Steps[0].Fragment != 5699 {
		t.Errorf("want the longest-waiting step first, got #%d", got.Steps[0].Fragment)
	}
	// A step nobody can be reminded about is shown, not dropped.
	if got.Steps[0].OwnerKind != model.RepoOwnerNotAPerson {
		t.Errorf("the not-a-person step was dropped: %+v", got.Steps)
	}
	if len(got.Days) != 1 || got.Days[0].Fragments != 51 || got.Days[0].WithHuman != 2 {
		t.Fatalf("days = %+v", got.Days)
	}

	// state=all is how "how long did that take" stays answerable.
	var all humanDebtResp
	h.getJSON(t, "/v1/repo/human-debt?repo=o/r&state=all", &all)
	if len(all.Steps) != 3 {
		t.Fatalf("state=all should include the finished step, got %d", len(all.Steps))
	}
}

// The ingest response names every kind of row, including the ones this
// snapshot carried none of: a shipper that gets no "human_steps" key back
// cannot tell a hub that stored zero from a hub too old to know the field.
func TestRepoIngest_EchoesHumanCounts(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "shipper")
	resp := h.pushRepo(t, tok, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(1, 1, model.RepoStateOpen)},
	})
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if _, ok := body["human_steps"]; !ok {
		t.Errorf("ingest response must name human_steps even when zero: %+v", body)
	}
	if _, ok := body["human_days"]; !ok {
		t.Errorf("ingest response must name human_days even when zero: %+v", body)
	}
}

// A snapshot carrying ONLY manual steps is legal: the collector that parses a
// repo's release fragments is not the one that counts its issue flow, and
// requiring it to ship issues too would make it invent them.
func TestRepoIngest_HumanOnlySnapshotIsAccepted(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "shipper")
	resp := h.pushRepo(t, tok, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		HumanSteps: []model.RepoHumanStep{humanStep(6995, 1, "发起人", model.RepoOwnerPerson, "wose1234", 2)},
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("human-only snapshot rejected: %d", resp.StatusCode)
	}
}

// A shipper bug must come back as a 400 the shipper can fix, and the rejection
// must name the row — "owner_kind" is a field somebody typed, and a 500 would
// send them reading hub logs instead of their own payload.
func TestRepoIngest_RejectsUnknownOwnerKind(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "shipper")
	bad := humanStep(6995, 1, "发起人", "user", "wose1234", 2) // the producing repo's own spelling
	resp := h.pushRepo(t, tok, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		HumanSteps: []model.RepoHumanStep{bad},
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("want 400 for an unknown owner_kind, got %d", resp.StatusCode)
	}
}
