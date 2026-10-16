package attachment

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/pion/webrtc/v4"
)

func TestAttachmentSDPLimits(t *testing.T) {
	fp := strings.TrimSuffix(strings.Repeat("AB:", 32), ":")
	sdp := "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=fingerprint:sha-256 " + fp + "\r\n"
	if got, err := Fingerprint(sdp); err != nil || got != fp {
		t.Fatal(got, err)
	}
	for _, s := range []string{
		sdp + strings.Repeat("a=candidate:1 1 udp 1 192.0.2.1 9 typ host\r\n", CandidateMax+1),
		sdp + "a=candidate:1 1 udp 1 192.0.2.1 9 typ relay\r\n",
		sdp + "m=audio 9 RTP/AVP 0\r\n",
		sdp + "a=fingerprint:sha-256 " + strings.ReplaceAll(fp, "AB", "CD") + "\r\n",
		strings.Repeat(" ", SDPMax+1),
	} {
		if _, err := Fingerprint(s); err == nil {
			t.Fatal("accepted invalid SDP")
		}
	}
	for _, urls := range [][]string{{"turn:example.com"}, {"stun:user:pass@example.com"}, {"http://example.com"}, {"stun:"}} {
		if _, err := ICEConfig(urls); err == nil {
			t.Fatal("accepted invalid ICE configuration", urls)
		}
	}
}

func TestAttachmentBackpressureAndEarlyData(t *testing.T) {
	for _, mode := range []string{"before-ready", "slow-reader", "short-burst"} {
		t.Run(mode, func(t *testing.T) {
			early := mode == "before-ready"
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			client, err := webrtc.NewPeerConnection(webrtc.Configuration{})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			proto := ChannelLabel
			dc, err := client.CreateDataChannel(proto, &webrtc.DataChannelInit{Protocol: &proto})
			if err != nil {
				t.Fatal(err)
			}
			opened := make(chan struct{})
			dc.OnOpen(func() { close(opened) })
			offer, err := client.CreateOffer(nil)
			if err != nil {
				t.Fatal(err)
			}
			gather := webrtc.GatheringCompletePromise(client)
			if err = client.SetLocalDescription(offer); err != nil {
				t.Fatal(err)
			}
			select {
			case <-gather:
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			peer, answer, err := Answer(ctx, client.LocalDescription().SDP, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer peer.Close()
			if err = client.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); err != nil {
				t.Fatal(err)
			}
			select {
			case <-opened:
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			if !early {
				peer.Arm()
				if err = peer.Write(ctx, websocket.MessageBinary, make([]byte, FrameMax+1)); err == nil {
					t.Fatal("oversized write accepted")
				}
			}
			count := 1
			if !early {
				count = 10
			}
			data := make([]byte, FrameMax)
			if mode == "short-burst" {
				count, data = 50, []byte("x")
			}
			for i := 0; i < count; i++ {
				if err = dc.Send(data); err != nil {
					break
				}
			}
			if mode == "short-burst" {
				time.Sleep(100 * time.Millisecond) // the PTY is briefly busy checking its lease
				for i := 0; i < count; i++ {
					typ, b, err := peer.Read(ctx)
					if err != nil || typ != websocket.MessageBinary || string(b) != "x" {
						t.Fatalf("burst frame %d: %q %v", i, b, err)
					}
				}
				return
			}
			select {
			case <-peer.done:
			case <-ctx.Done():
				t.Fatal("unbounded input or signaling accepted data")
			}
			if len(peer.in) > BufferMax/FrameMax {
				t.Fatal("buffer exceeded bound")
			}
		})
	}
}
