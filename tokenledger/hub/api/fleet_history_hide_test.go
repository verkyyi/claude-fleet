package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

func historyCacheServer(t *testing.T) *Server {
	t.Helper()
	st := storetest.OpenFleet(t)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	return &Server{Store: st, Vault: &credvault.Vault{Store: st, Sealer: sealer}}
}

func historyCacheRecord(t *testing.T, s *Server, owner string, n int, sid string) store.HistoryHideManifest {
	t.Helper()
	now := time.Now()
	fid := fmt.Sprintf("12345678-1234-4234-8234-%012d", n)
	events := []map[string]any{{"ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "key": "scratch-1"}}
	natives := []string{}
	if sid != "" {
		events = append(events, map[string]any{"ev": "native", "seq": float64(2), "ts": float64(now.Unix()), "native": sid, "agent": "claude"})
		natives = append(natives, sid)
	}
	seq := len(events) + 1
	events = append(events, map[string]any{"ev": "closed", "seq": float64(seq), "ts": float64(now.Unix())})
	if _, err := s.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: owner, EndpointID: "test", Machine: "test", Login: "test", ID: fid, Events: events}); err != nil {
		t.Fatal(err)
	}
	return store.HistoryHideManifest{Owner: owner, ID: fid, Seq: seq, Machine: "test", Login: "test", CheckedAt: now.Unix(), Online: true, Complete: true, Natives: natives, NativeEvidence: "absent_verified", Backups: "absent_verified", Inputs: "empty_verified", Evidence: "test reviewed placements"}
}

func historyCachePut(t *testing.T, s *Server, owner, key, sid string, at time.Time) []byte {
	t.Helper()
	sealed, err := s.Vault.SealPerson(chatMirrorDoc{Session: sid, Items: []json.RawMessage{}}, owner, chatMirrorPurpose)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Store.PutChatMirrorOf(owner, "view:"+key, sealed, at.Add(chatMirrorKeep), at); err != nil {
		t.Fatal(err)
	}
	return sealed
}

// Runs on SQLite AND the Postgres CI leg. Old key names are deliberately reused;
// only the decrypted native session is evidence. Counts reproduce the reviewed
// shape: 61 no-task candidates alongside 45 unrelated retained view copies.
func TestHistoryHideNativeCacheAttribution(t *testing.T) {
	s := historyCacheServer(t)
	now := time.Now()
	const owner = "gh:2718137"
	for i := 1; i <= 45; i++ {
		sid := fmt.Sprintf("native-%d", i)
		historyCacheRecord(t, s, owner, i, sid)
		historyCachePut(t, s, owner, fmt.Sprintf("old-fleet/scratch-%d", i), sid, now)
	}
	var candidates []store.HistoryHideManifest
	for i := 101; i <= 161; i++ {
		m := historyCacheRecord(t, s, owner, i, "")
		candidates = append(candidates, m)
		if err := s.Store.HideHistory(m, "admin", false, true, time.Now(), s.historyMirrorSession); err != nil {
			t.Fatalf("candidate %d: %v", i, err)
		}
	}
	hidden, err := s.Store.HiddenHistory(owner, s.historyMirrorSession)
	if err != nil || len(hidden) != 61 {
		t.Fatalf("hidden=%d err=%v", len(hidden), err)
	}
	var cacheCount int
	if err := s.Store.DB().QueryRow(`SELECT COUNT(*) FROM hub_chat_mirrors`).Scan(&cacheCount); err != nil || cacheCount != 45 {
		t.Fatalf("copies changed: %d %v", cacheCount, err)
	}
	// Undo changes visibility alone; it does not require caches or the vault.
	if err := s.Store.HideHistory(candidates[0], "admin", true, true, time.Now(), nil); err != nil {
		t.Fatal(err)
	}
	hidden, err = s.Store.HiddenHistory(owner, s.historyMirrorSession)
	if err != nil || len(hidden) != 60 {
		t.Fatalf("undo hidden=%d err=%v", len(hidden), err)
	}
	// A later unrelated cache does not expose hidden candidates.
	historyCachePut(t, s, owner, "new-key", "native-1", now.Add(time.Second))
	hidden, err = s.Store.HiddenHistory(owner, s.historyMirrorSession)
	if err != nil || len(hidden) != 60 {
		t.Fatalf("unrelated arrival: %d %v", len(hidden), err)
	}
}

