package credvault

// Aliyun KMS, for the vault's envelope (claude-fleet#1417).
//
// The hub talks to KMS for one thing: unwrapping the vault's data key at
// startup (and wrapping it the first time, or again under a new master key).
// Three RPC actions — GenerateDataKey, Decrypt, Encrypt — signed by hand
// (signature v1, HMAC-SHA1) rather than through the Aliyun SDK, whose
// dependency tree would dwarf this module's for three calls made once a boot.
//
// Where the hub's Aliyun identity comes from decides whether KMS buys anything.
// A static AccessKey in a k8s Secret puts the master key one Secret away from
// the database again; RRSA (ACK's per-pod RAM role, an OIDC token projected
// into the pod) or an ECS instance role put it behind the cluster's own
// identity, which a stolen Secret + database do not carry. The static key is
// supported for a laptop test, and the hub says so in its log.

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

// KMS is the slice of Aliyun KMS the vault uses. Plaintexts cross it as
// base64 text — KMS's own convention for a data key — so a key wrapped by
// GenerateDataKey and one re-wrapped by Encrypt unwrap identically.
type KMS interface {
	GenerateDataKey(ctx context.Context, keyID string, ec map[string]string) (KMSResult, error)
	Decrypt(ctx context.Context, blob string, ec map[string]string) (KMSResult, error)
	Encrypt(ctx context.Context, keyID, plaintextB64 string, ec map[string]string) (KMSResult, error)
}

// KMSResult is what one KMS call returned. Plaintext is base64; RequestID is
// the id the call carries in KMS's own log (ActionTrail), so a hub audit row
// can be matched to the console record.
type KMSResult struct {
	KeyID          string `json:"KeyId"`
	KeyVersionID   string `json:"KeyVersionId"`
	CiphertextBlob string `json:"CiphertextBlob"`
	Plaintext      string `json:"Plaintext"`
	RequestID      string `json:"RequestId"`
}

// AliyunCreds is one set of Aliyun credentials; SecurityToken is set for STS.
type AliyunCreds struct {
	AccessKeyID, AccessKeySecret, SecurityToken string
	// Source names where they came from, for the hub's log ("rrsa", ...).
	Source string
}

// CredsProvider yields credentials for one call. It is asked every call: the
// vault calls KMS a handful of times a boot, so caching an STS token would buy
// nothing and add an expiry to get wrong.
type CredsProvider func(ctx context.Context) (AliyunCreds, error)

// AliyunKMS is the KMS RPC client.
type AliyunKMS struct {
	Endpoint string // https://kms.cn-shenzhen.aliyuncs.com
	Creds    CredsProvider
	HTTP     *http.Client
	Now      func() time.Time
}

