package api

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/netip"
	"os"
	"strings"
)

// The browser's place, for the person's own conversation (claude-fleet#4034).
// The page sends what a browser knows of itself (device, language, time zone);
// the address it came from and the city that address is in are only known
// here, at the entry, so the relayed request carries them as one header the
// entry writes itself — control.ChatClientHeader, next to X-Fleet-Person, and
// like it never taken from the browser. The city comes from an offline
// ip2region database (CCQUOTA_FLEET_CHAT_GEO_DB): nothing is asked of another
// service. No database ⇒ the address alone.

// ChatClient is the header's payload.
type ChatClient struct {
	IP       string `json:"ip,omitempty"`
	Country  string `json:"country,omitempty"`
	Province string `json:"province,omitempty"`
	City     string `json:"city,omitempty"`
}

// chatClientIP is the address a chat request came from: the right-most public
// X-Forwarded-For entry (the one our ingress appended; a replica that handed
// the request over adds a private one), else the socket's peer.
func chatClientIP(r *http.Request) netip.Addr {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			a, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
			if err == nil && !a.IsPrivate() && !a.IsLoopback() && !a.IsLinkLocalUnicast() {
				return a.Unmap()
			}
		}
	}
	ap, err := netip.ParseAddrPort(r.RemoteAddr)
	if err != nil {
		return netip.Addr{}
	}
	return ap.Addr().Unmap()
}

// chatClientHeader is the header's value for r: base64url of ChatClient's
// JSON, "" when the address cannot be told.
func (s *Server) chatClientHeader(r *http.Request) string {
	ip := chatClientIP(r)
	if !ip.IsValid() {
		return ""
	}
	c := ChatClient{IP: ip.String()}
	if db := s.chatGeo(); db != nil {
		c.Country, c.Province, c.City = db.lookup(ip)
	}
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}

// chatGeo loads CCQUOTA_FLEET_CHAT_GEO_DB once (nil: none, or unreadable —
// said once in the log).
func (s *Server) chatGeo() *geoDB {
	s.chatGeoOnce.Do(func() {
		if s.ChatGeoDB == "" {
			return
		}
		db, err := loadGeoDB(s.ChatGeoDB)
		if err != nil {
			log.Printf("chat: city database %s: %v — the address goes without a city", s.ChatGeoDB, err)
			return
		}
		s.chatGeoDB = db
	})
	return s.chatGeoDB
}

// geoDB is an ip2region xdb (IPv4), held in memory (~11 MB).
//
//	header 256 B · vector index 256×256 × (start u32, end u32) · segments of
//	14 B (start ip u32, end ip u32, len u16, ptr u32), all little-endian ·
//	region strings "国家|区域|省份|城市|ISP" (v2) or "国家|省份|城市|ISP|ISO" (v3)
type geoDB struct{ b []byte }

const (
	geoHeader  = 256
	geoVector  = 256 * 256 * 8
	geoSegment = 14
)

func loadGeoDB(path string) (*geoDB, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(b) < geoHeader+geoVector {
		return nil, errors.New("not an ip2region xdb (too short)")
	}
	// v3 headers say the address family at 16..17; an IPv6 database has
	// another segment layout
	if v := binary.LittleEndian.Uint16(b[0:2]); v >= 3 && binary.LittleEndian.Uint16(b[16:18]) == 6 {
		return nil, errors.New("an IPv6 xdb; this reader takes the IPv4 one")
	}
	return &geoDB{b: b}, nil
}

// lookup → country, province, city ("" each when unknown or not IPv4).
func (g *geoDB) lookup(ip netip.Addr) (country, province, city string) {
	region := g.region(ip)
	if region == "" {
		return "", "", ""
	}
	f := strings.Split(region, "|")
	at := func(i int) string {
		if i < len(f) && f[i] != "0" {
			return strings.TrimSpace(f[i])
		}
		return ""
	}
	switch {
	case len(f) == 5 && len(at(4)) == 2 && strings.ToUpper(at(4)) == at(4): // v3: 国家|省份|城市|ISP|ISO
		return at(0), at(1), at(2)
	case len(f) >= 5: // v2: 国家|区域|省份|城市|ISP
		return at(0), at(2), at(3)
	case len(f) == 4: // 国家|省份|城市|ISP
		return at(0), at(1), at(2)
	default:
		return at(0), "", ""
	}
}

func (g *geoDB) region(ip netip.Addr) string {
	if !ip.Is4() {
		return ""
	}
	a := ip.As4()
	v := binary.BigEndian.Uint32(a[:])
	b := g.b
	vi := geoHeader + int(a[0])*256*8 + int(a[1])*8
	sPtr := int(binary.LittleEndian.Uint32(b[vi:]))
	ePtr := int(binary.LittleEndian.Uint32(b[vi+4:]))
	if sPtr <= 0 || ePtr < sPtr || ePtr+geoSegment > len(b) {
		return ""
	}
	lo, hi := 0, (ePtr-sPtr)/geoSegment
	for lo <= hi {
		m := (lo + hi) / 2
		p := sPtr + m*geoSegment
		start := binary.LittleEndian.Uint32(b[p:])
		end := binary.LittleEndian.Uint32(b[p+4:])
		switch {
		case v < start:
			hi = m - 1
		case v > end:
			lo = m + 1
		default:
			n := int(binary.LittleEndian.Uint16(b[p+8:]))
			ptr := int(binary.LittleEndian.Uint32(b[p+10:]))
			if ptr < 0 || ptr+n > len(b) {
				return ""
			}
			return string(b[ptr : ptr+n])
		}
	}
	return ""
}
