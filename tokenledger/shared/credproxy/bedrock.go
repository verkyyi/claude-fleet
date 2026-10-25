package credproxy

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Bedrock fallback (task PNWW): when a Claude Messages request cannot ride
// the subscription pool — the chosen account answered 429 (after the one
// rebind), or the hub found no account at all (claude_pool_unavailable) —
// the proxy asks the hub once (POST FallbackPath) whether this session may
// fall back to Amazon Bedrock. The hub says no unless its setting
// fleet.fallback.bedrock is "on", the person is not a trial person and the
// month's Bedrock spend is under fleet.fallback.bedrock.cap_usd; when it says
// yes it hands the pool's Bedrock key pair for this one request. The proxy
// then replays the SAME request body to Bedrock (InvokeModel /
// InvokeModelWithResponseStream, SigV4), translates Bedrock's event stream
// back into Anthropic SSE, and reports the usage with source "bedrock".
// Anything that goes wrong on the way (no mapping for the model, the hub
// says no, Bedrock refuses) answers the ORIGINAL error, unchanged.

// FallbackPath is the hub route the proxy asks (api.CredProxyFallbackPath).
const FallbackPath = "/v1/fleet/credproxy/fallback"

// SourceBedrock is a usage report's source for a request Bedrock served.
const SourceBedrock = "bedrock"

// Fallback is the hub's answer: OK with a key for this request, or a reason.
type Fallback struct {
	OK              bool   `json:"ok"`
	Reason          string `json:"reason,omitempty"`
	Principal       string `json:"principal,omitempty"`
	WorkerID        string `json:"worker_id,omitempty"`
	Account         string `json:"account,omitempty"`
	Region          string `json:"region,omitempty"`
	AccessKeyID     string `json:"access_key_id,omitempty"`
	SecretAccessKey string `json:"secret_access_key,omitempty"`
	SessionToken    string `json:"session_token,omitempty"`
}

// Fallbacker is a Resolver that can grant a Bedrock fallback.
type Fallbacker interface {
	Fallback(ctx context.Context, pass, provider, model string) (Fallback, error)
}

