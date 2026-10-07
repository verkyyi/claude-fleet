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

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
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
//	0  REMOTE <machine> <operation_id> done <window>\t<reason>
//	                                                 ... and a window opened there
//	3  HELD <machine>\t<message>                     the issue is leased elsewhere
//	4  REFUSED <code>\t<message>                     no machine can take it (or
//	                                                 the chosen one refused)
//	5  DECLINED <machine> <operation_id> <exit>\t<line>
//	                                                 the start was sent and that
//	                                                 machine's spawn refused it:
//	                                                 its exit code (2 at capacity,
//	                                                 3 claimed, 1 anything else)
//	                                                 and its refusal line — or
//	                                                 it never reached that
//	                                                 machine / never started
//	                                                 there (1, claude-fleet#1606)
//	6  UNKNOWN <machine> <operation_id>\t<message>   still running there when the
//	                                                 wait ran out — not a success
//	Every answer but REMOTE … done hands the lease back to the asker (#1606).
//	1  the hub could not be asked (stderr says why)
//	2  usage
//
// The hub waits on a REMOTE start's outcome (claude-fleet#1586) — --wait
// seconds, its own default (60, claude-fleet#1606) when not given; --wait 0
// answers on acceptance, the status-only REMOTE line. A hub predating #1586 always answers that way.

// placeRefused is the exit code of a placement the hub answered with no;
// placeDeclined of a start the chosen machine's spawn refused; placeUnknown
// of one with no final state in time.
const (
	placeRefused  = 4
	placeDeclined = 5
	placeUnknown  = 6
)

// placeTimeout covers the hub's own wait for the remote node to take the
// start (fleetWriteWait, 25s) plus the round trip; the outcome wait comes on
// top (placeWaitDefault when --wait is not given, as the hub's default).
// workerAssertEnv names the worker assertion a session's tool service hands
// the spawn it runs (claude-fleet#1810).
const workerAssertEnv = "FLEET_WORKER_ASSERT"

const (
	placeTimeout     = 40 * time.Second
	placeWaitDefault = 60
)

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
	token := secretEnvFlag(fs, "token", "CCQUOTA_TOKEN", "this endpoint's enrollment `token`")
	node := fs.String("node", "auto", "auto, or the machine to open it on")
	origin := fs.String("origin-wid", "", "the worker_id of the session that asked for this one")
	agent := fs.String("agent", "", "claude or codex (default: the chosen fleet's)")
	account := fs.String("account", "", "local, pool or any: the kind of subscription the session runs on (default: the opening fleet's pick)")
	key := fs.String("key", "", "idempotency key (default: one per call)")
	wait := fs.Int("wait", -1, "seconds the hub waits on a remote start's outcome (default: the hub's, 60; 0 = answer on acceptance)")
	name := fs.String("name", "", "a scratch session's name (with `scratch` in place of the issue)")
	reap := fs.String("reap", "", "when the session may be closed on its own: merged[:<dur>], done[:<dur>], loop-end, at:<time> or keep (claude-fleet#1902; default: its kind's)")
	fs.Usage = func() {
		fmt.Fprint(stderr, `Usage: ccquota place [--node auto|<machine>] [--origin-wid <wid>] [--agent a] [--account local|pool|any] <owner/repo> <issue> <worker_id>
       ccquota place [--node auto|<machine>] [--origin-wid <wid>] [--agent a] [--account local|pool|any] [--name <n>] <owner/repo> scratch <fleet UUID>

Ask the hub which machine should open a session on an issue (claude-fleet#1425),
or a raw scratch session with no issue (claude-fleet#1541: no lease; the
scratch-<N> is minted where it opens, so the asker names its fleet).
Exit 0 LOCAL/REMOTE, 3 held elsewhere, 4 refused, 5 the chosen machine
declined the start, 6 its outcome is unknown, 1 hub unreachable, 2 usage.
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
	ask := map[string]any{"repo": rest[0], "node": *node, "origin_wid": *origin, "agent": *agent, "idempotency_key": *key}
	if rest[1] == "scratch" {
		if !fleetid.IsUUID(rest[2]) {
			return 2, fmt.Errorf("a scratch start names the asking fleet's UUID, not %q", rest[2])
		}
		ask["kind"], ask["fleet_id"] = "scratch", rest[2]
		if *name != "" {
			ask["name"] = *name
		}
	} else {
		issue, err := strconv.Atoi(rest[1])
		if err != nil || issue <= 0 {
			return 2, fmt.Errorf("issue must be a positive number (or scratch), not %q", rest[1])
		}
		if *name != "" {
			return 2, errors.New("--name is for a scratch start")
		}
		ask["issue"], ask["worker_id"] = issue, rest[2]
	}
	if *hub == "" || *token == "" {
		return 1, errors.New("no hub configured (CCQUOTA_HUB_URL and CCQUOTA_TOKEN)")
	}
	if *account != "" {
		ask["account_class"] = *account
	}
	if *reap != "" {
		ask["reap"] = *reap
	}
	timeout := placeTimeout + placeWaitDefault*time.Second
	if *wait >= 0 {
		ask["wait"] = *wait
		timeout = placeTimeout + time.Duration(*wait)*time.Second
	}
	body, _ := json.Marshal(ask)
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(*hub, "/")+"/v1/node/place", bytes.NewReader(body))
	if err != nil {
		return 1, err
	}
	req.Header.Set("Authorization", "Bearer "+*token)
	req.Header.Set("Content-Type", "application/json")
	// The session this placement is for (claude-fleet#1810): its tool service
	// (bin/fleet-mcp.py) verified the session's credential and signed this
	// with the node's token. Environment only, never an argv; absent = the
	// node's own call, as before.
	if a := strings.TrimSpace(os.Getenv(workerAssertEnv)); a != "" {
		req.Header.Set("X-Fleet-Worker", a)
	}
	resp, err := (&http.Client{Timeout: timeout}).Do(req)
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
		Outcome *struct {
			State  string `json:"state"`
			Exit   *int   `json:"exit"`
			Stderr string `json:"stderr1"`
			Window string `json:"window"`
		} `json:"outcome"`
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
	case resp.StatusCode == http.StatusOK && out.Local != nil && out.Operation.ID != "" && out.Outcome != nil:
		// What became of the start there (claude-fleet#1586).
		oc := out.Outcome
		switch {
		case oc.State == "done":
			win := oc.Window
			if win == "" {
				win = "-"
			}
			fmt.Fprintf(stdout, "REMOTE %s %s done %s\t%s\n", out.Placement.Machine, out.Operation.ID,
				oneLine(win), oneLine(out.Placement.Reason))
			return 0, nil
		case (oc.State == "refused" || oc.State == "failed") && oc.Exit != nil && *oc.Exit > 0:
			fmt.Fprintf(stdout, "DECLINED %s %s %d\t%s\n", out.Placement.Machine, out.Operation.ID,
				*oc.Exit, oneLine(oc.Stderr))
			return placeDeclined, nil
		}
		fmt.Fprintf(stdout, "UNKNOWN %s %s\t%s\n", out.Placement.Machine, out.Operation.ID, oneLine(oc.Stderr))
		return placeUnknown, nil
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
