package api

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"net/url"
	"strings"
	"time"
)

// The hub's one way to send a mail (claude-fleet#3604): plain SMTP, from
// CCQUOTA_SMTP_URL — smtp://user:pass@host:587 (STARTTLS, required) or
// smtps://user:pass@host:465 (TLS from the first byte). Today that is Amazon
// SES's SMTP interface; another provider is another URL, never another
// client. The URL carries the credentials, so it lives in the hub's Secret
// only and is never logged — a log line names the host at most.
//
// The sender is CCQUOTA_SMTP_FROM, else the URL's ?from=: an address on the
// domain whose SPF, DKIM and DMARC the provider was set up for.

// smtpConf is CCQUOTA_SMTP_URL, read.
type smtpConf struct {
	host     string // host:port
	implicit bool   // smtps: TLS before the first byte
	user     string
	pass     string
	from     *mail.Address
}

// parseSMTP reads an SMTP URL and the sender (from, else the URL's ?from=).
// Its errors never quote the URL.
func parseSMTP(raw, from string) (*smtpConf, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return nil, errors.New("CCQUOTA_SMTP_URL is not a URL like smtp://user:pass@host:587")
	}
	c := &smtpConf{}
	port := "587"
	switch u.Scheme {
	case "smtp":
	case "smtps":
		c.implicit, port = true, "465"
	default:
		return nil, errors.New("CCQUOTA_SMTP_URL must start smtp:// or smtps://")
	}
	host := u.Hostname()
	if u.Port() != "" {
		port = u.Port()
	}
	c.host = net.JoinHostPort(host, port)
	if u.User != nil {
		c.user = u.User.Username()
		c.pass, _ = u.User.Password()
	}
	if from = strings.TrimSpace(from); from == "" {
		from = u.Query().Get("from")
	}
	if from == "" {
		return nil, errors.New("no sender: set CCQUOTA_SMTP_FROM (or ?from= on CCQUOTA_SMTP_URL)")
	}
	if c.from, err = mail.ParseAddress(from); err != nil {
		return nil, fmt.Errorf("the sender %q is not an address", from)
	}
	return c, nil
}

// hostName is the server's name, for TLS and for a log line.
func (c *smtpConf) hostName() string {
	h, _, _ := net.SplitHostPort(c.host)
	return h
}

// send delivers one plain-text mail.
func (c *smtpConf) send(ctx context.Context, to, subject, body string) error {
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(30 * time.Second)
	}
	d := net.Dialer{Deadline: deadline}
	tcfg := &tls.Config{ServerName: c.hostName(), MinVersion: tls.VersionTLS12}
	var conn net.Conn
	var err error
	if c.implicit {
		conn, err = tls.DialWithDialer(&d, "tcp", c.host, tcfg)
	} else {
		conn, err = d.DialContext(ctx, "tcp", c.host)
	}
	if err != nil {
		return fmt.Errorf("smtp %s: %w", c.hostName(), err)
	}
	_ = conn.SetDeadline(deadline)
	cl, err := smtp.NewClient(conn, c.hostName())
	if err != nil {
		conn.Close()
		return fmt.Errorf("smtp %s: %w", c.hostName(), err)
	}
	defer cl.Close()
	if !c.implicit {
		// Credentials and the code never cross the wire in the clear.
		if ok, _ := cl.Extension("STARTTLS"); !ok {
			return fmt.Errorf("smtp %s offers no STARTTLS", c.hostName())
		}
		if err := cl.StartTLS(tcfg); err != nil {
			return fmt.Errorf("smtp %s: starttls: %w", c.hostName(), err)
		}
	}
	if c.user != "" {
		if err := cl.Auth(smtp.PlainAuth("", c.user, c.pass, c.hostName())); err != nil {
			return fmt.Errorf("smtp %s: auth refused", c.hostName())
		}
	}
	if err := cl.Mail(c.from.Address); err != nil {
		return fmt.Errorf("smtp %s: MAIL FROM: %w", c.hostName(), err)
	}
	if err := cl.Rcpt(to); err != nil {
		return fmt.Errorf("smtp %s: RCPT TO refused", c.hostName())
	}
	wc, err := cl.Data()
	if err != nil {
		return fmt.Errorf("smtp %s: DATA: %w", c.hostName(), err)
	}
	if _, err := wc.Write(buildMail(c.from, to, subject, body, time.Now())); err != nil {
		return fmt.Errorf("smtp %s: %w", c.hostName(), err)
	}
	if err := wc.Close(); err != nil {
		return fmt.Errorf("smtp %s: %w", c.hostName(), err)
	}
	return cl.Quit()
}

// buildMail is one RFC 5322 message: UTF-8 text, base64, a subject encoded
// for any client.
func buildMail(from *mail.Address, to, subject, body string, now time.Time) []byte {
	var id [12]byte
	_, _ = rand.Read(id[:])
	domain := from.Address[strings.LastIndex(from.Address, "@")+1:]
	var b strings.Builder
	b.WriteString("From: " + from.String() + "\r\n")
	b.WriteString("To: " + to + "\r\n")
	b.WriteString("Subject: " + mime.BEncoding.Encode("utf-8", subject) + "\r\n")
	b.WriteString("Date: " + now.Format(time.RFC1123Z) + "\r\n")
	b.WriteString("Message-ID: <" + hex.EncodeToString(id[:]) + "@" + domain + ">\r\n")
	b.WriteString("MIME-Version: 1.0\r\n")
	b.WriteString("Content-Type: text/plain; charset=utf-8\r\n")
	b.WriteString("Content-Transfer-Encoding: base64\r\n")
	// Not a list, not a reply target: auto-responders stay quiet.
	b.WriteString("Auto-Submitted: auto-generated\r\n\r\n")
	enc := base64.StdEncoding.EncodeToString([]byte(body))
	for len(enc) > 76 {
		b.WriteString(enc[:76] + "\r\n")
		enc = enc[76:]
	}
	b.WriteString(enc + "\r\n")
	return []byte(b.String())
}
