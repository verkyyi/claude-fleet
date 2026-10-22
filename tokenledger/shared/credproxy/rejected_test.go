package credproxy

import (
	"compress/gzip"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type rejectionResolver struct {
	reports atomic.Int64
	result  Resolution
	err     error
}

func (resolver *rejectionResolver) Resolve(context.Context, string, string) (Resolution, error) {
	return Resolution{Valid: true, Provider: Codex, Owner: "pool", Account: "default", AccessToken: "old"}, nil
}

func (resolver *rejectionResolver) RejectAccess(_ context.Context, _, _ string, previous Resolution, code string) (Resolution, error) {
	resolver.reports.Add(1)
	if previous.AccessToken != "old" || code != "token_expired" {
		return Resolution{}, errors.New("incorrect rejection")
	}
	return resolver.result, resolver.err
}

func TestRejectedAccessRetry(t *testing.T) {
	for _, test := range []struct {
		name       string
		status     int
		body       string
		token      string
		refreshErr error
		retryFails bool
		wantStatus int
		wantCalls  int64
		wantReport int64
	}{
		{"expired", 401, `{"error":{"code":"token_expired"}}`, "new", nil, false, 401, 1, 1},
		{"relay auth", 401, `{"error":{"code":"unauthenticated"}}`, "new", nil, false, 401, 1, 0},
		{"refresh token rejected", 401, `{"error":{"code":"refresh_token_expired"}}`, "new", nil, false, 401, 1, 0},
		{"plain response", 401, "unauthorized", "new", nil, false, 401, 1, 0},
		{"other status", 403, `{"error":{"code":"token_expired"}}`, "new", nil, false, 403, 1, 0},
		{"hub down", 401, `{"error":{"code":"token_expired"}}`, "new", ErrHubUnavailable, false, 401, 1, 1},
		{"unchanged token", 401, `{"error":{"code":"token_expired"}}`, "old", nil, false, 401, 1, 1},
		{"retry bounded", 401, `{"error":{"code":"token_expired"}}`, "new", nil, true, 401, 1, 1},
		{"gzip expired", 401, `{"error":{"code":"token_expired"}}`, "new", nil, false, 401, 1, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int64
			upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				calls.Add(1)
				body, _ := io.ReadAll(request.Body)
				if string(body) != `{"input":"request-body"}` {
					t.Error("request body changed on retry")
				}
				if request.Header.Get("Authorization") == "Bearer new" && !test.retryFails {
					_, _ = io.WriteString(writer, "reply")
					return
				}
				if test.name == "gzip expired" {
					writer.Header().Set("Content-Encoding", "gzip")
					writer.WriteHeader(test.status)
					compressed := gzip.NewWriter(writer)
					_, _ = io.WriteString(compressed, test.body)
					_ = compressed.Close()
					return
				}
				writer.WriteHeader(test.status)
				_, _ = io.WriteString(writer, test.body)
			}))
			defer upstream.Close()
			resolver := &rejectionResolver{result: Resolution{Valid: true, Provider: Codex, Owner: "pool", Account: "default", AccessToken: test.token}, err: test.refreshErr}
			proxy, err := New(Config{Resolver: resolver, Direct: true, CodexURL: upstream.URL, Audit: func(string) {}})
			if err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodPost, "/v1/proxy/codex/responses", strings.NewReader(`{"input":"request-body"}`))
			request.Header.Set("Authorization", "Bearer fcp-h1.test")
			response := httptest.NewRecorder()
			proxy.Handler().ServeHTTP(response, request)
			if response.Code != test.wantStatus || calls.Load() != test.wantCalls || resolver.reports.Load() != test.wantReport {
				t.Fatalf("status=%d calls=%d reports=%d", response.Code, calls.Load(), resolver.reports.Load())
			}
			body := response.Body.String()
			if response.Header().Get("Content-Encoding") == "gzip" {
				decoded, err := gzip.NewReader(strings.NewReader(body))
				if err != nil {
					t.Fatal(err)
				}
				raw, err := io.ReadAll(decoded)
				decoded.Close()
				if err != nil {
					t.Fatal(err)
				}
				body = string(raw)
			}
			if test.wantStatus != 200 && body != test.body {
				t.Fatalf("original refusal changed: %q", response.Body.String())
			}
		})
	}
}

func TestForgetRejectedAccessOnly(t *testing.T) {
	proxy := &Proxy{cache: map[string]*entry{
		"old":   {ok: true, res: Resolution{Provider: Codex, Owner: "pool", Account: "default", AccessToken: "old"}},
		"new":   {ok: true, res: Resolution{Provider: Codex, Owner: "pool", Account: "default", AccessToken: "new"}},
		"other": {ok: true, res: Resolution{Provider: Codex, Owner: "another", Account: "default", AccessToken: "old"}},
	}}
	proxy.forgetAccess(Codex, proxy.cache["old"].res)
	if proxy.cache["old"].ok || !proxy.cache["new"].ok || !proxy.cache["other"].ok {
		t.Fatal("rejection invalidated a different credential or left the rejected token cached")
	}
}