// Fallback asks the hub for a Bedrock key for one request.
func (h *HubResolver) Fallback(ctx context.Context, pass, provider, model string) (Fallback, error) {
	c := h.Client
	if c == nil {
		c = &http.Client{Timeout: 5 * time.Second}
	}
	body, _ := json.Marshal(map[string]string{"cred": pass, "provider": provider, "model": model})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(h.URL, "/")+FallbackPath, bytes.NewReader(body))
	if err != nil {
		return Fallback{}, err
	}
	req.Header.Set("Authorization", "Bearer "+h.Token)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.Do(req)
	if err != nil {
		return Fallback{}, fmt.Errorf("%w: %v", ErrHubUnavailable, err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	if res.StatusCode != http.StatusOK {
		return Fallback{}, fmt.Errorf("fallback: %d %s", res.StatusCode, firstLine(raw))
	}
	var f Fallback
	if err := json.Unmarshal(raw, &f); err != nil {
		return Fallback{}, fmt.Errorf("fallback: unreadable answer: %v", err)
	}
	return f, nil
}

// BedrockModels maps an Anthropic model id (date suffix dropped) to its
// Bedrock foundation-model id — the ONE table. The cross-region inference
// profile prefix (us. / eu. / apac.) is added from the key's region, so the
// table holds the bare ids. A model not here is never sent to Bedrock.
var BedrockModels = map[string]string{
	"claude-fable-5-1":  "anthropic.claude-fable-5-1",
	"claude-fable-5":    "anthropic.claude-fable-5",
	"claude-opus-5-5":   "anthropic.claude-opus-5-5",
	"claude-sonnet-5-5": "anthropic.claude-sonnet-5-5",
	"claude-haiku-5-5":  "anthropic.claude-haiku-5-5",
	"claude-opus-5":     "anthropic.claude-opus-5",
	"claude-sonnet-5":   "anthropic.claude-sonnet-5",
	"claude-opus-4-8":   "anthropic.claude-opus-4-8",
	"claude-opus-4-7":   "anthropic.claude-opus-4-7",
	"claude-opus-4-6":   "anthropic.claude-opus-4-6-v1",
	"claude-sonnet-4-6": "anthropic.claude-sonnet-4-6",
	"claude-opus-4-5":   "anthropic.claude-opus-4-5-20251101-v1:0",
	"claude-sonnet-4-5": "anthropic.claude-sonnet-4-5-20250929-v1:0",
	"claude-haiku-4-5":  "anthropic.claude-haiku-4-5-20251001-v1:0",
}

// bedrockBetas are the anthropic-beta values Bedrock takes (in the body's
// anthropic_beta); any other (oauth, claude-code) is dropped, never sent.
var bedrockBetas = map[string]bool{
	"interleaved-thinking-2025-05-14":        true,
	"context-1m-2025-08-07":                  true,
	"fine-grained-tool-streaming-2025-05-14": true,
	"token-efficient-tools-2025-02-19":       true,
	"output-128k-2025-02-19":                 true,
	"context-management-2025-06-27":          true,
	"computer-use-2025-01-24":                true,
	"tool-search-tool-2025-10-19":            true,
	"effort-2025-11-24":                      true,
}

var modelDate = regexp.MustCompile(`-(\d{8}|\d{4}-\d{2}-\d{2})$`)

// BedrockModelID is the id a model is invoked by in region ("" = not mapped).
func BedrockModelID(model, region string) string {
	base := modelDate.ReplaceAllString(strings.TrimSpace(model), "")
	if i := strings.IndexByte(base, '['); i >= 0 { // a client alias like [1m]
		base = base[:i]
	}
	id, ok := BedrockModels[base]
	if !ok {
		return ""
	}
	switch {
	case strings.HasPrefix(region, "us-"):
		return "us." + id
	case strings.HasPrefix(region, "eu-"):
		return "eu." + id
	case strings.HasPrefix(region, "ap-"):
		return "apac." + id
	}
	return id
}

// bedrockBody turns a Messages API body into Bedrock's: model and stream move
// to the URL, anthropic_version is Bedrock's, the betas ride in the body.
func bedrockBody(body []byte, betas []string) (out []byte, model string, stream bool, err error) {
	var v map[string]json.RawMessage
	if err := json.Unmarshal(body, &v); err != nil {
		return nil, "", false, err
	}
	_ = json.Unmarshal(v["model"], &model)
	_ = json.Unmarshal(v["stream"], &stream)
	for _, k := range []string{"model", "stream", "metadata", "service_tier"} {
		delete(v, k)
	}
	v["anthropic_version"] = json.RawMessage(`"bedrock-2023-05-31"`)
	var keep []string
	for _, b := range betas {
		if bedrockBetas[b] && !contains(keep, b) {
			keep = append(keep, b)
		}
	}
	if len(keep) > 0 {
		raw, _ := json.Marshal(keep)
		v["anthropic_beta"] = raw
	}
	out, err = json.Marshal(v)
	return out, model, stream, err
}

// awsEscape is RFC 3986 encoding, unreserved characters kept.
func awsEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func hmacSHA(key []byte, s string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(s))
	return m.Sum(nil)
}

