package attachment

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/pion/webrtc/v4"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Fingerprint validates a complete, non-trickled data-only SDP. Candidates are
// bounded in the SDP rather than an unbounded stream of signaling messages.
// TURN is intentionally unsupported: a relay pair must never be called direct.
func Fingerprint(sdp string) (string, error) {
	bad := errors.New("invalid or oversized data-channel SDP")
	if len(sdp) == 0 || len(sdp) > SDPMax {
		return "", bad
	}
	var fingerprint string
	media, candidates := 0, 0
	for _, line := range strings.Split(strings.ReplaceAll(sdp, "\r\n", "\n"), "\n") {
		if len(line) > 2048 {
			return "", bad
		}
		if strings.HasPrefix(line, "m=") {
			media++
			if !strings.HasPrefix(line, "m=application ") || !strings.Contains(line, "UDP/DTLS/SCTP") {
				return "", bad
			}
		}
		if strings.HasPrefix(line, "a=fingerprint:") {
			fp, ok := strings.CutPrefix(line, "a=fingerprint:sha-256 ")
			fp = strings.ToUpper(fp)
			if !ok || !control.ValidPeerFingerprint(fp) || (fingerprint != "" && fingerprint != fp) {
				return "", bad
			}
			fingerprint = fp
		}
		if strings.HasPrefix(line, "a=candidate:") {
			candidates++
			f := strings.Fields(line)
			if len(f) < 8 || !strings.EqualFold(f[2], "udp") || f[6] != "typ" || (f[7] != "host" && f[7] != "srflx" && f[7] != "prflx") {
				return "", bad
			}
		}
	}
	if media != 1 || fingerprint == "" || candidates > CandidateMax {
		return "", bad
	}
	return fingerprint, nil
}

func ICEConfig(stun []string) (webrtc.Configuration, error) {
	var cfg webrtc.Configuration
	if len(stun) > 4 {
		return cfg, errors.New("at most four explicit STUN endpoints")
	}
	for _, u := range stun {
		if len(u) > 256 || !strings.HasPrefix(u, "stun:") || len(u) <= 5 || strings.ContainsAny(u, "@/?#\r\n\t ") {
			return cfg, errors.New("only credential-free stun: endpoints are supported")
		}
		cfg.ICEServers = append(cfg.ICEServers, webrtc.ICEServer{URLs: []string{u}})
	}
	return cfg, nil
}

type frame struct {
	typ  websocket.MessageType
	data []byte
}

// Peer owns all on-demand ICE sockets. Closing it is idempotent and closes only
// this attachment. A slow reader/writer fails closed at bounded memory.
type Peer struct {
	pc        *webrtc.PeerConnection
	mu        sync.Mutex
	dc        *webrtc.DataChannel
	in        chan frame
	ready     chan struct{}
	done      chan struct{}
	once      sync.Once
	readyOnce sync.Once
	writeMu   sync.Mutex
	armed     bool
}

