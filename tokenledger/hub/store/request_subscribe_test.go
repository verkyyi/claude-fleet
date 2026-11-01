package store

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRequestSubscribeConsumedOnce(t *testing.T) {
	s := newStore(t)
	_, err := s.Requests().Create(AccessRequest{ID: "rq-sub", Kind: IdentityWeChat, Subject: "union-sub", Display: "Applicant", Use: "A software access application", NotifyChannel: NotifyWeChat, CreatedAt: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := s.GrantRequestSubscribe("rq-sub", IdentityWeChat, "other", "other-openid", "tpl"); err != nil || ok {
		t.Fatalf("other applicant %v %v", ok, err)
	}
	if ok, err := s.GrantRequestSubscribe("rq-sub", IdentityWeChat, "union-sub", "openid", "tpl"); err != nil || !ok {
		t.Fatalf("grant %v %v", ok, err)
	}
	var wg sync.WaitGroup
	var claimed atomic.Int32
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id, err := s.ClaimRequestSubscribe("rq-sub", "tpl")
			if err != nil {
				t.Error(err)
			}
			if id != "" {
				if id != "openid" {
					t.Errorf("wrong recipient %s", id)
				}
				claimed.Add(1)
			}
		}()
	}
	wg.Wait()
	if claimed.Load() != 1 {
		t.Fatalf("claimed %d times", claimed.Load())
	}
	if ok, err := s.GrantRequestSubscribe("rq-sub", IdentityWeChat, "union-sub", "openid", "tpl"); err != nil || ok {
		t.Fatalf("rearmed %v %v", ok, err)
	}
	if id, err := s.ClaimRequestSubscribe("different-request", "tpl"); err != nil || id != "" {
		t.Fatalf("cross-request grant %q %v", id, err)
	}
}
