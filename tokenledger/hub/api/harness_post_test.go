package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

// post is the harness's counterpart to get/getJSON: a viewer-token JSON
// POST.
func (h *harness) post(t *testing.T, path string, body any) (int, map[string]any) {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+path, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	req.Header.Set("Content-Type", "application/json")
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}