// signV4 signs req (whose body is payload) for service in region, AWS
// Signature Version 4: every header named host, content-type or x-amz-* is
// signed. The canonical path is the request's escaped path encoded once more
// (every service but S3).
func signV4(req *http.Request, payload []byte, keyID, secret, token, region, service string, now time.Time) {
	amzDate := now.UTC().Format("20060102T150405Z")
	day := amzDate[:8]
	req.Header.Set("X-Amz-Date", amzDate)
	if token != "" {
		req.Header.Set("X-Amz-Security-Token", token)
	}
	hdr := map[string]string{"host": req.URL.Host}
	for k, vs := range req.Header {
		lk := strings.ToLower(k)
		if lk == "content-type" || strings.HasPrefix(lk, "x-amz-") {
			hdr[lk] = strings.TrimSpace(strings.Join(vs, ","))
		}
	}
	names := make([]string, 0, len(hdr))
	for k := range hdr {
		names = append(names, k)
	}
	sort.Strings(names)
	var ch strings.Builder
	for _, k := range names {
		ch.WriteString(k + ":" + hdr[k] + "\n")
	}
	signed := strings.Join(names, ";")
	segs := strings.Split(req.URL.EscapedPath(), "/")
	for i, s := range segs {
		segs[i] = awsEscape(s)
	}
	cpath := strings.Join(segs, "/")
	if cpath == "" {
		cpath = "/"
	}
	// query: sorted key=value, each encoded
	q := req.URL.Query()
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var qs []string
	for _, k := range keys {
		vs := append([]string(nil), q[k]...)
		sort.Strings(vs)
		for _, v := range vs {
			qs = append(qs, awsEscape(k)+"="+awsEscape(v))
		}
	}
	ph := sha256.Sum256(payload)
	creq := strings.Join([]string{req.Method, cpath, strings.Join(qs, "&"), ch.String(), signed, hex.EncodeToString(ph[:])}, "\n")
	ch2 := sha256.Sum256([]byte(creq))
	scope := day + "/" + region + "/" + service + "/aws4_request"
	sts := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(ch2[:])
	k := hmacSHA([]byte("AWS4"+secret), day)
	k = hmacSHA(k, region)
	k = hmacSHA(k, service)
	k = hmacSHA(k, "aws4_request")
	sig := hex.EncodeToString(hmacSHA(k, sts))
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+keyID+"/"+scope+", SignedHeaders="+signed+", Signature="+sig)
}

// bedrockBase is where a region's runtime answers (Config.BedrockURL wins:
// a test seam, or an operator's own endpoint).
func (p *Proxy) bedrockBase(region string) string {
	if p.cfg.BedrockURL != "" {
		return p.cfg.BedrockURL
	}
	return "https://bedrock-runtime." + region + ".amazonaws.com"
}

// fallbackEligible says whether a request may be replayed on Bedrock at all:
// a Claude Messages call.
func fallbackEligible(provider string, r *http.Request) bool {
	return provider == Claude && r.Method == http.MethodPost &&
		strings.TrimPrefix(r.URL.EscapedPath(), "/v1/proxy/anthropic") == "/v1/messages"
}

