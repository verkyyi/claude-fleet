// Package spot talks to the Kubernetes API the hub runs under, for the one
// thing the hub needs from it (claude-fleet#1428): create a pod on the
// cluster's SPOT machines, see whether it is still there, and delete it.
//
// Hand-rolled over net/http, like the Aliyun KMS client (internal/credvault):
// four verbs on one resource do not justify client-go's dependency tree, and
// the hub's own Dockerfile must stay a pure-Go cross-compile. In-cluster
// discovery is the standard one — KUBERNETES_SERVICE_HOST/PORT, the service
// account's token (re-read on every call: bound tokens rotate) and CA under
// /var/run/secrets/kubernetes.io/serviceaccount. Anything can be overridden,
// which is how the tests point it at an httptest server.
package spot

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// The in-cluster service account mount.
const (
	saDir           = "/var/run/secrets/kubernetes.io/serviceaccount"
	saTokenFile     = saDir + "/token"
	saCAFile        = saDir + "/ca.crt"
	saNamespaceFile = saDir + "/namespace"
)

// Config is where the API server is and how to authenticate.
type Config struct {
	// APIServer is the base URL. Empty: in-cluster, from the environment.
	APIServer string
	// Token is a bearer token; TokenFile a file holding one, re-read on
	// every request. With neither, the service account's token file.
	Token     string
	TokenFile string
	// CAFile is the PEM bundle the API server's certificate chains to; empty
	// means the service account's. Insecure skips verification (tests).
	CAFile   string
	Insecure bool
	// Namespace is where pods go; empty means the service account's own.
	Namespace string
	// Timeout bounds one request.
	Timeout time.Duration
}

// InCluster reports whether this process runs in a pod with a service
// account: the API server's address is in the environment and the token is
// mounted.
func InCluster() bool {
	if os.Getenv("KUBERNETES_SERVICE_HOST") == "" {
		return false
	}
	_, err := os.Stat(saTokenFile)
	return err == nil
}

// Client is one API server, one namespace.
type Client struct {
	base      string
	ns        string
	token     string
	tokenFile string
	http      *http.Client
}

