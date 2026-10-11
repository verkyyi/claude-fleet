package dns

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// DNSPodURL is the legacy DNSPod API (token auth: login_token=<id>,<key>).
const DNSPodURL = "https://dnsapi.cn/"

// dnspodLine is the line every record answers on: the default one.
const dnspodLine = "默认"

// dnspodPage is how many records one Record.List asks for (its cap is 3000).
const dnspodPage = 3000

// DNSPod is Provider on the legacy DNSPod API: Record.List / Record.Create
// (+ Record.Remark, which marks it ours) / Record.Modify / Record.Remove.
// The token goes in each POST body only — never a URL, never a log line,
// never an error.
type DNSPod struct {
	Config
	URL    string       // DNSPodURL; a test's server
	Client *http.Client // nil: 15 s timeout
}

// NewDNSPod is the provider for c.
func NewDNSPod(c Config) *DNSPod { return &DNSPod{Config: c} }

type dnspodStatus struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type dnspodRecord struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Type   string `json:"type"`
	Value  string `json:"value"`
	TTL    string `json:"ttl"`
	Remark string `json:"remark"`
}

// call POSTs action with form + the common parameters and decodes the
// answer into out; a status other than "1" is an error (its code and
// message — DNSPod's words, which never carry the token).
func (p *DNSPod) call(ctx context.Context, action string, form url.Values, out any) (dnspodStatus, error) {
	base := p.URL
	if base == "" {
		base = DNSPodURL
	}
	form.Set("login_token", p.ID+","+p.Key)
	form.Set("format", "json")
	form.Set("lang", "en")
	form.Set("error_on_empty", "no")
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(base, "/")+"/"+action, strings.NewReader(form.Encode()))
	if err != nil {
		return dnspodStatus{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// DNSPod asks every caller to name itself and a contact.
	req.Header.Set("User-Agent", "claude-fleet-hub/1.0 (fleet@24haowan.com)")
	cl := p.Client
	if cl == nil {
		cl = &http.Client{Timeout: 15 * time.Second}
	}
	resp, err := cl.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err // the URL carries no token, but say less
		}
		return dnspodStatus{}, fmt.Errorf("dnspod %s: %w", action, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return dnspodStatus{}, fmt.Errorf("dnspod %s: %w", action, err)
	}
	if resp.StatusCode != http.StatusOK {
		return dnspodStatus{}, fmt.Errorf("dnspod %s: HTTP %d", action, resp.StatusCode)
	}
	var st struct {
		Status dnspodStatus `json:"status"`
	}
	if err := json.Unmarshal(body, &st); err != nil {
		return dnspodStatus{}, fmt.Errorf("dnspod %s: unreadable answer", action)
	}
	if st.Status.Code != "1" {
		return st.Status, fmt.Errorf("dnspod %s: code %s: %s", action, st.Status.Code, st.Status.Message)
	}
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			return st.Status, fmt.Errorf("dnspod %s: unreadable answer", action)
		}
	}
	return st.Status, nil
}

// List is every marked A / AAAA record under the subdomain.
func (p *DNSPod) List(ctx context.Context) ([]Record, error) {
	out := []Record{}
	for off := 0; ; off += dnspodPage {
		form := url.Values{"domain": {p.Domain}, "offset": {strconv.Itoa(off)}, "length": {strconv.Itoa(dnspodPage)}}
		var ans struct {
			Info struct {
				RecordTotal string `json:"record_total"`
			} `json:"info"`
			Records []dnspodRecord `json:"records"`
		}
		st, err := p.call(ctx, "Record.List", form, &ans)
		if err != nil {
			if st.Code == "10" { // no records at all
				return out, nil
			}
			return nil, err
		}
		for _, r := range ans.Records {
			if r.Remark != Marker || (r.Type != "A" && r.Type != "AAAA") || NameOf(r.Name, p.Subdomain) == "" {
				continue
			}
			ttl, _ := strconv.Atoi(r.TTL)
			out = append(out, Record{ID: r.ID, Name: strings.ToLower(r.Name), Type: r.Type, Value: r.Value, TTL: ttl})
		}
		total, _ := strconv.Atoi(ans.Info.RecordTotal)
		if len(ans.Records) < dnspodPage || off+dnspodPage >= total {
			return out, nil
		}
	}
}

// Upsert makes r (then marks it ours — a record that cannot be marked is
// removed again, or every later tick would make another) or changes r.ID.
func (p *DNSPod) Upsert(ctx context.Context, r Record) (Record, error) {
	if NameOf(r.Name, p.Subdomain) == "" {
		return Record{}, fmt.Errorf("dnspod: %q is not under %s", r.Name, p.Subdomain)
	}
	form := url.Values{
		"domain": {p.Domain}, "sub_domain": {r.Name}, "record_type": {r.Type},
		"record_line": {dnspodLine}, "value": {r.Value}, "ttl": {strconv.Itoa(r.TTL)},
	}
	if r.ID != "" {
		form.Set("record_id", r.ID)
		if _, err := p.call(ctx, "Record.Modify", form, nil); err != nil {
			return Record{}, err
		}
		return r, nil
	}
	var ans struct {
		Record struct {
			ID string `json:"id"`
		} `json:"record"`
	}
	if _, err := p.call(ctx, "Record.Create", form, &ans); err != nil {
		return Record{}, err
	}
	if ans.Record.ID == "" {
		return Record{}, errors.New("dnspod Record.Create: no record id in the answer")
	}
	r.ID = ans.Record.ID
	mark := url.Values{"domain": {p.Domain}, "record_id": {r.ID}, "remark": {Marker}}
	if _, err := p.call(ctx, "Record.Remark", mark, nil); err != nil {
		if derr := p.Delete(ctx, r.ID); derr != nil {
			return Record{}, fmt.Errorf("%w; and removing the unmarked record %s: %v", err, r.ID, derr)
		}
		return Record{}, err
	}
	return r, nil
}

// Delete removes the record id.
func (p *DNSPod) Delete(ctx context.Context, id string) error {
	_, err := p.call(ctx, "Record.Remove", url.Values{"domain": {p.Domain}, "record_id": {id}}, nil)
	return err
}
