package store

import (
	"errors"
	"testing"
	"time"
)

func TestTrialQuotaKey(t *testing.T) {
	for in, want := range map[string]string{
		"Alice@Example.com":              "alice@example.com",
		"alice+trial1@example.com":       "alice@example.com",
		"a.l.i.c.e+x@gmail.com":          "alice@gmail.com",
		"A.Lice@GoogleMail.com":          "alice@gmail.com",
		"a.lice@example.com":             "a.lice@example.com", // dots count outside Gmail
		"+tag@example.com":               "+tag@example.com",   // nothing before the tag: kept
		"not-an-address":                 "not-an-address",
		"  bob+1@example.com  ":          "bob@example.com",
		"carol+a+b@sub.example.com":      "carol@sub.example.com",
		"d.ave@gmail.com.example.com":    "d.ave@gmail.com.example.com",
		"plain@gmail.com":                "plain@gmail.com",
		"under_score+z@example.co.uk":    "under_score@example.co.uk",
		"UPPER.CASE+Tag@GMAIL.COM":       "uppercase@gmail.com",
		"x@googlemail.com":               "x@gmail.com",
		"y.y+@gmail.com":                 "yy@gmail.com",
		"zed@example.com":                "zed@example.com",
		"first.last+news@googlemail.com": "firstlast@gmail.com",
	} {
		if got := TrialQuotaKey(IdentityEmail, in); got != want {
			t.Errorf("TrialQuotaKey(%q) = %q; want %q", in, got, want)
		}
	}
	// other kinds, and the login identity itself, are untouched
	if got := TrialQuotaKey(IdentityWeChat, " o+1.x "); got != "o+1.x" {
		t.Errorf("wechat subject changed: %q", got)
	}
	if got := NormIdentitySubject(IdentityEmail, "A.B+x@Gmail.com"); got != "a.b+x@gmail.com" {
		t.Errorf("NormIdentitySubject changed: %q", got)
	}
}

// One mailbox, one trial: an alias of an address that already has a trial is
// refused for another person; the holder's own row, and other mailboxes, are not.
func TestStartTrialAsRefusesAnAlias(t *testing.T) {
	s := newStore(t)
	if err := s.ensureFleetTrials(); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if err := s.StartTrialAs("p-1", IdentityEmail, "first.last@gmail.com", now); err != nil {
		t.Fatal(err)
	}
	for _, alias := range []string{"firstlast@gmail.com", "first.last+2@gmail.com", "f.irst.last@googlemail.com"} {
		if err := s.StartTrialAs("p-2", IdentityEmail, alias, now); !errors.Is(err, ErrTrialWayTaken) {
			t.Fatalf("%s: %v; want ErrTrialWayTaken", alias, err)
		}
	}
	if err := s.StartTrialAs("p-1", IdentityEmail, "firstlast+again@gmail.com", now); err != nil {
		t.Fatalf("the holder: %v", err)
	}
	if err := s.StartTrialAs("p-3", IdentityEmail, "first.last@example.com", now); err != nil {
		t.Fatalf("another mailbox: %v", err)
	}
	if err := s.StartTrialAs("p-4", IdentityEmail, "first.last+x@example.com", now); !errors.Is(err, ErrTrialWayTaken) {
		t.Fatalf("+tag on another domain: %v", err)
	}
	if tr, err := s.Trial("p-1"); err != nil || tr == nil || tr.Subject != "first.last@gmail.com" {
		t.Fatalf("the row keeps the address as signed in with: %+v %v", tr, err)
	}
}
