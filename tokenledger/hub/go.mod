module github.com/verkyyi/claude-fleet/tokenledger/hub

go 1.25.0

require (
	github.com/coder/websocket v1.8.14
	github.com/google/uuid v1.6.0
	github.com/jackc/pgx/v5 v5.11.0
	github.com/pion/webrtc/v4 v4.2.23
	github.com/verkyyi/claude-fleet/tokenledger/shared v0.0.0
	golang.org/x/crypto v0.52.0
	golang.org/x/net v0.54.0
	modernc.org/sqlite v1.57.0
	rsc.io/qr v0.2.0
)

require (
	github.com/dustin/go-humanize v1.0.1 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/mattn/go-isatty v0.0.24 // indirect
	github.com/ncruces/go-strftime v1.0.0 // indirect
	github.com/pion/datachannel v1.6.3 // indirect
	github.com/pion/dtls/v3 v3.1.10 // indirect
	github.com/pion/ice/v4 v4.4.7 // indirect
	github.com/pion/interceptor v0.1.49 // indirect
	github.com/pion/logging v0.2.4 // indirect
	github.com/pion/mdns/v2 v2.2.2 // indirect
	github.com/pion/randutil v0.1.0 // indirect
	github.com/pion/rtcp v1.2.19 // indirect
	github.com/pion/rtp v1.10.5 // indirect
	github.com/pion/sctp v1.12.0 // indirect
	github.com/pion/sdp/v3 v3.0.20 // indirect
	github.com/pion/srtp/v3 v3.1.3 // indirect
	github.com/pion/stun/v4 v4.0.1 // indirect
	github.com/pion/transport/v5 v5.1.1 // indirect
	github.com/pion/turn/v5 v5.1.2 // indirect
	github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec // indirect
	github.com/wlynxg/anet v0.0.5 // indirect
	golang.org/x/sync v0.21.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.37.0 // indirect
	golang.org/x/time v0.14.0 // indirect
	modernc.org/libc v1.74.4 // indirect
	modernc.org/mathutil v1.7.1 // indirect
	modernc.org/memory v1.11.0 // indirect
)

replace github.com/verkyyi/claude-fleet/tokenledger/shared => ../shared
