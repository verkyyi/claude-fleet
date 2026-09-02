// internal/api/scope_test.go
package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

func TestScopeParsesChipsAndAlignsHours(t *testing.T) {
	h := newHarness(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/v1/summary?account=all&since=2026-09-02T10:20:00Z&until=2026-09-02T12:05:00Z"+
		"&endpoint=ep1&user=u&project=%2Fp&model=m&branch=b&team=t&session=s", nil)
	f, ok := h.srv.scope(rec, req)
	if !ok {
		t.Fatalf("scope refused: %s", rec.Body.String())
	}
	if f.Account != store.AllAccounts || f.Endpoint != "ep1" || f.OSUser != "u" || f.CWD != "/p" ||
		f.Model != "m" || f.Branch != "b" || f.Team != "t" || f.Session != "s" {
		t.Fatalf("%+v", f)
	}
	if !f.Start.Equal(time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC)) || !f.End.Equal(time.Date(2026, 9, 2, 13, 0, 0, 0, time.UTC)) {
		t.Fatalf("not hour-aligned: %v..%v", f.Start, f.End)
	}
}

func TestScopeRejectsMalformedTime(t *testing.T) {
	h := newHarness(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/v1/summary?account=all&since=yesterday", nil)
	if _, ok := h.srv.scope(rec, req); ok || rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got ok=%v code=%d", ok, rec.Code)
	}
}
