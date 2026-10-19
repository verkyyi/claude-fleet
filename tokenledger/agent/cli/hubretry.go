package cli

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"syscall"
	"time"
)

// hubRetryDelays is how long a node's one-shot hub call waits before each
// retry of a transient failure (claude-fleet#4933): a hub replica stopping in
// a rolling release cuts the requests it still holds once its shutdown grace
// is over — `ccquota place` waits up to a minute per machine on a remote
// start, far past the 25 s grace — and the caller saw `Post "…": EOF`. Two
// retries, 1 s then 3 s; a test shortens them.
var hubRetryDelays = []time.Duration{time.Second, 3 * time.Second}

// hubTransient says whether a failed round trip is worth one more try: the
// connection dropped under the request (EOF, reset, broken pipe) or a gateway
// answered for a replica that went away (502/503/504 that is not the hub's
// own JSON — the hub's own 503s, e.g. NO_ELIGIBLE_NODE, are answers). A
// timeout, a refused dial or any other answer is final.
func hubTransient(resp *http.Response, err error) bool {
	if err != nil {
		return errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
			errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.EPIPE)
	}
	switch resp.StatusCode {
	case http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return !strings.HasPrefix(resp.Header.Get("Content-Type"), "application/json")
	}
	return false
}

// hubDo sends the request build makes, retrying a transient failure with
// hubRetryDelays. build is called once per try (a body is read once), so a
// retry is the SAME request — the caller makes it idempotent (place's key,
// lease's same worker_id). Each retry is one stderr line `ccquota <what>:
// retry k/n after: <why>`; the shell's failure reader skips those lines.
func hubDo(client *http.Client, build func() (*http.Request, error), what string, stderr io.Writer) (*http.Response, error) {
	for try := 0; ; try++ {
		req, err := build()
		if err != nil {
			return nil, err
		}
		resp, err := client.Do(req)
		if try >= len(hubRetryDelays) || !hubTransient(resp, err) {
			return resp, err
		}
		why := ""
		if err != nil {
			why = err.Error()
		} else {
			why = "hub answered HTTP " + resp.Status + " from a gateway"
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
			resp.Body.Close()
		}
		fmt.Fprintf(stderr, "ccquota %s: retry %d/%d after: %s\n", what, try+1, len(hubRetryDelays), why)
		time.Sleep(hubRetryDelays[try])
	}
}