// tryBedrock replays the request on Bedrock and answers it there. false =
// nothing was written: the caller answers its original error. why is the
// audit's word for a fallback that did not happen ("" when none was asked).
func (p *Proxy) tryBedrock(w http.ResponseWriter, r *http.Request, pass string, body []byte, a *audit) bool {
	fb, ok := p.cfg.Resolver.(Fallbacker)
	if !ok || !fallbackEligible(Claude, r) {
		return false
	}
	if p.fallbackOff() {
		return false
	}
	var betas []string
	for _, v := range r.Header.Values("Anthropic-Beta") {
		for _, b := range strings.Split(v, ",") {
			if b = strings.TrimSpace(b); b != "" {
				betas = append(betas, b)
			}
		}
	}
	bbody, model, streaming, err := bedrockBody(body, betas)
	if err != nil || model == "" {
		a.fallback = "bedrock: unreadable body"
		return false
	}
	ctx := r.Context()
	g, err := fb.Fallback(ctx, pass, Claude, model)
	if err != nil {
		a.fallback = "bedrock: hub " + errClass(err)
		return false
	}
	if !g.OK {
		if g.Reason == "off" {
			p.noteFallbackOff()
		}
		a.fallback = "bedrock: " + g.Reason
		return false
	}
	region := g.Region
	if region == "" {
		region = "us-west-2"
	}
	id := BedrockModelID(model, region)
	if id == "" {
		a.fallback = "bedrock: no mapping for " + model
		return false
	}
	op := "invoke"
	if streaming {
		op = "invoke-with-response-stream"
	}
	target := p.bedrockBase(region) + "/model/" + awsEscape(id) + "/" + op
	out, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(bbody))
	if err != nil {
		a.fallback = "bedrock: bad target"
		return false
	}
	out.ContentLength = int64(len(bbody))
	out.Header.Set("Content-Type", "application/json")
	if streaming {
		out.Header.Set("Accept", "application/vnd.amazon.eventstream")
	} else {
		out.Header.Set("Accept", "application/json")
	}
	signV4(out, bbody, g.AccessKeyID, g.SecretAccessKey, g.SessionToken, region, "bedrock", p.cfg.Now())
	resp, err := p.cfg.Upstream.Do(out)
	if err != nil {
		a.fallback = "bedrock: upstream " + errClass(err)
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		a.fallback = fmt.Sprintf("bedrock: %d %s", resp.StatusCode, firstLine(raw))
		return false
	}
	a.fallback = "bedrock"
	a.route = "bedrock"
	a.fallbackFrom = a.account
	a.account = "pool/" + g.Account
	m := newMeter()
	if streaming {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)
		a.status = http.StatusOK
		a.out = bedrockStream(w, resp.Body, m)
	} else {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		a.status = http.StatusOK
		a.out = stream(w, io.TeeReader(resp.Body, m))
	}
	u := m.usage()
	a.tokens = u.Tokens()
	u.Model = model // priced as the model asked for, whatever Bedrock calls it
	u.Cred, u.Principal, u.WorkerID, u.Provider, u.Owner, u.Account = pass, g.Principal, g.WorkerID, Claude, "pool", g.Account
	u.Source = SourceBedrock
	p.report(u)
	return true
}

// fallbackOff / noteFallbackOff keep a hub's "off" for one cache life, so a
// pool at its limit does not ask the hub again on every 429.
func (p *Proxy) fallbackOff() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return !p.fbOffAt.IsZero() && p.cfg.Now().Sub(p.fbOffAt) < p.cfg.CacheTTL
}

func (p *Proxy) noteFallbackOff() {
	p.mu.Lock()
	p.fbOffAt = p.cfg.Now()
	p.mu.Unlock()
}

// errBadFrame is an event-stream frame that does not check out.
var errBadFrame = errors.New("bedrock: malformed event-stream frame")

// eventFrame is one decoded application/vnd.amazon.eventstream message.
type eventFrame struct {
	headers map[string]string
	payload []byte
}

// readFrame reads one frame: total length, headers length, prelude CRC,
// headers, payload, message CRC — both CRCs checked.
func readFrame(r io.Reader) (eventFrame, error) {
	var pre [12]byte
	if _, err := io.ReadFull(r, pre[:]); err != nil {
		return eventFrame{}, err
	}
	total := binary.BigEndian.Uint32(pre[0:4])
	hlen := binary.BigEndian.Uint32(pre[4:8])
	if crc32.ChecksumIEEE(pre[:8]) != binary.BigEndian.Uint32(pre[8:12]) || total < 16 || total > 16<<20 || hlen > total-16 {
		return eventFrame{}, errBadFrame
	}
	rest := make([]byte, total-12)
	if _, err := io.ReadFull(r, rest); err != nil {
		return eventFrame{}, err
	}
	msg := append(pre[:], rest[:len(rest)-4]...)
	if crc32.ChecksumIEEE(msg) != binary.BigEndian.Uint32(rest[len(rest)-4:]) {
		return eventFrame{}, errBadFrame
	}
	f := eventFrame{headers: map[string]string{}, payload: rest[hlen : len(rest)-4]}
	h := rest[:hlen]
	for len(h) > 0 {
		n := int(h[0])
		if len(h) < 2+n {
			return eventFrame{}, errBadFrame
		}
		name := string(h[1 : 1+n])
		typ := h[1+n]
		h = h[2+n:]
		size := map[byte]int{0: 0, 1: 0, 2: 1, 3: 2, 4: 4, 5: 8, 8: 8, 9: 16}
		switch typ {
		case 6, 7:
			if len(h) < 2 {
				return eventFrame{}, errBadFrame
			}
			l := int(binary.BigEndian.Uint16(h[:2]))
			if len(h) < 2+l {
				return eventFrame{}, errBadFrame
			}
			if typ == 7 {
				f.headers[name] = string(h[2 : 2+l])
			}
			h = h[2+l:]
		default:
			sz, ok := size[typ]
			if !ok || len(h) < sz {
				return eventFrame{}, errBadFrame
			}
			h = h[sz:]
		}
	}
	return f, nil
}

