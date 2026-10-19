package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// `ccquota notify "<message>"` — the hub's FLEET_NOTIFY_CMD (claude-fleet#4086).
//
// The hub runs `<FLEET_NOTIFY_CMD> "<message>"` with no shell (svc_degraded,
// claude-fleet#4007). Its image is alpine with no python3 or curl, so the
// node's extras/wecom-webhook-notify.sh cannot run there; the image ships
// /usr/local/bin/fleet-hub-notify, which execs this. Where the message goes is
// read from the environment only — the overlay takes the key from a Secret,
// so it is never in a manifest, an argv or a log:
//
//	FLEET_NOTIFY_KF_URL + FLEET_NOTIFY_KF_KEY   a kf-notify service (POST /v1/notify,
//	    Bearer key): FLEET_NOTIFY_KF_DEST (default person), FLEET_NOTIFY_KF_TO
//	    (the recipient an app dest needs), FLEET_NOTIFY_KF_SOURCE (default
//	    fleet:hub), FLEET_NOTIFY_KF_SEVERITY (default error)
//	FLEET_NOTIFY_WEBHOOK                       else a robot webhook (https only):
//	    WeCom · Feishu / Lark · Bark by host, anything else {"text": …}
//
// Neither set, or no message ⇒ nothing sent, exit 0.

const notifyTimeout = 10 * time.Second

// notifyRequest is the one HTTP call a message becomes; nil = nothing to send.
type notifyRequest struct {
	url  string
	auth string // the Authorization header, or ""
	body []byte
}

func notifyPlan(getenv func(string) string, msg string) (*notifyRequest, error) {
	msg = strings.TrimSpace(msg)
	if msg == "" {
		return nil, nil
	}
	title, rest, _ := strings.Cut(msg, "\n")
	title = strings.TrimSpace(title)
	if r := []rune(title); len(r) > 80 {
		title = string(r[:80])
	}
	if kf := strings.TrimSpace(getenv("FLEET_NOTIFY_KF_URL")); kf != "" {
		key := strings.TrimSpace(getenv("FLEET_NOTIFY_KF_KEY"))
		if key == "" {
			return nil, errors.New("FLEET_NOTIFY_KF_URL is set but FLEET_NOTIFY_KF_KEY is not")
		}
		u, err := url.Parse(kf)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return nil, errors.New("FLEET_NOTIFY_KF_URL is not http(s)://host")
		}
		or := func(k, d string) string {
			if v := strings.TrimSpace(getenv(k)); v != "" {
				return v
			}
			return d
		}
		sum := sha256.Sum256([]byte(title))
		in := map[string]string{
			"dest": or("FLEET_NOTIFY_KF_DEST", "person"), "title": title, "body": strings.TrimSpace(rest),
			"source": or("FLEET_NOTIFY_KF_SOURCE", "fleet:hub"), "severity": or("FLEET_NOTIFY_KF_SEVERITY", "error"),
			"dedupKey": "fleet:" + hex.EncodeToString(sum[:8]),
		}
		if in["body"] == "" {
			in["body"] = title
		}
		if to := strings.TrimSpace(getenv("FLEET_NOTIFY_KF_TO")); to != "" {
			in["to"] = to
		}
		b, _ := json.Marshal(in)
		return &notifyRequest{url: strings.TrimRight(kf, "/") + "/v1/notify", auth: "Bearer " + key, body: b}, nil
	}
	hook := strings.TrimSpace(getenv("FLEET_NOTIFY_WEBHOOK"))
	if hook == "" {
		return nil, nil
	}
	u, err := url.Parse(hook)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return nil, errors.New("FLEET_NOTIFY_WEBHOOK is not https://")
	}
	var v any
	switch u.Hostname() {
	case "qyapi.weixin.qq.com":
		v = map[string]any{"msgtype": "markdown", "markdown": map[string]string{"content": msg}}
	case "open.feishu.cn", "open.larksuite.com":
		v = map[string]any{"msg_type": "text", "content": map[string]string{"text": msg}}
	case "api.day.app":
		v = map[string]string{"title": title, "body": msg, "group": "fleet"}
	default:
		v = map[string]string{"text": msg}
	}
	b, _ := json.Marshal(v)
	return &notifyRequest{url: hook, body: b}, nil
}

// notifySend posts r once. The error names the host, never the address or key.
func notifySend(ctx context.Context, c *http.Client, r *notifyRequest) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.url, bytes.NewReader(r.body))
	if err != nil {
		return errors.New("the notify address is malformed")
	}
	host := req.URL.Host
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	if r.auth != "" {
		req.Header.Set("Authorization", r.auth)
	}
	resp, err := c.Do(req)
	if err != nil {
		return fmt.Errorf("%s did not answer", host)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s answered HTTP %d: %s", host, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return nil
}

func runNotify(args []string) error {
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}
	r, err := notifyPlan(os.Getenv, strings.Join(args, " "))
	if err != nil || r == nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), notifyTimeout)
	defer cancel()
	return notifySend(ctx, &http.Client{Timeout: notifyTimeout}, r)
}