func (k *AliyunKMS) client() *http.Client {
	if k.HTTP != nil {
		return k.HTTP
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (k *AliyunKMS) now() time.Time {
	if k.Now != nil {
		return k.Now()
	}
	return time.Now()
}

func ecJSON(ec map[string]string) string {
	if len(ec) == 0 {
		return ""
	}
	b, _ := json.Marshal(ec) // map keys marshal sorted: stable
	return string(b)
}

// GenerateDataKey mints a 256-bit data key under keyID.
func (k *AliyunKMS) GenerateDataKey(ctx context.Context, keyID string, ec map[string]string) (KMSResult, error) {
	return k.call(ctx, "GenerateDataKey", map[string]string{
		"KeyId": keyID, "KeySpec": "AES_256", "EncryptionContext": ecJSON(ec)})
}

// Decrypt unwraps a blob. The blob names its own master key and version, so a
// rotated master key needs nothing from the caller.
func (k *AliyunKMS) Decrypt(ctx context.Context, blob string, ec map[string]string) (KMSResult, error) {
	return k.call(ctx, "Decrypt", map[string]string{"CiphertextBlob": blob, "EncryptionContext": ecJSON(ec)})
}

// Encrypt wraps plaintextB64 under keyID.
func (k *AliyunKMS) Encrypt(ctx context.Context, keyID, plaintextB64 string, ec map[string]string) (KMSResult, error) {
	return k.call(ctx, "Encrypt", map[string]string{
		"KeyId": keyID, "Plaintext": plaintextB64, "EncryptionContext": ecJSON(ec)})
}

// KMSError is an error KMS (or STS) answered with.
type KMSError struct {
	Status    int
	Code      string
	Message   string
	RequestID string
}

func (e *KMSError) Error() string {
	return fmt.Sprintf("kms %d %s: %s (request %s)", e.Status, e.Code, e.Message, e.RequestID)
}

func (k *AliyunKMS) call(ctx context.Context, action string, params map[string]string) (KMSResult, error) {
	if k.Creds == nil {
		return KMSResult{}, errors.New("kms: no credentials configured")
	}
	cr, err := k.Creds(ctx)
	if err != nil {
		return KMSResult{}, fmt.Errorf("kms credentials: %w", err)
	}
	q := map[string]string{
		"Action": action, "Version": "2016-01-20", "Format": "JSON",
		"AccessKeyId": cr.AccessKeyID, "SignatureMethod": "HMAC-SHA1", "SignatureVersion": "1.0",
		"SignatureNonce": nonce(), "Timestamp": k.now().UTC().Format("2006-01-02T15:04:05Z"),
	}
	if cr.SecurityToken != "" {
		q["SecurityToken"] = cr.SecurityToken
	}
	for key, v := range params {
		if v != "" {
			q[key] = v
		}
	}
	q["Signature"] = SignRPC(http.MethodPost, q, cr.AccessKeySecret)
	var out KMSResult
	if err := postForm(ctx, k.client(), strings.TrimRight(k.Endpoint, "/")+"/", q, &out); err != nil {
		return KMSResult{}, err
	}
	return out, nil
}

// SignRPC is Aliyun's RPC signature v1 over the query q (Signature excluded).
func SignRPC(method string, q map[string]string, secret string) string {
	keys := make([]string, 0, len(q))
	for k := range q {
		if k != "Signature" {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = percentEncode(k) + "=" + percentEncode(q[k])
	}
	sts := method + "&" + percentEncode("/") + "&" + percentEncode(strings.Join(parts, "&"))
	m := hmac.New(sha1.New, []byte(secret+"&"))
	m.Write([]byte(sts))
	return base64.StdEncoding.EncodeToString(m.Sum(nil))
}

func percentEncode(s string) string {
	e := url.QueryEscape(s)
	e = strings.ReplaceAll(e, "+", "%20")
	e = strings.ReplaceAll(e, "*", "%2A")
	return strings.ReplaceAll(e, "%7E", "~")
}

func nonce() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// postForm sends q as a form and decodes a 2xx JSON answer into out, or turns
// a non-2xx into a KMSError.
func postForm(ctx context.Context, hc *http.Client, endpoint string, q map[string]string, out any) error {
	form := url.Values{}
	for k, v := range q {
		form.Set(k, v)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		var e struct{ Code, Message, RequestId string }
		_ = json.Unmarshal(body, &e)
		if e.Code == "" {
			e.Message = truncate(strings.TrimSpace(string(body)), 200)
		}
		return &KMSError{Status: resp.StatusCode, Code: e.Code, Message: e.Message, RequestID: e.RequestId}
	}
	return json.Unmarshal(body, out)
}

// --- where the hub's Aliyun identity comes from ----------------------------------

// Endpoints. Package variables so a test can point them at a fake.
var (
	ecsMetadataURL = "http://100.100.100.200/latest/meta-data/ram/security-credentials/"
	stsEndpoint    = "https://sts.aliyuncs.com"
)

// CredsFromEnv picks the hub's Aliyun identity from the standard Alibaba Cloud
// variables, most to least preferred:
//
//	RRSA        ALIBABA_CLOUD_ROLE_ARN + ALIBABA_CLOUD_OIDC_PROVIDER_ARN +
//	            ALIBABA_CLOUD_OIDC_TOKEN_FILE (what ACK injects into a pod)
//	ECS role    ALIBABA_CLOUD_ECS_METADATA=<role name>
//	static key  ALIBABA_CLOUD_ACCESS_KEY_ID + ALIBABA_CLOUD_ACCESS_KEY_SECRET
//	            (+ ALIBABA_CLOUD_SECURITY_TOKEN)
//
// ALIBABA_CLOUD_STS_ENDPOINT overrides the STS endpoint RRSA exchanges at
// (a VPC endpoint, say).
func CredsFromEnv(getenv func(string) string, hc *http.Client) (CredsProvider, string, error) {
	if hc == nil {
		hc = &http.Client{Timeout: 10 * time.Second}
	}
	role, provider, tokenFile := getenv("ALIBABA_CLOUD_ROLE_ARN"), getenv("ALIBABA_CLOUD_OIDC_PROVIDER_ARN"),
		getenv("ALIBABA_CLOUD_OIDC_TOKEN_FILE")
	if role != "" && provider != "" && tokenFile != "" {
		sts := stsEndpoint
		if v := getenv("ALIBABA_CLOUD_STS_ENDPOINT"); v != "" {
			if !strings.Contains(v, "://") {
				v = "https://" + v
			}
			sts = v
		}
		return func(ctx context.Context) (AliyunCreds, error) {
			return assumeRoleWithOIDC(ctx, hc, sts, role, provider, tokenFile)
		}, "rrsa", nil
	}
	if r := getenv("ALIBABA_CLOUD_ECS_METADATA"); r != "" {
		return func(ctx context.Context) (AliyunCreds, error) { return ecsRoleCreds(ctx, hc, r) }, "ecs-role", nil
	}
	id, secret := getenv("ALIBABA_CLOUD_ACCESS_KEY_ID"), getenv("ALIBABA_CLOUD_ACCESS_KEY_SECRET")
	if id != "" && secret != "" {
		c := AliyunCreds{AccessKeyID: id, AccessKeySecret: secret,
			SecurityToken: getenv("ALIBABA_CLOUD_SECURITY_TOKEN"), Source: "static-key"}
		return func(context.Context) (AliyunCreds, error) { return c, nil }, "static-key", nil
	}
	return nil, "", errors.New("no Aliyun identity: set RRSA (ALIBABA_CLOUD_ROLE_ARN + ALIBABA_CLOUD_OIDC_PROVIDER_ARN + " +
		"ALIBABA_CLOUD_OIDC_TOKEN_FILE), ALIBABA_CLOUD_ECS_METADATA, or ALIBABA_CLOUD_ACCESS_KEY_ID/_SECRET")
}

func assumeRoleWithOIDC(ctx context.Context, hc *http.Client, endpoint, role, provider, tokenFile string) (AliyunCreds, error) {
	tok, err := os.ReadFile(tokenFile)
	if err != nil {
		return AliyunCreds{}, fmt.Errorf("read OIDC token: %w", err)
	}
	// AssumeRoleWithOIDC is the one STS call that is not signed: the OIDC
	// token IS the proof.
	q := map[string]string{
		"Action": "AssumeRoleWithOIDC", "Version": "2015-04-01", "Format": "JSON",
		"Timestamp": time.Now().UTC().Format("2006-01-02T15:04:05Z"), "SignatureNonce": nonce(),
		"RoleArn": role, "OIDCProviderArn": provider, "OIDCToken": strings.TrimSpace(string(tok)),
		"RoleSessionName": "ccquota-hub", "DurationSeconds": "900",
	}
	var out struct {
		Credentials struct{ AccessKeyId, AccessKeySecret, SecurityToken string }
	}
	if err := postForm(ctx, hc, strings.TrimRight(endpoint, "/")+"/", q, &out); err != nil {
		return AliyunCreds{}, fmt.Errorf("sts AssumeRoleWithOIDC: %w", err)
	}
	c := out.Credentials
	if c.AccessKeyId == "" {
		return AliyunCreds{}, errors.New("sts AssumeRoleWithOIDC: no credentials in the answer")
	}
	return AliyunCreds{AccessKeyID: c.AccessKeyId, AccessKeySecret: c.AccessKeySecret,
		SecurityToken: c.SecurityToken, Source: "rrsa"}, nil
}

func ecsRoleCreds(ctx context.Context, hc *http.Client, role string) (AliyunCreds, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ecsMetadataURL+url.PathEscape(role), nil)
	if err != nil {
		return AliyunCreds{}, err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return AliyunCreds{}, fmt.Errorf("ecs metadata: %w", err)
	}
	defer resp.Body.Close()
	var out struct{ Code, AccessKeyId, AccessKeySecret, SecurityToken string }
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&out); err != nil {
		return AliyunCreds{}, fmt.Errorf("ecs metadata: %w", err)
	}
	if resp.StatusCode != http.StatusOK || out.Code != "Success" || out.AccessKeyId == "" {
		return AliyunCreds{}, fmt.Errorf("ecs metadata: role %q: status %d code %q", role, resp.StatusCode, out.Code)
	}
	return AliyunCreds{AccessKeyID: out.AccessKeyId, AccessKeySecret: out.AccessKeySecret,
		SecurityToken: out.SecurityToken, Source: "ecs-role"}, nil
}