func Answer(ctx context.Context, offer string, stun []string) (*Peer, string, error) {
	if _, err := Fingerprint(offer); err != nil {
		return nil, "", err
	}
	cfg, err := ICEConfig(stun)
	if err != nil {
		return nil, "", err
	}
	se := webrtc.SettingEngine{}
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6})
	se.SetSCTPMaxReceiveBufferSize(BufferMax)
	se.SetSCTPMaxMessageSize(FrameMax)
	se.SetICETimeouts(5*time.Second, 5*time.Second, time.Second)
	pc, err := webrtc.NewAPI(webrtc.WithSettingEngine(se)).NewPeerConnection(cfg)
	if err != nil {
		return nil, "", err
	}
	p := &Peer{pc: pc, in: make(chan frame, BufferMax/FrameMax), ready: make(chan struct{}), done: make(chan struct{})}
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		if s == webrtc.PeerConnectionStateFailed || s == webrtc.PeerConnectionStateClosed || s == webrtc.PeerConnectionStateDisconnected {
			go p.Close()
		}
	})
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		p.mu.Lock()
		valid := p.dc == nil && dc.Label() == ChannelLabel && dc.Protocol() == ChannelLabel && dc.Ordered() && dc.MaxRetransmits() == nil && dc.MaxPacketLifeTime() == nil
		if valid {
			p.dc = dc
		}
		p.mu.Unlock()
		if !valid {
			go p.Close()
			return
		}
		dc.OnOpen(func() { p.readyOnce.Do(func() { close(p.ready) }) })
		dc.OnClose(func() { go p.Close() })
		dc.OnError(func(error) { go p.Close() })
		dc.OnMessage(func(m webrtc.DataChannelMessage) {
			p.mu.Lock()
			armed := p.armed
			p.mu.Unlock()
			if !armed {
				go p.Close()
				return
			}
			if len(m.Data) > FrameMax {
				go p.Close()
				return
			}
			t := websocket.MessageBinary
			if m.IsString {
				t = websocket.MessageText
			}
			// A short keystroke burst can fill eight frames while the PTY is
			// checking its lease. Bound memory and wait briefly for the consumer;
			// an actually stalled reader still closes, without dropping live input.
			timer := time.NewTimer(2 * time.Second)
			defer timer.Stop()
			select {
			case <-p.done:
			case p.in <- frame{t, append([]byte(nil), m.Data...)}:
			case <-timer.C:
				go p.Close()
			}
		})
	})
	fail := func(err error) (*Peer, string, error) { p.Close(); return nil, "", err }
	if err = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); err != nil {
		return fail(err)
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return fail(err)
	}
	gather := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(answer); err != nil {
		return fail(err)
	}
	select {
	case <-ctx.Done():
		return fail(ctx.Err())
	case <-p.done:
		return fail(ErrClosed)
	case <-gather:
	}
	sdp := pc.LocalDescription().SDP
	if _, err = Fingerprint(sdp); err != nil {
		return fail(err)
	}
	return p, sdp, nil
}

func (p *Peer) Wait(ctx context.Context) error {
	select {
	case <-p.done:
		return ErrClosed
	case <-ctx.Done():
		return ctx.Err()
	case <-p.ready:
		return nil
	}
}

// Arm permits service data only once authority has been committed and the
// adapter is about to emit ready. Data received while signaling is rejected.
func (p *Peer) Arm() { p.mu.Lock(); p.armed = true; p.mu.Unlock() }

func (p *Peer) Read(ctx context.Context) (websocket.MessageType, []byte, error) {
	select {
	case <-p.done:
		return 0, nil, ErrClosed
	default:
	}
	select {
	case <-ctx.Done():
		return 0, nil, ctx.Err()
	case <-p.done:
		return 0, nil, ErrClosed
	case f := <-p.in:
		return f.typ, f.data, nil
	}
}

func (p *Peer) Write(ctx context.Context, t websocket.MessageType, b []byte) error {
	if len(b) > FrameMax {
		return errors.New("attachment frame too large")
	}
	if err := p.Wait(ctx); err != nil {
		return err
	}
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	p.mu.Lock()
	dc := p.dc
	p.mu.Unlock()
	if dc == nil {
		return ErrClosed
	}
	if dc.BufferedAmount()+uint64(len(b)) > BufferMax {
		return ErrBackpressure
	}
	if t == websocket.MessageText {
		return dc.SendText(string(b))
	}
	if t != websocket.MessageBinary {
		return errors.New("unknown frame type")
	}
	return dc.Send(b)
}

func (p *Peer) Pair() (string, error) {
	sctp := p.pc.SCTP()
	if sctp == nil || sctp.Transport() == nil {
		return "", ErrClosed
	}
	pair, err := sctp.Transport().ICETransport().GetSelectedCandidatePair()
	if err != nil || pair == nil {
		return "", errors.New("no selected candidate pair")
	}
	if pair.Local.Typ == webrtc.ICECandidateTypeRelay || pair.Remote.Typ == webrtc.ICECandidateTypeRelay {
		return "", errors.New("relay candidate is not direct")
	}
	return fmt.Sprintf("%s/%s", pair.Local.Typ, pair.Remote.Typ), nil
}

func (p *Peer) Close() error {
	var err error
	p.once.Do(func() { close(p.done); err = p.pc.Close() })
	return err
}
