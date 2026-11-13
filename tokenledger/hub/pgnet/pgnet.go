// Package pgnet is how every hub connection to Postgres is dialled (task N9GH).
//
// On 2026-11-13 a libc upgrade on the k3s box restarted systemd-networkd,
// which deleted and re-added the box's DHCP address; the kernel's MASQUERADE
// forgot the NAT state of every connection leaving through it, so the hub
// pods' OPEN connections to RDS stopped getting replies, with no error at
// all; new ones worked. The connections had no keepalive and no TCP_USER_TIMEOUT, so every
// request — /readyz included — blocked until the kernel gave up retransmitting
// (tcp_retries2=15: ~15.5 minutes) and the hub was down for 16.
//
// Apply bounds a dead connection to about UserTimeout instead:
//
//   - TCP keepalive (Idle 4 s, Interval 2 s, Count 3): an idle connection —
//     including one blocked reading a reply that will never come, with nothing
//     unacknowledged in flight — is probed and declared dead;
//   - TCP_USER_TIMEOUT (UserTimeout, Linux): data sent and not acknowledged for
//     that long errors the connection, and it caps the keepalive probes too;
//   - a connect timeout, when the URL did not set one.
//
// The error reaches whatever call was blocked on the socket, pgx marks the
// connection closed, and database/sql's pool never hands it out again
// (pgx stdlib's IsValid / ResetSession refuse a closed connection).
package pgnet

import (
	"context"
	"net"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// UserTimeout is the longest a Postgres connection may sit on unacknowledged
// data (or unanswered keepalive probes) before the kernel errors it.
// CCQUOTA_DB_TCP_USER_TIMEOUT (a Go duration) overrides it; "0" turns the
// option off.
//
// 10 s (30 s before): the database is in the hub's own region, a reply takes
// milliseconds, and a stream that has acknowledged nothing for 10 s is gone —
// on the box a networkd restart dropped the NAT state of every open
// connection, and each such stall cost the whole hub this long (task N9GH,
// measured on 2026-11-13: 4 stalls of ~30 s each).
var UserTimeout = 10 * time.Second

// Keepalive is the probe schedule: first probe after Idle with nothing on the
// wire, then every Interval, dead after Count unanswered — 4 + 3×2 = 10 s.
var Keepalive = net.KeepAliveConfig{Enable: true, Idle: 4 * time.Second, Interval: 2 * time.Second, Count: 3}

// ConnectTimeout bounds a new connection's dial when the URL sets no
// connect_timeout.
const ConnectTimeout = 10 * time.Second

// userTimeout is UserTimeout after the environment's override.
func userTimeout() time.Duration {
	if v := os.Getenv("CCQUOTA_DB_TCP_USER_TIMEOUT"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d >= 0 {
			return d
		}
	}
	return UserTimeout
}

// Dialer is the dialer Apply installs: keepalive on, TCP_USER_TIMEOUT set on
// the socket before it connects.
func Dialer(connectTimeout time.Duration) *net.Dialer {
	ut := userTimeout()
	return &net.Dialer{
		Timeout:         connectTimeout,
		KeepAliveConfig: Keepalive,
		Control: func(network, address string, c syscallRawConn) error {
			if ut <= 0 {
				return nil
			}
			var serr error
			if err := c.Control(func(fd uintptr) { serr = setUserTimeout(fd, ut) }); err != nil {
				return err
			}
			return serr
		},
	}
}

// Apply makes cfg (and each fallback it tries) dial through Dialer.
func Apply(cfg *pgconn.Config) {
	ct := cfg.ConnectTimeout
	if ct <= 0 {
		ct = ConnectTimeout
		cfg.ConnectTimeout = ct
	}
	d := Dialer(ct)
	cfg.DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return d.DialContext(ctx, network, addr)
	}
}
