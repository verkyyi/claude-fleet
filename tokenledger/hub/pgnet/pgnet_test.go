package pgnet

import (
	"context"
	"net"
	"runtime"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// TestApplyDialsWithUserTimeout: a connection made through Apply's DialFunc
// carries TCP_USER_TIMEOUT (on Linux, where the hub runs) and a connect
// timeout when the URL set none.
func TestApplyDialsWithUserTimeout(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			defer c.Close()
		}
	}()
	cfg, err := pgconn.ParseConfig("postgres://u@" + ln.Addr().String() + "/db?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnectTimeout = 0
	Apply(cfg)
	if cfg.ConnectTimeout != ConnectTimeout {
		t.Fatalf("connect timeout %v, want %v", cfg.ConnectTimeout, ConnectTimeout)
	}
	c, err := cfg.DialFunc(context.Background(), "tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if runtime.GOOS != "linux" {
		t.Skip("TCP_USER_TIMEOUT is Linux only; the dial itself worked")
	}
	raw, err := c.(*net.TCPConn).SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var got time.Duration
	var gerr error
	if err := raw.Control(func(fd uintptr) { got, gerr = UserTimeoutOf(fd) }); err != nil {
		t.Fatal(err)
	}
	if gerr != nil || got != UserTimeout {
		t.Fatalf("TCP_USER_TIMEOUT = %v (%v), want %v", got, gerr, UserTimeout)
	}
	var ka int
	_ = raw.Control(func(fd uintptr) { ka, _ = syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_KEEPALIVE) })
	if ka == 0 {
		t.Fatal("SO_KEEPALIVE is off")
	}
}

// TestUserTimeoutEnv: CCQUOTA_DB_TCP_USER_TIMEOUT overrides, "0" turns it off,
// garbage keeps the default.
func TestUserTimeoutEnv(t *testing.T) {
	for v, want := range map[string]time.Duration{"": UserTimeout, "12s": 12 * time.Second, "0": 0, "nope": UserTimeout} {
		t.Setenv("CCQUOTA_DB_TCP_USER_TIMEOUT", v)
		if got := userTimeout(); got != want {
			t.Errorf("%q: %v, want %v", v, got, want)
		}
	}
}