func TestHistoryHideCacheRecheckAndUnknown(t *testing.T) {
	s := historyCacheServer(t)
	now := time.Now()
	const owner = "gh:2718137"
	m := historyCacheRecord(t, s, owner, 1, "native-kept")
	apply := func(apply bool) error {
		return s.Store.HideHistory(m, "admin", false, apply, time.Now(), s.historyMirrorSession)
	}
	if err := apply(false); err != nil {
		t.Fatal(err)
	}
	// A copy arriving between dry-run and apply must invalidate the earlier result.
	sealed := historyCachePut(t, s, owner, "old-fleet/scratch-1", "native-kept", now)
	if !errors.Is(apply(true), store.ErrHistoryEvidence) {
		t.Fatal("cache arriving after dry-run did not block apply")
	}
	copy, err := s.Store.ChatHistoryMirrorOf(owner, m.ID, now, s.historyMirrorSession)
	if err != nil || copy == nil || !bytes.Equal(copy.Sealed, sealed) {
		t.Fatalf("legacy copy lost: %v", err)
	}
	other := historyCacheRecord(t, s, "other", 2, "native-kept")
	if err := s.Store.HideHistory(other, "admin", false, true, time.Now(), s.historyMirrorSession); err != nil {
		t.Fatalf("foreign owner cache blocked: %v", err)
	}
	copy, err = s.Store.ChatHistoryMirrorOf("other", other.ID, now, s.historyMirrorSession)
	if err != nil || copy != nil {
		t.Fatal("foreign owner cache exposed")
	}
	for _, test := range []struct {
		name, sid string
		broken    bool
	}{
		{"empty session", "", false}, {"unknown SID", "unrecorded", false}, {"malformed ciphertext", "", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			ss := historyCacheServer(t)
			candidate := historyCacheRecord(t, ss, owner, 3, "")
			if err := ss.Store.HideHistory(candidate, "admin", false, true, time.Now(), ss.historyMirrorSession); err != nil {
				t.Fatal(err)
			}
			if test.broken {
				if err := ss.Store.PutChatMirrorOf(owner, "view:old/scratch-1", []byte("invalid"), now.Add(chatMirrorKeep), now); err != nil {
					t.Fatal(err)
				}
			} else {
				historyCachePut(t, ss, owner, "old/scratch-1", test.sid, now)
			}
			if err := ss.Store.HideHistory(candidate, "admin", false, true, time.Now(), ss.historyMirrorSession); !errors.Is(err, store.ErrHistoryEvidence) {
				t.Fatalf("unknown accepted: %v", err)
			}
			hidden, err := ss.Store.HiddenHistory(owner, ss.historyMirrorSession)
			if err != nil || hidden[candidate.ID] {
				t.Fatalf("uncertain cached history remained hidden: %v", err)
			}
		})
	}
	// Ambiguous owner SID mapping is never used as proof or as readable content.
	historyCacheRecord(t, s, owner, 4, "native-kept")
	copy, err = s.Store.ChatHistoryMirrorOf(owner, m.ID, now, s.historyMirrorSession)
	if err != nil || copy != nil {
		t.Fatal("ambiguous native mapping supplied a conversation")
	}
	if !errors.Is(apply(true), store.ErrHistoryEvidence) {
		t.Fatal("ambiguous native mapping allowed hide")
	}
}

func TestHistoryHideCacheArrivalSerialized(t *testing.T) {
	s := historyCacheServer(t)
	// Use two Store instances to exercise the database lock across replicas,
	// not just the one-connection write pool within a single process.
	path := filepath.Join(t.TempDir(), "shared.db")
	st, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	peer, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { peer.Close() })
	s.Store = st
	now := time.Now()
	const owner = "gh:2718137"
	m := historyCacheRecord(t, s, owner, 1, "target-native")
	// TestMainPostgres maps this SAME path to the SAME isolated schema for both
	// Stores. Assert shared data before testing cross-connection serialization.
	if rec, err := peer.FleetIDOf(owner, m.ID); err != nil || rec.ID != m.ID {
		t.Fatalf("peer Store is not on the same database/schema: %v", err)
	}
	historyCacheRecord(t, s, owner, 2, "unrelated-native")
	historyCachePut(t, s, owner, "old/scratch-1", "unrelated-native", now)
	// Pause while the hide inspects its transaction snapshot, then start a cache
	// write. It must wait for that transaction, and then restore board visibility.
	entered, release := make(chan struct{}), make(chan struct{})
	hideDone, putDone := make(chan error, 1), make(chan error, 1)
	decode := func(pid string, raw []byte) (string, error) {
		close(entered)
		<-release
		return s.historyMirrorSession(pid, raw)
	}
	go func() { hideDone <- s.Store.HideHistory(m, "admin", false, true, time.Now(), decode) }()
	select {
	case <-entered:
	case err := <-hideDone:
		t.Fatalf("hide failed before cache inspection: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("hide did not inspect cache")
	}
	sealed, err := s.Vault.SealPerson(chatMirrorDoc{Session: "target-native", Items: []json.RawMessage{}}, owner, chatMirrorPurpose)
	if err != nil {
		close(release)
		t.Fatal(err)
	}
	started := make(chan struct{})
	go func() {
		close(started)
		putDone <- peer.PutChatMirrorOf(owner, "view:legacy/scratch-2", sealed, now.Add(chatMirrorKeep), now)
	}()
	<-started
	select {
	case err := <-putDone:
		close(release)
		t.Fatalf("cache escaped hide snapshot: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	if err := <-hideDone; err != nil {
		t.Fatal(err)
	}
	if err := <-putDone; err != nil {
		t.Fatal(err)
	}
	hidden, err := s.Store.HiddenHistory(owner, s.historyMirrorSession)
	if err != nil || hidden[m.ID] {
		t.Fatalf("new relevant cache did not restore visibility: %v", err)
	}
}
