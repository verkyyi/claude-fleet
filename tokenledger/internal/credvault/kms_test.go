package credvault

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Aliyun's own worked example of signature v1 (the ECS DescribeRegions call in
// the "request signature" docs): if this drifts, every real KMS call is
// refused as SignatureDoesNotMatch.
func TestSignRPCMatchesAliyunExample(t *testing.T) {
	q := map[string]string{
		"AccessKeyId": "testid", "Action": "DescribeRegions", "Format": "XML",
		"SignatureMethod": "HMAC-SHA1", "SignatureNonce": "3ee8c1b8-83d3-44af-a94f-4e0ad82fd6cf",
		"SignatureVersion": "1.0", "Timestamp": "2016-02-23T12:46:24Z", "Version": "2014-05-26",
	}
	if got, want := SignRPC(http.MethodGet, q, "testsecret"), "OLeaidS1JvxuMvnyHOwuJ+uX5qY="; got != want {
		t.Fatalf("signature %s, want %s", got, want)
	}
}

// fakeKMS is a KMS that holds its master keys and never hands them out: a
// wrapped blob is opaque to anything but this server. It checks every
// request's signature and EncryptionContext, and can be taken down.
type fakeKMS struct {
	t      *testing.T
	secret string
	mu     sync.Mutex
	master map[string][]byte
	calls  []string
	down   atomic.Bool
	srv    *httptest.Server
}

func newFakeKMS(t *testing.T) *fakeKMS {
	f := &fakeKMS{t: t, secret: "kms-secret", master: map[string][]byte{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeKMS) client() *AliyunKMS {
	return &AliyunKMS{Endpoint: f.srv.URL, Creds: func(context.Context) (AliyunCreds, error) {
		return AliyunCreds{AccessKeyID: "hub", AccessKeySecret: f.secret, SecurityToken: "sts"}, nil
	}}
}

func (f *fakeKMS) Calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func (f *fakeKMS) fail(w http.ResponseWriter, status int, code string) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"Code": code, "Message": code, "RequestId": "req-err"})
}

func (f *fakeKMS) aead(keyID string) cipher.AEAD {
	f.mu.Lock()
	defer f.mu.Unlock()
	k := f.master[keyID]
	if k == nil {
		k = make([]byte, 32)
		_, _ = rand.Read(k)
		f.master[keyID] = k
	}
	b, _ := aes.NewCipher(k)
	a, _ := cipher.NewGCM(b)
	return a
}

func (f *fakeKMS) wrap(keyID, plain, ec string) string {
	a := f.aead(keyID)
	n := make([]byte, a.NonceSize())
	_, _ = rand.Read(n)
	return base64.StdEncoding.EncodeToString([]byte(keyID + "|" + string(a.Seal(n, n, []byte(plain), []byte(ec)))))
}

func (f *fakeKMS) serve(w http.ResponseWriter, r *http.Request) {
	if f.down.Load() {
		f.fail(w, http.StatusServiceUnavailable, "ServiceUnavailable")
		return
	}
	_ = r.ParseForm()
	q := map[string]string{}
	for k := range r.PostForm {
		q[k] = r.PostForm.Get(k)
	}
	if SignRPC(http.MethodPost, q, f.secret) != q["Signature"] || q["SecurityToken"] != "sts" {
		f.fail(w, http.StatusBadRequest, "SignatureDoesNotMatch")
		return
	}
	ec := q["EncryptionContext"]
	if !strings.Contains(ec, "ccquota-fleet-credential-vault") {
		f.t.Errorf("%s without the vault's EncryptionContext: %q", q["Action"], ec)
	}
	f.mu.Lock()
	f.calls = append(f.calls, q["Action"])
	f.mu.Unlock()
	out := map[string]string{"RequestId": "req-" + q["Action"], "KeyVersionId": "v1"}
	switch q["Action"] {
	case "GenerateDataKey":
		dk := make([]byte, 32)
		_, _ = rand.Read(dk)
		plain := base64.StdEncoding.EncodeToString(dk)
		out["KeyId"], out["Plaintext"], out["CiphertextBlob"] = q["KeyId"], plain, f.wrap(q["KeyId"], plain, ec)
	case "Encrypt":
		out["KeyId"], out["CiphertextBlob"] = q["KeyId"], f.wrap(q["KeyId"], q["Plaintext"], ec)
	case "Decrypt":
		raw, _ := base64.StdEncoding.DecodeString(q["CiphertextBlob"])
		keyID, ct, ok := strings.Cut(string(raw), "|")
		if !ok {
			f.fail(w, http.StatusBadRequest, "InvalidCiphertextBlob")
			return
		}
		a := f.aead(keyID)
		ns := a.NonceSize()
		plain, err := a.Open(nil, []byte(ct)[:ns], []byte(ct)[ns:], []byte(ec))
		if err != nil {
			f.fail(w, http.StatusBadRequest, "InvalidCiphertextBlob")
			return
		}
		out["KeyId"], out["Plaintext"] = keyID, string(plain)
	default:
		f.fail(w, http.StatusBadRequest, "InvalidAction")
		return
	}
	_ = json.NewEncoder(w).Encode(out)
}

func newStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "hub.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	return st
}

// The first KMS start mints a data key and stores it wrapped; the next start
// (a new process: nothing in memory) gets the same key back from Decrypt.
func TestEnvelopeInstallsThenUnwraps(t *testing.T) {
	kms := newFakeKMS(t)
	st := newStore(t)
	env := &Envelope{KMS: kms.client(), KeyID: "alias/fleet", Store: st}

	s1, detail, err := env.Open(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(detail, "req-GenerateDataKey") {
		t.Errorf("detail should carry the KMS request id: %q", detail)
	}
	v := &Vault{Store: st, Sealer: s1}
	if err := v.Put("p1", Claude, "main", Secret{RefreshToken: "RT-1"}); err != nil {
		t.Fatal(err)
	}

	s2, detail, err := (&Envelope{KMS: kms.client(), KeyID: "alias/fleet", Store: st}).Open(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(detail, "req-Decrypt") {
		t.Errorf("second start should Decrypt: %q", detail)
	}
	c, _ := st.Credential("p1", Claude, "main")
	var s Secret
	if err := s2.Open(c.SecretSealed, &s, "p1", Claude, "main", "secret"); err != nil || s.RefreshToken != "RT-1" {
		t.Fatalf("unwrapped key does not open the row: %v %+v", err, s)
	}
	if got := kms.Calls(); strings.Join(got, ",") != "GenerateDataKey,Decrypt" {
		t.Errorf("kms calls %v", got)
	}
}

// The success criterion: the database and every Secret taken together open
// nothing. After the migration the old plain key (the Secret #1415 used) no
// longer opens a row, and the database holds the data key only as KMS
// ciphertext.
func TestDatabaseAndSecretTogetherOpenNothing(t *testing.T) {
	kms := newFakeKMS(t)
	st := newStore(t)
	legacy, _ := NewSealer(testKey())
	old := &Vault{Store: st, Sealer: legacy}
	if err := old.Put("p1", Claude, "main", Secret{RefreshToken: "RT-secret"}); err != nil {
		t.Fatal(err)
	}
	if err := old.Put("p1", Codex, "work", Secret{RefreshToken: "RT-codex", AccountID: "acc"}); err != nil {
		t.Fatal(err)
	}

	env := &Envelope{KMS: kms.client(), KeyID: "alias/fleet", Store: st, Legacy: testKey()}
	s, detail, err := env.Open(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(detail, "re-sealed 2") {
		t.Errorf("detail %q", detail)
	}

	creds, _ := st.Credentials("")
	for _, c := range creds {
		var sec Secret
		if legacy.Open(c.SecretSealed, &sec, c.PrincipalID, c.Provider, c.Account, "secret") == nil {
			t.Errorf("%s/%s still opens with the leaked Secret's key", c.Provider, c.Account)
		}
		if err := s.Open(c.SecretSealed, &sec, c.PrincipalID, c.Provider, c.Account, "secret"); err != nil || sec.RefreshToken == "" {
			t.Errorf("%s/%s does not open with the KMS data key: %v", c.Provider, c.Account, err)
		}
	}
	// What the database holds of the key is KMS ciphertext: neither the data
	// key nor anything derived from the Secret.
	k, err := st.VaultKey()
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.StdEncoding.DecodeString(k.Wrapped)
	for _, c := range creds {
		if bytes.Contains(c.SecretSealed, []byte("RT-")) {
			t.Error("plaintext refresh token in the database")
		}
	}
	if len(raw) < 32 || bytes.Contains(raw, testKey()) {
		t.Errorf("wrapped key looks wrong: %d bytes", len(raw))
	}
	// And a restart with the legacy key still set ignores it: Decrypt only.
	if _, _, err := (&Envelope{KMS: kms.client(), KeyID: "alias/fleet", Store: st, Legacy: testKey()}).Open(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := kms.Calls(); strings.Join(got, ",") != "GenerateDataKey,Decrypt" {
		t.Errorf("kms calls %v", got)
	}
}

// Rows sealed under a key the hub was not given refuse the install rather
// than strand them behind a fresh data key.
func TestInstallRefusesRowsItCannotReseal(t *testing.T) {
	kms := newFakeKMS(t)
	st := newStore(t)
	legacy, _ := NewSealer(testKey())
	if err := (&Vault{Store: st, Sealer: legacy}).Put("p1", Claude, "main", Secret{RefreshToken: "RT"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := (&Envelope{KMS: kms.client(), KeyID: "k", Store: st}).Open(context.Background()); err == nil {
		t.Fatal("install over unreadable rows succeeded")
	}
	if _, err := st.VaultKey(); !errors.Is(err, store.ErrNoVaultKey) {
		t.Errorf("a key row was left behind: %v", err)
	}
}

// Pointing the hub at another master key re-wraps the one data key; no row
// is touched.
func TestNewMasterKeyRewrapsWithoutTouchingData(t *testing.T) {
	kms := newFakeKMS(t)
	st := newStore(t)
	s, _, err := (&Envelope{KMS: kms.client(), KeyID: "key-a", Store: st}).Open(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := (&Vault{Store: st, Sealer: s}).Put("p1", Claude, "main", Secret{RefreshToken: "RT"}); err != nil {
		t.Fatal(err)
	}
	before, _ := st.Credential("p1", Claude, "main")

	_, detail, err := (&Envelope{KMS: kms.client(), KeyID: "key-b", Store: st}).Open(context.Background())
	if err != nil || !strings.Contains(detail, "re-wrapped key-a → key-b") {
		t.Fatalf("%v %q", err, detail)
	}
	k, _ := st.VaultKey()
	if k.KMSKeyID != "key-b" || k.RewrappedAt == nil {
		t.Errorf("key row %+v", k)
	}
	after, _ := st.Credential("p1", Claude, "main")
	if !bytes.Equal(before.SecretSealed, after.SecretSealed) {
		t.Error("re-wrapping touched the sealed data")
	}
	s3, _, err := (&Envelope{KMS: kms.client(), KeyID: "key-b", Store: st}).Open(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var sec Secret
	if err := s3.Open(after.SecretSealed, &sec, "p1", Claude, "main", "secret"); err != nil {
		t.Fatal(err)
	}
}

// The completion criterion: KMS unreachable ⇒ the vault refuses to issue,
// says so, and does NOT fall back to the plain key it was also given. When
// KMS comes back, it opens.
func TestKMSDownLocksVaultWithoutFallback(t *testing.T) {
	kms := newFakeKMS(t)
	st := newStore(t)
	legacy, _ := NewSealer(testKey())
	if err := (&Vault{Store: st, Sealer: legacy}).Put("p1", Claude, "main", Secret{RefreshToken: "RT"}); err != nil {
		t.Fatal(err)
	}
	kms.down.Store(true)

	v := &Vault{Store: st, Refresher: &countingRefresher{ttl: 8 * time.Hour}}
	v.SetLocked("starting", time.Now())
	type ev struct {
		locked bool
		detail string
	}
	events := make(chan ev, 4)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go KeepUnlocked(ctx, v, &Envelope{KMS: kms.client(), KeyID: "k", Store: st, Legacy: testKey()},
		20*time.Millisecond, 50*time.Millisecond, func(locked bool, d string) { events <- ev{locked, d} })

	e := <-events
	if !e.locked || !strings.Contains(e.detail, "ServiceUnavailable") {
		t.Fatalf("first event %+v", e)
	}
	if l := v.Locked(); l == nil || !strings.Contains(l.Reason, "ServiceUnavailable") {
		t.Fatalf("vault not locked: %+v", l)
	}
	if _, err := v.Lease(context.Background(), "p1", Claude, "main"); !errors.Is(err, ErrLocked) {
		t.Fatalf("lease while locked: %v", err)
	}
	if err := v.Put("p2", Claude, "x", Secret{RefreshToken: "RT"}); !errors.Is(err, ErrLocked) {
		t.Fatalf("put while locked: %v", err)
	}
	// Still sealed under the legacy key, untouched: nothing was migrated
	// and nothing fell back.
	c, _ := st.Credential("p1", Claude, "main")
	var sec Secret
	if err := legacy.Open(c.SecretSealed, &sec, "p1", Claude, "main", "secret"); err != nil {
		t.Fatalf("row changed while KMS was down: %v", err)
	}

	kms.down.Store(false)
	select {
	case e = <-events:
	case <-time.After(5 * time.Second):
		t.Fatal("never unlocked after KMS came back")
	}
	if e.locked || v.Locked() != nil {
		t.Fatalf("still locked: %+v", e)
	}
	if _, err := v.Lease(context.Background(), "p1", Claude, "main"); err != nil {
		t.Fatalf("lease after unlock: %v", err)
	}
}

// A vault with no lock state and no sealer reports itself locked rather than
// panicking on a nil sealer.
func TestZeroVaultIsLocked(t *testing.T) {
	v := &Vault{}
	if v.Locked() == nil {
		t.Fatal("keyless vault reports unlocked")
	}
	if _, err := v.Lease(context.Background(), "p", Claude, "a"); !errors.Is(err, ErrLocked) {
		t.Fatal(err)
	}
}

func TestCredsFromEnv(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if _, _, err := CredsFromEnv(env(nil), nil); err == nil {
		t.Error("no identity accepted")
	}
	_, src, err := CredsFromEnv(env(map[string]string{"ALIBABA_CLOUD_ACCESS_KEY_ID": "a", "ALIBABA_CLOUD_ACCESS_KEY_SECRET": "b"}), nil)
	if err != nil || src != "static-key" {
		t.Errorf("static: %s %v", src, err)
	}

	// RRSA: the OIDC token is exchanged at STS, unsigned, for STS creds.
	tokFile := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokFile, []byte("oidc-jwt\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	sts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.PostForm.Get("Action") != "AssumeRoleWithOIDC" || r.PostForm.Get("OIDCToken") != "oidc-jwt" ||
			r.PostForm.Get("RoleArn") != "acs:ram::1:role/hub" {
			w.WriteHeader(400)
			return
		}
		_, _ = w.Write([]byte(`{"Credentials":{"AccessKeyId":"STS.x","AccessKeySecret":"s","SecurityToken":"t"}}`))
	}))
	defer sts.Close()
	p, src, err := CredsFromEnv(env(map[string]string{
		"ALIBABA_CLOUD_ROLE_ARN": "acs:ram::1:role/hub", "ALIBABA_CLOUD_OIDC_PROVIDER_ARN": "acs:ram::1:oidc-provider/ack",
		"ALIBABA_CLOUD_OIDC_TOKEN_FILE": tokFile, "ALIBABA_CLOUD_STS_ENDPOINT": sts.URL,
		// RRSA outranks a static key set beside it.
		"ALIBABA_CLOUD_ACCESS_KEY_ID": "a", "ALIBABA_CLOUD_ACCESS_KEY_SECRET": "b",
	}), nil)
	if err != nil || src != "rrsa" {
		t.Fatalf("rrsa: %s %v", src, err)
	}
	c, err := p(context.Background())
	if err != nil || c.AccessKeyID != "STS.x" || c.SecurityToken != "t" {
		t.Fatalf("rrsa creds %+v %v", c, err)
	}

	// ECS instance role, from the metadata service.
	md := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/hub-role") {
			w.WriteHeader(404)
			return
		}
		_, _ = w.Write([]byte(`{"Code":"Success","AccessKeyId":"STS.e","AccessKeySecret":"s","SecurityToken":"t"}`))
	}))
	defer md.Close()
	old := ecsMetadataURL
	ecsMetadataURL = md.URL + "/latest/meta-data/ram/security-credentials/"
	defer func() { ecsMetadataURL = old }()
	p, src, err = CredsFromEnv(env(map[string]string{"ALIBABA_CLOUD_ECS_METADATA": "hub-role"}), nil)
	if err != nil || src != "ecs-role" {
		t.Fatalf("ecs: %s %v", src, err)
	}
	if c, err := p(context.Background()); err != nil || c.AccessKeyID != "STS.e" {
		t.Fatalf("ecs creds %+v %v", c, err)
	}
}