// New builds a client. It fails early on a configuration that cannot work
// (no address, no credential) rather than at the first pod create.
func New(cfg Config) (*Client, error) {
	base := strings.TrimRight(cfg.APIServer, "/")
	if base == "" {
		host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
		if host == "" {
			return nil, errors.New("no API server: not in a cluster (KUBERNETES_SERVICE_HOST unset) and no address configured")
		}
		if port == "" {
			port = "443"
		}
		base = "https://" + host + ":" + port
	}
	c := &Client{base: base, ns: cfg.Namespace, token: cfg.Token, tokenFile: cfg.TokenFile}
	if c.token == "" && c.tokenFile == "" {
		c.tokenFile = saTokenFile
	}
	if c.token == "" {
		if _, err := os.Stat(c.tokenFile); err != nil {
			return nil, fmt.Errorf("no credential: %w", err)
		}
	}
	if c.ns == "" {
		if b, err := os.ReadFile(saNamespaceFile); err == nil {
			c.ns = strings.TrimSpace(string(b))
		}
	}
	if c.ns == "" {
		c.ns = "default"
	}
	tr := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}}
	switch {
	case cfg.Insecure:
		tr.TLSClientConfig.InsecureSkipVerify = true
	case strings.HasPrefix(base, "https://"):
		ca := cfg.CAFile
		if ca == "" {
			ca = saCAFile
		}
		pem, err := os.ReadFile(ca)
		if err != nil {
			return nil, fmt.Errorf("API server CA: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("API server CA %s: no certificate in it", ca)
		}
		tr.TLSClientConfig.RootCAs = pool
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	c.http = &http.Client{Transport: tr, Timeout: timeout}
	return c, nil
}

// Namespace is where this client puts pods.
func (c *Client) Namespace() string { return c.ns }

func (c *Client) bearer() (string, error) {
	if c.token != "" {
		return c.token, nil
	}
	b, err := os.ReadFile(c.tokenFile)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

// APIError is the API server's refusal, as its Status object says it.
type APIError struct {
	Code    int
	Reason  string
	Message string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("kubernetes: HTTP %d %s: %s", e.Code, e.Reason, e.Message)
}

// IsNotFound reports a 404.
func IsNotFound(err error) bool {
	var ae *APIError
	return errors.As(err, &ae) && ae.Code == http.StatusNotFound
}

func (c *Client) do(ctx context.Context, method, path string, body any, out any) error {
	var rd io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rd)
	if err != nil {
		return err
	}
	tok, err := c.bearer()
	if err != nil {
		return fmt.Errorf("kubernetes credential: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("kubernetes: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode/100 != 2 {
		ae := &APIError{Code: resp.StatusCode, Reason: resp.Status}
		var st struct {
			Reason  string `json:"reason"`
			Message string `json:"message"`
		}
		if json.Unmarshal(raw, &st) == nil && st.Message != "" {
			ae.Reason, ae.Message = st.Reason, st.Message
		} else {
			ae.Message = strings.TrimSpace(string(raw))
		}
		return ae
	}
	if out != nil && len(raw) > 0 {
		return json.Unmarshal(raw, out)
	}
	return nil
}

// Pod is what the hub reads back about one pod.
type Pod struct {
	Name string `json:"name"`
	// Phase is Pending | Running | Succeeded | Failed | Unknown.
	Phase string `json:"phase"`
	// Deleting is set once a delete was accepted (deletionTimestamp set).
	Deleting bool              `json:"deleting,omitempty"`
	Node     string            `json:"node,omitempty"`
	Labels   map[string]string `json:"labels,omitempty"`
	// Reason is the first container's waiting/terminated reason when it is
	// not simply running — ImagePullBackOff, OOMKilled, Error — so a pod that
	// never joins says why in the ledger.
	Reason string `json:"reason,omitempty"`
}

// Gone reports a pod that will never serve again: finished, or failed.
func (p Pod) Gone() bool { return p.Phase == "Succeeded" || p.Phase == "Failed" }

type podObject struct {
	Metadata struct {
		Name              string            `json:"name"`
		Labels            map[string]string `json:"labels"`
		DeletionTimestamp string            `json:"deletionTimestamp"`
	} `json:"metadata"`
	Spec struct {
		NodeName string `json:"nodeName"`
	} `json:"spec"`
	Status struct {
		Phase             string `json:"phase"`
		ContainerStatuses []struct {
			State map[string]struct {
				Reason string `json:"reason"`
			} `json:"state"`
		} `json:"containerStatuses"`
	} `json:"status"`
}

func (o podObject) pod() Pod {
	p := Pod{Name: o.Metadata.Name, Phase: o.Status.Phase, Node: o.Spec.NodeName, Labels: o.Metadata.Labels,
		Deleting: o.Metadata.DeletionTimestamp != ""}
	if p.Phase == "" {
		p.Phase = "Unknown"
	}
	for _, cs := range o.Status.ContainerStatuses {
		for k, st := range cs.State {
			if k != "running" && st.Reason != "" {
				p.Reason = st.Reason
			}
		}
		break
	}
	return p
}

func (c *Client) podsPath() string { return "/api/v1/namespaces/" + c.ns + "/pods" }

// CreatePod creates the pod described by spec (a complete Pod object, see
// BuildPod).
func (c *Client) CreatePod(ctx context.Context, spec map[string]any) (Pod, error) {
	var o podObject
	if err := c.do(ctx, http.MethodPost, c.podsPath(), spec, &o); err != nil {
		return Pod{}, err
	}
	return o.pod(), nil
}

// GetPod reads one pod. found is false (and err nil) when it does not exist.
func (c *Client) GetPod(ctx context.Context, name string) (p Pod, found bool, err error) {
	var o podObject
	err = c.do(ctx, http.MethodGet, c.podsPath()+"/"+name, nil, &o)
	if IsNotFound(err) {
		return Pod{}, false, nil
	}
	if err != nil {
		return Pod{}, false, err
	}
	return o.pod(), true, nil
}

// DeletePod asks for the pod to go, giving its process graceSeconds to
// finish (the kubelet sends SIGTERM, then SIGKILL after that long). A pod
// that is already gone is not an error (found false).
func (c *Client) DeletePod(ctx context.Context, name string, graceSeconds int64) (found bool, err error) {
	body := map[string]any{"apiVersion": "v1", "kind": "DeleteOptions", "gracePeriodSeconds": graceSeconds}
	err = c.do(ctx, http.MethodDelete, c.podsPath()+"/"+name, body, nil)
	if IsNotFound(err) {
		return false, nil
	}
	return err == nil, err
}

// ListPods lists the pods matching a label selector (k=v[,k=v]).
func (c *Client) ListPods(ctx context.Context, selector string) ([]Pod, error) {
	var list struct {
		Items []podObject `json:"items"`
	}
	path := c.podsPath()
	if selector != "" {
		path += "?labelSelector=" + strings.ReplaceAll(selector, ",", "%2C")
	}
	if err := c.do(ctx, http.MethodGet, path, nil, &list); err != nil {
		return nil, err
	}
	out := make([]Pod, 0, len(list.Items))
	for _, o := range list.Items {
		out = append(out, o.pod())
	}
	return out, nil
}

// PodInput is everything the hub decides about a node pod.
type PodInput struct {
	Name, Image  string
	Labels       map[string]string
	Env          map[string]string
	NodeSelector map[string]string
	Tolerations  []map[string]any
	// GraceSeconds is terminationGracePeriodSeconds: how long the node gets,
	// after the SPOT reclaim's SIGTERM, to move its idle sessions off.
	GraceSeconds   int64
	CPU, Memory    string
	ServiceAccount string
	PullSecret     string
	// Overlay is merged over the generated object last (maps merge by key,
	// anything else replaces) — the operator's escape hatch for a field this
	// struct does not name: a volume, a runtime class, an affinity.
	Overlay map[string]any
}

// BuildPod renders the Pod object the hub creates.
func BuildPod(in PodInput) map[string]any {
	env := make([]map[string]any, 0, len(in.Env))
	for _, k := range sortedKeys(in.Env) {
		env = append(env, map[string]any{"name": k, "value": in.Env[k]})
	}
	container := map[string]any{"name": "node", "image": in.Image, "env": env}
	if in.CPU != "" || in.Memory != "" {
		req := map[string]any{}
		if in.CPU != "" {
			req["cpu"] = in.CPU
		}
		if in.Memory != "" {
			req["memory"] = in.Memory
		}
		container["resources"] = map[string]any{"requests": req}
	}
	spec := map[string]any{
		"restartPolicy":                 "Never",
		"terminationGracePeriodSeconds": in.GraceSeconds,
		"containers":                    []any{container},
	}
	if len(in.NodeSelector) > 0 {
		spec["nodeSelector"] = toAnyMap(in.NodeSelector)
	}
	if len(in.Tolerations) > 0 {
		t := make([]any, 0, len(in.Tolerations))
		for _, x := range in.Tolerations {
			t = append(t, x)
		}
		spec["tolerations"] = t
	}
	if in.ServiceAccount != "" {
		spec["serviceAccountName"] = in.ServiceAccount
	}
	if in.PullSecret != "" {
		spec["imagePullSecrets"] = []any{map[string]any{"name": in.PullSecret}}
	}
	obj := map[string]any{
		"apiVersion": "v1", "kind": "Pod",
		"metadata": map[string]any{"name": in.Name, "labels": toAnyMap(in.Labels)},
		"spec":     spec,
	}
	if len(in.Overlay) > 0 {
		obj = merge(obj, in.Overlay).(map[string]any)
	}
	return obj
}

// merge lays over on top of base: maps merge key by key, anything else
// (lists, scalars) replaces.
func merge(base, over any) any {
	bm, bok := base.(map[string]any)
	om, ook := over.(map[string]any)
	if !bok || !ook {
		return over
	}
	out := make(map[string]any, len(bm)+len(om))
	for k, v := range bm {
		out[k] = v
	}
	for k, v := range om {
		if cur, ok := out[k]; ok {
			out[k] = merge(cur, v)
		} else {
			out[k] = v
		}
	}
	return out
}

func toAnyMap(m map[string]string) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := 1; i < len(keys); i++ { // insertion sort: a handful of env vars
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	return keys
}

// ParseTolerations reads CCQUOTA_FLEET_SPOT_TOLERATIONS: a JSON array of
// toleration objects, or the short form `key[=value][:effect]` separated by
// commas (`spot=true:NoSchedule,kubernetes.io/spot:NoExecute`). With no
// value the operator is Exists; with one, Equal.
func ParseTolerations(s string) ([]map[string]any, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	if strings.HasPrefix(s, "[") {
		var out []map[string]any
		if err := json.Unmarshal([]byte(s), &out); err != nil {
			return nil, fmt.Errorf("tolerations: %w", err)
		}
		return out, nil
	}
	var out []map[string]any
	for _, item := range strings.Split(s, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		t := map[string]any{}
		if i := strings.LastIndexByte(item, ':'); i >= 0 {
			t["effect"] = item[i+1:]
			item = item[:i]
		}
		if k, v, ok := strings.Cut(item, "="); ok {
			t["key"], t["operator"], t["value"] = k, "Equal", v
		} else {
			t["key"], t["operator"] = item, "Exists"
		}
		out = append(out, t)
	}
	return out, nil
}

// ParseSelector reads a `k=v,k=v` node selector.
func ParseSelector(s string) (map[string]string, error) {
	out := map[string]string{}
	for _, item := range strings.Split(s, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		k, v, ok := strings.Cut(item, "=")
		if !ok || k == "" {
			return nil, fmt.Errorf("node selector: %q is not key=value", item)
		}
		out[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	return out, nil
}

// Quantity checks a Kubernetes resource quantity loosely: a number with an
// optional SI / binary suffix. Enough to refuse a typo before the API does.
func Quantity(s string) error {
	if s == "" {
		return nil
	}
	num := strings.TrimRight(s, "mkMGTPEKi")
	if _, err := strconv.ParseFloat(num, 64); err != nil || num == "" {
		return fmt.Errorf("%q is not a Kubernetes quantity (500m, 2, 4Gi)", s)
	}
	return nil
}
