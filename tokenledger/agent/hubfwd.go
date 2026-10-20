package agent

import (
	"context"
	"log"
	"net/http"
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/hubfwd"
)

// serveHubFwd runs the local forwarder to the hub (claude-fleet T672) at
// path until ctx ends — $CCQUOTA_HUB_SOCK overrides it, "off" turns it off.
// Its own keep-alive client, no overall timeout: a caller's place may wait on
// a remote start for a minute, and its going away cancels the request.
// A forwarder that cannot listen is said once; the callers go direct.
func serveHubFwd(ctx context.Context, hub, dial, path string) {
	if v := os.Getenv(hubfwd.SockEnv); v != "" {
		path = v
	} else if !hubfwd.Known(path) {
		return // nobody would look there (a test's state dir)
	}
	if hub == "" || path == "" || path == "off" {
		return
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 8
	f := &hubfwd.Forwarder{Hub: hub, Dial: dial, Client: &http.Client{Transport: tr}}
	if err := f.Serve(ctx, path); err != nil && ctx.Err() == nil {
		log.Printf("hub forwarder at %s: %v — scripts reach the hub directly", path, err)
	}
}
