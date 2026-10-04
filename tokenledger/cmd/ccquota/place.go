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
	"strconv"
	"strings"
	"time"
)

// ccquota place — a node asks the hub where a new session should run
// (claude-fleet#1425, EPIC #1419 C6).
//
// claude-fleet's dash-issue-session.sh runs it (FLEET_HUB_PLACE_CMD) after it
// took the issue's lease. One line on stdout, the reason after a TAB, one exit
// code:
//
//	0  LOCAL <machine>\t<reason>                     open it here, as always
//	0  REMOTE <machine> <operation_id> <status>\t<reason>
//	                                                 the hub sent the start there
//	3  HELD <machine>\t<message>                     the issue is leased elsewhere
//	4  REFUSED <code>\t<message>                     no machine can take it (or
//	                                                 the chosen one refused)
//	1  the hub could not be asked (stderr says why)
//	2  usage

// placeRefused is the exit code of a placement the hub answered with no.
const placeRefused = 4

// placeTimeout covers the hub's own wait for the remote node to take the
// start (fleetWriteWait, 25s) plus the round trip.
const placeTimeout = 40 * time.Second

func runPlace(args []string) error {
	code, err := place(args, os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccquota place:", err)
	}
	if code != 0 {
		os.Exit(code)
	}
	return nil
}

func place(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("place", flag.ContinueOnError)
	fs.SetOutput(stderr)
	hub := fs.String("hub", os.Getenv("CCQUOTA_HUB_URL"), "hub base URL")
	token := fs.String("token", os.Getenv("CCQUOTA_TOKEN"), "this endpoint's enrollment token")
	node := fs.String("node", "auto", "auto, or the machine to open it on")
	origin := fs.String("origin-wid", "", "the worker_id of the session that asked for this one")
	agent := fs.String("agent", "", "claude or codex (default: the chosen fleet's)")
	key := fs.String("key", "", "idempotency key (default: one per call)")
	fs.Usage = func() {
		fmt.Fprint(stderr, `Usage: ccquota place [--node auto|<machine>] [--origin-wid <wid>] [--agent a] <owner/repo> <issue> <worker_id>

Ask the hub which machine should open a session on an issue (claude-fleet#1425).
Exit 0 LOCAL/REMOTE, 3 held elsewhere, 4 refused, 1 hub unreachable, 2 usage.
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2, nil
	}
	rest := fs.Args()
	if len(rest) != 3 {
		fs.Usage()
		return 2, nil
	}
	issue, err := strconv.Atoi(rest[1])
	if err != nil || issue <= 0 {
		return 2, fmt.Errorf("issue must be a positive number, not %q", rest[1])
	}
	if *hub == "" || *token == "" {
		return 1, errors.New("no hub configured (CCQUOTA_HUB_URL and CCQUOTA_TOKEN)")
	}
	body, _ := json.Marshal(map[string]any{"repo": rest[0], "issue": issue, "worker_id": rest[2],
		"node": *node, "origin_wid": *origin, "agent": *agent, "idempotency_key": *key})
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(*hub, "/")+"/v1/node/place", bytes.NewReader(body))
	if err != nil {
		return 1, err
	}
	req.Header.Set("Authorization", "Bearer "+*token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: placeTimeout}).Do(req)
	if err != nil {
		return 1, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 256<<10))
	var out struct {
		Local     *bool `json:"local"`
		Placement struct {
			Machine string `json:"machine"`
			Reason  string `json:"reason"`
		} `json:"placement"`
		Operation struct {
			ID     string `json:"operation_id"`
			Status string `json:"status"`
		} `json:"operation"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
		Holder struct {
			Node string `json:"node"`
		} `json:"holder"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return 1, fmt.Errorf("hub answered HTTP %d with something that is not JSON", resp.StatusCode)
	}
	oneLine := func(s string) string { return strings.Join(strings.Fields(s), " ") }
	switch {
	case resp.StatusCode == http.StatusOK && out.Local != nil && *out.Local:
		fmt.Fprintf(stdout, "LOCAL %s\t%s\n", out.Placement.Machine, oneLine(out.Placement.Reason))
		return 0, nil
	case resp.StatusCode == http.StatusOK && out.Local != nil && out.Operation.ID != "":
		fmt.Fprintf(stdout, "REMOTE %s %s %s\t%s\n", out.Placement.Machine, out.Operation.ID,
			out.Operation.Status, oneLine(out.Placement.Reason))
		return 0, nil
	case out.Error.Code == "ALREADY_CLAIMED":
		fmt.Fprintf(stdout, "HELD %s\t%s\n", out.Holder.Node, oneLine(out.Error.Message))
		return leaseHeld, nil
	case out.Error.Code != "" && resp.StatusCode < 500 || out.Error.Code == "NO_ELIGIBLE_NODE" ||
		out.Error.Code == "UNAVAILABLE":
		fmt.Fprintf(stdout, "REFUSED %s\t%s\n", out.Error.Code, oneLine(out.Error.Message))
		return placeRefused, nil
	}
	return 1, fmt.Errorf("hub answered HTTP %d: %s", resp.StatusCode, oneLine(string(raw)))
}
