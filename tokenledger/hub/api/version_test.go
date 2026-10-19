package api

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestVersionCommit(t *testing.T) {
	for in, want := range map[string]string{
		"prod-fe65a43":            "fe65a43",
		"prod-fe65a43a":           "fe65a43a",
		"fe65a43":                 "fe65a43",
		"ci-fe65a43":              "fe65a43",
		"v1.2.0-3-gfe65a43":       "fe65a43",
		"v1.2.0-3-gfe65a43-dirty": "fe65a43",
		"docker":                  "",
		"dev":                     "",
		"v1.2.0":                  "",
		"prod-fe65":               "",
		"":                        "",
	} {
		if got := VersionCommit(in); got != want {
			t.Errorf("VersionCommit(%q) = %q, want %q", in, got, want)
		}
	}
}

// /version is public like /healthz: the doctor on any machine reads it with
// no token (claude-fleet#1696).
func TestVersionEndpointIsPublic(t *testing.T) {
	h := newHarness(t)
	h.srv.Version = "prod-fe65a43"
	resp, err := h.http.Client().Get(h.http.URL + "/version")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/version: HTTP %d without a token, want 200", resp.StatusCode)
	}
	var got map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got["version"] != "prod-fe65a43" || got["commit"] != "fe65a43" {
		t.Errorf("/version = %v", got)
	}
}