// EncodeFrame is one event-stream message with string headers — what Bedrock
// sends; tests build their fake answers with it.
func EncodeFrame(headers map[string]string, payload []byte) []byte {
	var hb bytes.Buffer
	names := make([]string, 0, len(headers))
	for k := range headers {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		hb.WriteByte(byte(len(k)))
		hb.WriteString(k)
		hb.WriteByte(7)
		var l [2]byte
		binary.BigEndian.PutUint16(l[:], uint16(len(headers[k])))
		hb.Write(l[:])
		hb.WriteString(headers[k])
	}
	total := 12 + hb.Len() + len(payload) + 4
	out := make([]byte, 0, total)
	out = binary.BigEndian.AppendUint32(out, uint32(total))
	out = binary.BigEndian.AppendUint32(out, uint32(hb.Len()))
	out = binary.BigEndian.AppendUint32(out, crc32.ChecksumIEEE(out[:8]))
	out = append(out, hb.Bytes()...)
	out = append(out, payload...)
	return binary.BigEndian.AppendUint32(out, crc32.ChecksumIEEE(out))
}

// bedrockStream turns Bedrock's event stream into Anthropic SSE, flushing
// each event, the meter reading the SSE as it would Anthropic's own. An
// exception frame (or a broken stream) ends the answer with an SSE error.
func bedrockStream(w http.ResponseWriter, body io.Reader, m *meter) int64 {
	f, _ := w.(http.Flusher)
	var n int64
	emit := func(typ string, data []byte) bool {
		line := []byte("event: " + typ + "\ndata: ")
		line = append(append(line, data...), '\n', '\n')
		_, _ = m.Write(line)
		k, err := w.Write(line)
		n += int64(k)
		if f != nil {
			f.Flush()
		}
		return err == nil
	}
	fail := func(typ, msg string) {
		e, _ := json.Marshal(map[string]any{"type": "error", "error": map[string]string{"type": typ, "message": msg}})
		emit("error", e)
	}
	for {
		fr, err := readFrame(body)
		if err == io.EOF {
			return n
		}
		if err != nil {
			fail("api_error", "the Bedrock stream broke off")
			return n
		}
		if fr.headers[":message-type"] == "exception" {
			typ := "api_error"
			switch fr.headers[":exception-type"] {
			case "throttlingException", "serviceUnavailableException":
				typ = "overloaded_error"
			case "validationException":
				typ = "invalid_request_error"
			}
			var e struct {
				Message string `json:"message"`
			}
			_ = json.Unmarshal(fr.payload, &e)
			fail(typ, "Bedrock: "+e.Message)
			return n
		}
		if fr.headers[":event-type"] != "chunk" {
			continue
		}
		var c struct {
			Bytes string `json:"bytes"`
		}
		if json.Unmarshal(fr.payload, &c) != nil {
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(c.Bytes)
		if err != nil {
			continue
		}
		var ev map[string]json.RawMessage
		if json.Unmarshal(raw, &ev) != nil {
			continue
		}
		var typ string
		_ = json.Unmarshal(ev["type"], &typ)
		if typ == "" {
			continue
		}
		if _, ok := ev["amazon-bedrock-invocationMetrics"]; ok {
			delete(ev, "amazon-bedrock-invocationMetrics")
			raw, _ = json.Marshal(ev)
		}
		if !emit(typ, raw) {
			return n
		}
	}
}
