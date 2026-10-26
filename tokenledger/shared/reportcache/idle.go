// Package reportcache coalesces identical empty collector reports. Usage events,
// quota observations and attribution always reach the durable ingest path.
package reportcache

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

type entry struct {
	mu       sync.Mutex
	body     string
	at       time.Time
	response model.IngestResponse
}

type Cache struct{ entries sync.Map }

// Do remembers only a successful, empty report for at most a minute. A changed
// identity/status goes through immediately; a nonempty batch invalidates the
// previous report even when its ingest fails. Serialize per endpoint so an old
// account's cached result cannot hide a switch back after another account.
func (c *Cache) Do(key string, batch *model.Batch, now time.Time, send func() (*model.IngestResponse, error)) (*model.IngestResponse, error) {
	v, _ := c.entries.LoadOrStore(key, &entry{})
	e := v.(*entry)
	e.mu.Lock()
	defer e.mu.Unlock()
	body := fingerprint(batch)
	if body != "" && body == e.body && now.Sub(e.at) < time.Minute {
		result := e.response
		return &result, nil
	}
	e.body = ""
	result, err := send()
	if err == nil && result != nil && body != "" {
		e.body, e.at, e.response = body, now, *result
	}
	return result, err
}

func fingerprint(batch *model.Batch) string {
	if len(batch.Events) != 0 || len(batch.Quotas) != 0 || batch.Limits != nil || batch.AccountUsage != nil || batch.Attribution != nil {
		return ""
	}
	b := *batch
	if b.Collector != nil {
		status := *b.Collector
		status.ObservedAt = time.Time{}
		b.Collector = &status
	}
	if b.FleetVersion != nil {
		version := *b.FleetVersion
		version.ObservedAt = time.Time{}
		b.FleetVersion = &version
	}
	raw, err := json.Marshal(b)
	if err != nil {
		return ""
	}
	return string(raw)
}
