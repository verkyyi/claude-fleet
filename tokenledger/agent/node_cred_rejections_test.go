package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func rejectionStore(t *testing.T, response string) (string, <-chan map[string]any) {
	t.Helper()
	directory, err := os.MkdirTemp("", "reject")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	socket := filepath.Join(directory, "ctl.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	requests := make(chan map[string]any, 8)
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			connection.SetDeadline(time.Now().Add(time.Second))
			line, _ := bufio.NewReader(connection).ReadBytes('\n')
			var request map[string]any
			json.Unmarshal(line, &request)
			requests <- request
			fmt.Fprintln(connection, response)
			connection.Close()
		}
	}()
	return socket, requests
}

func TestSeparatedRejectionReachesHubWithoutLocalAuth(t *testing.T) {
	fingerprint := strings.Repeat("a", 64)
	socket, requests := rejectionStore(t, fmt.Sprintf(`{"ok":true,"rejected":[{"provider":"codex","account":"default","fingerprint":%q,"error":"token_expired"}]}`, fingerprint))
	body := make(chan []byte, 1)
	hub := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		raw, _ := io.ReadAll(request.Body)
		body <- raw
		fmt.Fprint(writer, `{"credentials":[]}`)
	}))
	t.Cleanup(hub.Close)
	agent := credAgent(hub, t.TempDir())
	agent.cfg.FleetCredStore = socket
	agent.cfg.RunAs = &RunAs{Login: "fixture-tenant"}
	if _, err := agent.fetchCredLease(context.Background()); err != nil {
		t.Fatal(err)
	}
	if request := <-requests; request["op"] != "upstream-rejections" || request["as"] != "fixture-tenant" {
		t.Fatalf("request = %v", request)
	}
	var reported struct {
		Rejected []upstreamRejection `json:"upstream_rejected"`
	}
	if err := json.Unmarshal(<-body, &reported); err != nil {
		t.Fatal(err)
	}
	if len(reported.Rejected) != 1 || reported.Rejected[0].Fingerprint != fingerprint || reported.Rejected[0].Error != "token_expired" {
		t.Fatalf("reported = %+v", reported)
	}
	if !agent.credReported[fingerprint] {
		t.Fatal("successfully reported rejection not remembered")
	}
	if _, err := os.Stat(filepath.Join(agent.cfg.Home, ".codex", "auth.json")); !os.IsNotExist(err) {
		t.Fatal("test must not depend on local auth.json")
	}
}

func TestSeparatedRejectionUnavailableDoesNotInventRefusal(t *testing.T) {
	for _, response := range []string{`{"ok":false,"err":"unknown op"}`, `not-json`, `{"ok":true,"rejected":[]}`} {
		t.Run(response, func(t *testing.T) {
			socket, _ := rejectionStore(t, response)
			agent := &Agent{cfg: Config{Home: t.TempDir(), FleetCredStore: socket}}
			if rejected := agent.upstreamRejections(); len(rejected) != 0 {
				t.Fatalf("unexpected rejection: %+v", rejected)
			}
		})
	}
}
