package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/verkyyi/ccquota/internal/api"
)

// HTTPS from the tailnet's own certificates.
//
// `tailscale cert <magicdns-name>` obtains a real Let's Encrypt certificate
// for this node's name (DNS-01, handled by Tailscale) and renews it when
// needed. The hub serves it directly, so the URL is https://<node>.<tailnet>.ts.net
// with no proxy in front -- which matters, because the tailnet-identity gate
// needs to see the real peer address, and a proxy would hide it.
//
// Renewal is the hub's job: the certificate is re-requested every 12 hours,
// which is a no-op until it is close to expiry. A failed renewal keeps the
// certificate already loaded; only starting with none at all is fatal.

type tailscaleCert struct {
	host string
	dir  string
	// issue runs the CLI; tests substitute a self-signed writer.
	issue func(host, certFile, keyFile string) error

	mu   sync.RWMutex
	cert *tls.Certificate
}

func newTailscaleCert(bin, host, dir string) *tailscaleCert {
	return &tailscaleCert{host: host, dir: dir, issue: func(host, cf, kf string) error {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, bin, "cert", "--cert-file", cf, "--key-file", kf, host).CombinedOutput()
		if err != nil {
			return fmt.Errorf("tailscale cert %s: %v: %s", host, err, out)
		}
		return nil
	}}
}

func (c *tailscaleCert) files() (string, string) {
	return filepath.Join(c.dir, c.host+".crt"), filepath.Join(c.dir, c.host+".key")
}

// refresh (re)issues and loads the pair. On failure the previously loaded
// certificate stays in service.
func (c *tailscaleCert) refresh() error {
	if err := os.MkdirAll(c.dir, 0o700); err != nil {
		return err
	}
	cf, kf := c.files()
	if err := c.issue(c.host, cf, kf); err != nil {
		return err
	}
	_ = os.Chmod(kf, 0o600)
	pair, err := tls.LoadX509KeyPair(cf, kf)
	if err != nil {
		return fmt.Errorf("load %s: %w", cf, err)
	}
	if pair.Leaf == nil && len(pair.Certificate) > 0 {
		pair.Leaf, _ = x509.ParseCertificate(pair.Certificate[0])
	}
	c.mu.Lock()
	c.cert = &pair
	c.mu.Unlock()
	if pair.Leaf != nil {
		log.Printf("tls: serving %s, expires %s", c.host, pair.Leaf.NotAfter.Format(time.RFC3339))
	}
	return nil
}

func (c *tailscaleCert) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.cert == nil {
		return nil, errors.New("no certificate loaded")
	}
	return c.cert, nil
}

// renewLoop re-requests the certificate on a schedule until ctx ends.
func (c *tailscaleCert) renewLoop(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := c.refresh(); err != nil {
				log.Printf("tls: renewal failed, keeping the current certificate: %v", err)
			}
		}
	}
}

// magicDNSName reads this node's HTTPS-capable name from `tailscale status
// --json`. CertDomains is empty when HTTPS is not enabled on the tailnet.
func magicDNSName(statusJSON []byte) (string, error) {
	var v struct {
		Self struct {
			DNSName string `json:"DNSName"`
		} `json:"Self"`
		CertDomains []string `json:"CertDomains"`
	}
	if err := json.Unmarshal(statusJSON, &v); err != nil {
		return "", err
	}
	if len(v.CertDomains) == 0 {
		return "", errors.New("this tailnet has no HTTPS certificate domains; enable HTTPS in the Tailscale admin console (DNS → HTTPS Certificates)")
	}
	return v.CertDomains[0], nil
}

func detectMagicDNSName(bin string) (string, error) {
	out, err := exec.Command(bin, "status", "--json").Output()
	if err != nil {
		return "", fmt.Errorf("tailscale status: %w", err)
	}
	return magicDNSName(out)
}

// tailnetOnly is a listener that refuses everyone but tailnet peers and the
// machine itself, before TLS even begins.
//
// It exists because of a macOS rule: an unprivileged process may bind a
// privileged port on the WILDCARD address but not on a specific one. So the
// HTTPS listener has to sit on 0.0.0.0:443 to be reachable at all, and this is
// what keeps "tailnet only" true anyway -- a LAN neighbour's connection is
// closed at accept, never answered.
type tailnetOnly struct{ net.Listener }

func (l tailnetOnly) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		if peerAllowed(c.RemoteAddr().String()) {
			return c, nil
		}
		c.Close()
	}
}

func peerAllowed(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		return false
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	ip = ip.Unmap()
	return ip.IsLoopback() || api.IsTailnetAddr(ip)
}
