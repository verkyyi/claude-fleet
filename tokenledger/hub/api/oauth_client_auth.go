package api

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Client authentication at the token endpoint (task T4DN): a metadata-document
// client that says token_endpoint_auth_method private_key_jwt — ChatGPT's does
// — proves itself with an RFC 7523 client assertion, an RS256 JWT signed by a
// key it publishes (jwks_uri, fetched public-only like the document, or inline
// jwks). Then a code or refresh token that leaked is worth nothing without the
// client's private key, on top of PKCE. The client's own declared method is
// held to: a document that prefers private_key_jwt must send an assertion; one
// that says none (or a registered DCR client) sends none, and an assertion it
// sends anyway is still verified, never ignored.
//
//	iss = sub = client_id · aud ∋ the token endpoint (or the issuer) ·
//	exp ≤ 1 h ahead and not past · jti, when sent, once (fleet_oauth_tokens, every replica)
const (
	privateKeyJWT       = "private_key_jwt"
	jwtBearerAssertion  = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
	assertionMaxLife    = time.Hour
	assertionClockSkew  = 60 * time.Second
	clientJWKSTTL       = 10 * time.Minute
	clientJWKSMaxBytes  = 64 << 10
	clientJWKSRefetchIn = time.Minute
)

// jwksFetch fetches a client's published keys; a test swaps it.
var jwksFetch = func(ctx context.Context, u string) ([]byte, error) {
	if !isCIMD(u) {
		return nil, errors.New("jwks_uri must be an https URL")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := cimdClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks_uri answered %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, clientJWKSMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) > clientJWKSMaxBytes {
		return nil, errors.New("jwks over 64 KB")
	}
	return b, nil
}

type clientKeys struct {
	keys map[string]*rsa.PublicKey
	at   time.Time
}

var clientJWKS sync.Map // jwks_uri → clientKeys

// clientKey is the client's key kid: from its inline jwks, else its jwks_uri
// (kept clientJWKSTTL; an unknown kid refetches at most once a minute, so a
// rotated key is picked up and a forged kid cannot make the hub hammer it).
func clientKey(ctx context.Context, doc cimdDoc, kid string) (*rsa.PublicKey, error) {
	if len(doc.JWKS) > 0 {
		keys, err := parseJWKS(doc.JWKS)
		if err != nil {
			return nil, fmt.Errorf("the client's jwks: %v", err)
		}
		if k := keys[kid]; k != nil {
			return k, nil
		}
		return nil, fmt.Errorf("unknown key id %q", kid)
	}
	if doc.JWKSURI == "" {
		return nil, errors.New("the client publishes no keys (jwks_uri)")
	}
	if e, ok := clientJWKS.Load(doc.JWKSURI); ok {
		ck := e.(clientKeys)
		if k := ck.keys[kid]; k != nil && time.Since(ck.at) < clientJWKSTTL {
			return k, nil
		}
		if ck.keys[kid] == nil && time.Since(ck.at) < clientJWKSRefetchIn {
			return nil, fmt.Errorf("unknown key id %q", kid)
		}
	}
	b, err := jwksFetch(ctx, doc.JWKSURI)
	if err != nil {
		return nil, fmt.Errorf("the client's keys: %v", err)
	}
	keys, err := parseJWKS(b)
	if err != nil {
		return nil, fmt.Errorf("the client's keys: %v", err)
	}
	clientJWKS.Store(doc.JWKSURI, clientKeys{keys, time.Now()})
	if k := keys[kid]; k != nil {
		return k, nil
	}
	return nil, fmt.Errorf("unknown key id %q", kid)
}

type assertionClaims struct {
	Iss string          `json:"iss"`
	Sub string          `json:"sub"`
	Aud json.RawMessage `json:"aud"`
	Exp int64           `json:"exp"`
	Iat int64           `json:"iat"`
	Nbf int64           `json:"nbf"`
	Jti string          `json:"jti"`
}

func (c assertionClaims) audIn(want ...string) bool {
	var auds []string
	var one string
	if json.Unmarshal(c.Aud, &one) == nil {
		auds = []string{one}
	} else {
		_ = json.Unmarshal(c.Aud, &auds)
	}
	for _, a := range auds {
		for _, w := range want {
			if strings.TrimRight(a, "/") == strings.TrimRight(w, "/") {
				return true
			}
		}
	}
	return false
}

