package dns

import (
	"context"
	"fmt"
	"sort"
	"sync"
)

// Fake is an in-memory Provider for tests: it holds the marked records,
// counts every call, and fails the next one when Fail is set.
type Fake struct {
	mu    sync.Mutex
	recs  map[string]Record
	next  int
	Calls map[string]int // List · Upsert · Delete
	Fail  error
}

// NewFake is an empty zone.
func NewFake() *Fake { return &Fake{recs: map[string]Record{}, Calls: map[string]int{}} }

func (f *Fake) take(op string) error {
	f.Calls[op]++
	if err := f.Fail; err != nil {
		f.Fail = nil
		return err
	}
	return nil
}

// Total is every call made so far.
func (f *Fake) Total() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.Calls {
		n += c
	}
	return n
}

// Records is the zone now, by name, type, value.
func (f *Fake) Records() []Record {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]Record, 0, len(f.recs))
	for _, r := range f.recs {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Name != b.Name {
			return a.Name < b.Name
		}
		if a.Type != b.Type {
			return a.Type < b.Type
		}
		return a.Value < b.Value
	})
	return out
}

// Set changes a record behind the loop's back (a hand edit in the console).
func (f *Fake) Set(id, value string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r := f.recs[id]
	r.Value = value
	f.recs[id] = r
}

// List implements Provider.
func (f *Fake) List(context.Context) ([]Record, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.take("List"); err != nil {
		return nil, err
	}
	out := make([]Record, 0, len(f.recs))
	for _, r := range f.recs {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// Upsert implements Provider.
func (f *Fake) Upsert(_ context.Context, r Record) (Record, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.take("Upsert"); err != nil {
		return Record{}, err
	}
	if r.ID == "" {
		f.next++
		r.ID = fmt.Sprintf("r%d", f.next)
	} else if _, ok := f.recs[r.ID]; !ok {
		return Record{}, fmt.Errorf("no record %s", r.ID)
	}
	f.recs[r.ID] = r
	return r, nil
}

// Delete implements Provider.
func (f *Fake) Delete(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.take("Delete"); err != nil {
		return err
	}
	delete(f.recs, id)
	return nil
}
