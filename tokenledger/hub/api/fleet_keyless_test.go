package api

import (
	"encoding/json"
	"testing"
)

// A keyless window (a no-repo session, claude-fleet#1749) keeps the identity
// worker_id it was reported under; a borrowed identity, or an identity id on a
// row that HAS a key, still loses it.
func TestConsistentWorkersKeylessIdentity(t *testing.T) {
	const fleet = "11111111-2222-4333-8444-555555555555"
	const other = "99999999-2222-4333-8444-555555555555"
	const ident = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	raw, _ := json.Marshal([]map[string]any{
		{"worker_id": fleet + "/" + ident, "key": nil, "identity": ident, "name": "guide"},
		{"worker_id": fleet + "/" + ident, "key": nil, "identity": "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee", "name": "borrowed"},
		{"worker_id": other + "/" + ident, "key": nil, "identity": ident, "name": "other fleet"},
		{"worker_id": fleet + "/" + ident, "key": "issue-7", "identity": ident, "name": "keyed"},
		{"worker_id": fleet + "/issue-8", "key": "issue-8", "identity": ident, "name": "key form"},
	})
	var ws []map[string]any
	if err := json.Unmarshal(consistentWorkers(fleet, raw), &ws); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"guide": fleet + "/" + ident, "borrowed": nil, "other fleet": nil,
		"keyed": nil, "key form": fleet + "/issue-8"}
	for _, w := range ws {
		if got := w["worker_id"]; got != want[w["name"].(string)] {
			t.Errorf("%s: worker_id %v, want %v", w["name"], got, want[w["name"].(string)])
		}
	}
}
