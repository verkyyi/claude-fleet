package api

import (
	"net/http"
	"strings"
	"testing"
	"testing/fstest"
)

// The company-business routes are gone (claude-fleet#1987): each answers 404
// to a stranger and to the operator alike — never the app's index, never a
// 401 that would say something is there.
func TestRemovedRoutesAre404(t *testing.T) {
	h := newHarness(t)
	h.srv.UI = fstest.MapFS{
		"index.html": &fstest.MapFile{Data: []byte("<!doctype html><title>app</title>")},
		"app.js":     &fstest.MapFile{Data: []byte("// app")},
	}
	removed := []string{
		"/growth", "/growth/", "/v1/ingest/growth", "/v1/growth/latest",
		"/v1/repos", "/v1/repo/flow", "/v1/repo/issues", "/v1/repo/cost", "/v1/repo/human-debt", "/v1/ingest/repo",
		"/share", "/share/abc", "/v1/share",
		"/v1/fx",
		"/enter",
	}
	for _, path := range removed {
		for _, who := range []struct {
			name string
			hdr  map[string]string
		}{
			{"no credential", map[string]string{"Accept": "text/html"}},
			{"the viewer token", map[string]string{"Authorization": "Bearer " + viewerToken}},
		} {
			for _, method := range []string{http.MethodGet, http.MethodPost} {
				req, _ := http.NewRequest(method, h.http.URL+path, strings.NewReader("{}"))
				for k, v := range who.hdr {
					req.Header.Set(k, v)
				}
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				resp.Body.Close()
				if resp.StatusCode != http.StatusNotFound {
					t.Errorf("%s %s with %s = %d, want 404", method, path, who.name, resp.StatusCode)
				}
			}
		}
	}
	// What remains is untouched: the app at "/" and its own files.
	for _, path := range []string{"/", "/app.js"} {
		if code := h.getCode(t, path); code != http.StatusOK {
			t.Errorf("GET %s = %d, want 200", path, code)
		}
	}
}