// assertionIssuer reads a client assertion's iss without trusting it — only
// to know which client's keys to verify it with.
func assertionIssuer(tok string) string {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return ""
	}
	pb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var c assertionClaims
	_ = json.Unmarshal(pb, &c)
	return c.Iss
}

// verifyAssertion checks one client assertion for clientID.
func (s *Server) verifyAssertion(ctx context.Context, doc cimdDoc, clientID, tok, tokenURL, issuer string, now time.Time) error {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return errors.New("client_assertion is not a JWT")
	}
	hb, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return errors.New("client_assertion: bad header")
	}
	var hd struct{ Alg, Kid string }
	if json.Unmarshal(hb, &hd) != nil || hd.Alg != "RS256" {
		return fmt.Errorf("client_assertion: alg %q, want RS256", hd.Alg)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return errors.New("client_assertion: bad signature encoding")
	}
	pub, err := clientKey(ctx, doc, hd.Kid)
	if err != nil {
		return err
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig) != nil {
		return errors.New("client_assertion: signature does not verify")
	}
	pb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return errors.New("client_assertion: bad payload")
	}
	var c assertionClaims
	if err := json.Unmarshal(pb, &c); err != nil {
		return errors.New("client_assertion: bad claims")
	}
	n := now.Unix()
	switch {
	case c.Iss != clientID || c.Sub != clientID:
		return errors.New("client_assertion: iss and sub must be the client_id")
	case !c.audIn(tokenURL, issuer, issuer+"/mcp"):
		return fmt.Errorf("client_assertion: aud %s is not this server's (%s)", string(c.Aud), tokenURL)
	case c.Exp == 0 || n > c.Exp+int64(assertionClockSkew/time.Second):
		return errors.New("client_assertion: expired")
	case c.Exp > n+int64((assertionMaxLife+assertionClockSkew)/time.Second):
		return errors.New("client_assertion: lives longer than an hour")
	case c.Nbf != 0 && n+int64(assertionClockSkew/time.Second) < c.Nbf:
		return errors.New("client_assertion: not valid yet")
	case len(c.Jti) > 256:
		return errors.New("client_assertion: jti too long")
	}
	// once, on every replica: the jti's hash is a row until it expires (RFC
	// 7523 makes jti optional; without one, the short life is the bound)
	if c.Jti == "" {
		return nil
	}
	if err := s.Store.PutOAuthToken(HashToken("jti\x00"+clientID+"\x00"+c.Jti), "", "jti",
		time.Unix(c.Exp, 0).Add(assertionClockSkew)); err != nil {
		return errors.New("client_assertion: jti already used")
	}
	return nil
}

// clientAuth authenticates the token request's client and returns its id.
// The id comes from client_id, else the assertion's iss; a form whose two
// disagree is refused.
func (s *Server) clientAuth(r *http.Request, now time.Time) (string, error) {
	f := r.PostForm
	clientID, assertion := f.Get("client_id"), f.Get("client_assertion")
	if assertion != "" && f.Get("client_assertion_type") != jwtBearerAssertion {
		return "", errors.New("client_assertion_type must be " + jwtBearerAssertion)
	}
	if assertion != "" {
		if iss := assertionIssuer(assertion); clientID == "" {
			clientID = iss
		} else if iss != clientID {
			return "", errors.New("client_assertion names another client")
		}
	}
	if clientID == "" {
		return "", errors.New("client_id is required")
	}
	if !isCIMD(clientID) {
		// a registered (DCR) client is public: no assertion is ours to verify
		if assertion != "" {
			return "", errors.New("this client registered no keys; send no client_assertion")
		}
		return clientID, nil
	}
	doc, err := cimdDocument(r.Context(), clientID, false)
	if err != nil {
		return "", err
	}
	if assertion == "" {
		if doc.AuthMethod == privateKeyJWT {
			return "", errors.New("this client authenticates with private_key_jwt: send client_assertion")
		}
		return clientID, nil
	}
	base := s.oauthIssuer(r)
	if err := s.verifyAssertion(r.Context(), doc, clientID, assertion, base+OAuthTokenPath, base, now); err != nil {
		return "", err
	}
	return clientID, nil
}
