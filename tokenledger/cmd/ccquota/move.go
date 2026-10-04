package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// ccquota move — a node moves one of its sessions to another machine through
// the hub (claude-fleet#1426, EPIC #1419 C7). claude-fleet's fleet-move.sh
// --via hub runs it (FLEET_HUB_MOVE_CMD); one line on stdout, the reason after
// a TAB, one exit code:
//
//	ccquota move plan [--node auto|<machine>] <repo> <worker_id>
//	  0  LOCAL <machine>\t<reason>             the best machine is this one
//	  0  REMOTE <machine> movable|old\t<reason> another machine; `old` = its
//	                                           agent cannot take a move yet
//	  4  REFUSED <code>\t<message>
//
//	ccquota move send --node <machine> --bundle <tar> --branch <b> --sid <uuid>
//	                  --name <n> [--pushed] [--raw 0|1] [--state s] [--origin o]
//	                  [--origin-wid w] [--handle h] [--wait S] <repo> <worker_id>
//	  0  MOVED <machine> <window> <pid>\t<new worker_id>
//	  3  HELD <machine>\t<message>             the issue is leased elsewhere
//	  4  REFUSED <code>\t<message>             nothing changed hands
//	  5  FAILED <code>\t<message>              the target tried and failed; the
//	                                           lease is back with the source
//	  6  UNKNOWN <operation>\t<message>        no outcome within --wait: do NOT
//	                                           close the source; read it later
//
//	1  the hub could not be asked (stderr says why) · 2 usage

const (
	moveRefused = 4
	moveFailed  = 5
	moveUnknown = 6
)

// moveHTTPTimeout covers the hub's own wait for the target to take the write
// (it downloads the bundle first: moveWriteWait, 120 s) plus the round trip.
const moveHTTPTimeout = 150 * time.Second

// movePollEvery paces the outcome reads.
var movePollEvery = 2 * time.Second

func runMove(args []string) error {
	code, err := move(args, os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccquota move:", err)
	}
	if code != 0 {
		os.Exit(code)
	}
	return nil
}

