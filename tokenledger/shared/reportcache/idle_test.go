package reportcache

import (
	"errors"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
	"testing"
	"time"
)

func TestIdleCacheChangesHeartbeatRetryAndUsage(t *testing.T) {
	var c Cache
	n := 0
	fail := false
	send := func() (*model.IngestResponse, error) {
		n++
		if fail {
			return nil, errors.New("offline")
		}
		return &model.IngestResponse{EndpointID: "e"}, nil
	}
	now := time.Now()
	b := model.Batch{Identity: model.Identity{AccountUUID: "a"}, Collector: &model.CollectorStatus{State: "idle", ObservedAt: now}}
	call := func() {
		t.Helper()
		if _, err := c.Do("e", &b, now, send); err != nil {
			t.Fatal(err)
		}
	}
	call()
	b.Collector.ObservedAt = now.Add(time.Second)
	call()
	if n != 1 {
		t.Fatal("identical empty report sent")
	}
	b.Collector.State = "degraded"
	call()
	if n != 2 {
		t.Fatal("status change lost")
	}
	now = now.Add(time.Minute)
	call()
	if n != 3 {
		t.Fatal("heartbeat missing")
	}
	b.Identity.AccountUUID = "b"
	call()
	b.Identity.AccountUUID = "a"
	call()
	if n != 5 {
		t.Fatal("account switch hidden")
	}
	b.Events = []model.UsageEvent{{InputTokens: 1}}
	call()
	call()
	if n != 7 {
		t.Fatal("usage discarded")
	}
	b.Events = nil
	b.Limits = &model.LimitsSnapshot{}
	call()
	call()
	if n != 9 {
		t.Fatal("quota observation discarded")
	}
	b.Limits = nil
	fail = true
	if _, err := c.Do("e", &b, now, send); err == nil {
		t.Fatal("failure hidden")
	}
	fail = false
	call()
	if n != 11 {
		t.Fatal("failed state cached")
	}
}