type moveAnswer struct {
	Local     *bool `json:"local"`
	Movable   bool  `json:"movable"`
	Placement struct {
		Machine string `json:"machine"`
		Reason  string `json:"reason"`
	} `json:"placement"`
	Operation struct {
		ID     string          `json:"operation_id"`
		Status string          `json:"status"`
		Result json.RawMessage `json:"result"`
	} `json:"operation"`
	ToWID string `json:"to_wid"`
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
	Holder struct {
		Node string `json:"node"`
	} `json:"holder"`
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

func shortHost(h string) string {
	if i := strings.IndexByte(h, '.'); i > 0 {
		return h[:i]
	}
	return h
}

func move(args []string, stdout, stderr io.Writer) (int, error) {
	if len(args) == 0 || (args[0] != "plan" && args[0] != "send") {
		fmt.Fprintln(stderr, "Usage: ccquota move plan|send [flags] <owner/repo> <worker_id>")
		return 2, nil
	}
	sub := args[0]
	fs := flag.NewFlagSet("move "+sub, flag.ContinueOnError)
	fs.SetOutput(stderr)
	hub := fs.String("hub", os.Getenv("CCQUOTA_HUB_URL"), "hub base URL")
	token := fs.String("token", os.Getenv("CCQUOTA_TOKEN"), "this endpoint's enrollment token")
	node := fs.String("node", "auto", "auto, or the machine to move to")
	bundle := fs.String("bundle", "", "send: the transcript tar")
	branch := fs.String("branch", "", "send: the session's branch")
	pushed := fs.Bool("pushed", false, "send: the branch is on origin")
	sid := fs.String("sid", "", "send: the Claude Code session id")
	name := fs.String("name", "", "send: the window name")
	rawWin := fs.Int("raw", 0, "send: 1 for a raw (scratch) window")
	state := fs.String("state", "", "send: the window's state")
	origin := fs.String("origin", "", "send: the window's @origin")
	originWID := fs.String("origin-wid", "", "send: the window's @origin_wid")
	handle := fs.String("handle", "", "send: the window's @wid handle")
	wait := fs.Duration("wait", 150*time.Second, "send: how long to wait for the outcome")
	key := fs.String("key", "", "idempotency key (default: one per bundle)")
	if err := fs.Parse(args[1:]); err != nil {
		return 2, nil
	}
	rest := fs.Args()
	if len(rest) != 2 {
		fmt.Fprintln(stderr, "Usage: ccquota move plan|send [flags] <owner/repo> <worker_id>")
		return 2, nil
	}
	if *hub == "" || *token == "" {
		return 1, errors.New("no hub configured (CCQUOTA_HUB_URL and CCQUOTA_TOKEN)")
	}
	base := strings.TrimRight(*hub, "/")
	client := &http.Client{Timeout: moveHTTPTimeout}
	post := func(path, ctype string, body []byte) (int, []byte, error) {
		req, err := http.NewRequest(http.MethodPost, base+path, bytes.NewReader(body))
		if err != nil {
			return 0, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+*token)
		req.Header.Set("Content-Type", ctype)
		resp, err := client.Do(req)
		if err != nil {
			return 0, nil, err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		return resp.StatusCode, b, nil
	}
	ask := func(body map[string]any) (int, moveAnswer, error) {
		var a moveAnswer
		b, _ := json.Marshal(body)
		st, resp, err := post("/v1/node/move", "application/json", b)
		if err != nil {
			return 0, a, err
		}
		if json.Unmarshal(resp, &a) != nil {
			return st, a, fmt.Errorf("hub answered HTTP %d with something that is not JSON", st)
		}
		return st, a, nil
	}
	refused := func(a moveAnswer) int {
		fmt.Fprintf(stdout, "REFUSED %s\t%s\n", a.Error.Code, oneLine(a.Error.Message))
		return moveRefused
	}

	if sub == "plan" {
		st, a, err := ask(map[string]any{"action": "plan", "repo": rest[0], "worker_id": rest[1], "node": *node})
		switch {
		case err != nil:
			return 1, err
		case st == http.StatusOK && a.Local != nil && *a.Local:
			fmt.Fprintf(stdout, "LOCAL %s\t%s\n", shortHost(a.Placement.Machine), oneLine(a.Placement.Reason))
			return 0, nil
		case st == http.StatusOK && a.Local != nil:
			m := "old"
			if a.Movable {
				m = "movable"
			}
			fmt.Fprintf(stdout, "REMOTE %s %s\t%s\n", shortHost(a.Placement.Machine), m, oneLine(a.Placement.Reason))
			return 0, nil
		case a.Error.Code != "" && st < 500 || a.Error.Code == "NO_ELIGIBLE_NODE" || a.Error.Code == "UNAVAILABLE":
			return refused(a), nil
		}
		return 1, fmt.Errorf("hub answered HTTP %d", st)
	}

	// send: the bundle first, then the move, then its outcome.
	if *bundle == "" || *branch == "" || *sid == "" || *name == "" || *node == "auto" {
		fmt.Fprintln(stderr, "ccquota move send: --node <machine>, --bundle, --branch, --sid and --name are required")
		return 2, nil
	}
	tarball, err := os.ReadFile(*bundle)
	if err != nil {
		return 1, err
	}
	st, raw, err := post("/v1/node/move/bundle", "application/x-tar", tarball)
	if err != nil {
		return 1, err
	}
	var up struct {
		ID string `json:"bundle_id"`
	}
	if st != http.StatusOK || json.Unmarshal(raw, &up) != nil || up.ID == "" {
		if st == http.StatusRequestEntityTooLarge || (st >= 400 && st < 500) {
			fmt.Fprintf(stdout, "REFUSED BUNDLE\t%s\n", oneLine(string(raw)))
			return moveRefused, nil
		}
		return 1, fmt.Errorf("bundle upload: hub answered HTTP %d: %s", st, oneLine(string(raw)))
	}
	req := map[string]any{"action": "move", "repo": rest[0], "worker_id": rest[1], "node": *node,
		"branch": *branch, "pushed": *pushed, "sid": *sid, "name": *name, "raw": *rawWin, "state": *state,
		"origin": *origin, "origin_wid": *originWID, "handle": *handle, "bundle_id": up.ID, "idempotency_key": *key}
	st, a, err := ask(req)
	switch {
	case err != nil:
		return 1, err
	case a.Error.Code == "ALREADY_CLAIMED":
		fmt.Fprintf(stdout, "HELD %s\t%s\n", a.Holder.Node, oneLine(a.Error.Message))
		return leaseHeld, nil
	case st != http.StatusOK && (a.Error.Code != "" && st < 500 || a.Error.Code == "NO_ELIGIBLE_NODE" || a.Error.Code == "UNAVAILABLE"):
		return refused(a), nil
	case st != http.StatusOK || a.Operation.ID == "":
		return 1, fmt.Errorf("hub answered HTTP %d", st)
	}
	machine, toWID, op := shortHost(a.Placement.Machine), a.ToWID, a.Operation
	deadline := time.Now().Add(*wait)
	for {
		switch op.Status {
		case "succeeded":
			var r struct {
				Window string `json:"window"`
				PID    string `json:"pid"`
			}
			_ = json.Unmarshal(op.Result, &r)
			fmt.Fprintf(stdout, "MOVED %s %s %s\t%s\n", machine, r.Window, r.PID, toWID)
			return 0, nil
		case "failed":
			var r struct {
				Error struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			_ = json.Unmarshal(op.Result, &r)
			fmt.Fprintf(stdout, "FAILED %s\t%s\n", r.Error.Code, oneLine(r.Error.Message))
			return moveFailed, nil
		}
		if time.Now().After(deadline) {
			fmt.Fprintf(stdout, "UNKNOWN %s\tno outcome from %s within %s (last: %s)\n", op.ID, machine, *wait, op.Status)
			return moveUnknown, nil
		}
		time.Sleep(movePollEvery)
		st, s2, err := ask(map[string]any{"action": "status", "worker_id": rest[1], "operation_id": op.ID})
		if err != nil || st != http.StatusOK {
			continue // the hub is briefly away: keep waiting until the deadline
		}
		op = s2.Operation
	}
}
