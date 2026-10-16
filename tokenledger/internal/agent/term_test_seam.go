package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"io"
	"sync"
)

// SetTermHelperForTest runs every terminal's helper in THIS process — the real
// RunTermPty, on a real pseudo-terminal — with argv(view, target) as the one
// command instead of fleet-term-attach.sh; nil puts both back. For the hub's
// end-to-end tests only (a test binary is no `ccquota`, so it cannot be the
// helper's executable).
func SetTermHelperForTest(argv func(view, target string) []string) {
	if argv == nil {
		startTermHelper, termAttachArgv = defaultStartTermHelper, defaultTermAttachArgv
		readTermAdmission = defaultReadTermAdmission
		return
	}
	readTermAdmission = func(io.Reader) (termController, error) {
		return termController{Term: "isolated", Gen: "isolated:1", Epoch: 1}, nil
	}
	termAttachArgv = func(_, view, target string) []string { return argv(view, target) }
	startTermHelper = inProcessTermHelper
}

var (
	defaultReadTermAdmission = readTermAdmission
	defaultStartTermHelper   = startTermHelper
	defaultTermAttachArgv    = termAttachArgv
)

// SetNativeTermHelperForTest keeps the real admission and epoch gate; the fixed
// entry is supplied by an isolated HOME/socket fixture, never a live account.
func SetNativeTermHelperForTest(argv func(view, target string) []string) {
	SetTermHelperForTest(argv)
	readTermAdmission = defaultReadTermAdmission
}

func inProcessTermHelper(ctx context.Context, view, target string, cols, rows int) (termHelper, error) {
	ctx, cancel := context.WithCancel(ctx)
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		args := []string{"--view", view, "--target", target}
		if req, ok := ctx.Value(termRequestKey{}).(termRequest); ok {
			if req.Resume != "" {
				args = append(args, "--resume", req.Resume)
			}
			if req.Renew {
				args = append(args, "--renew", "1")
			}
			if req.Take {
				args = append(args, "--take", "1")
			}
		}
		_, err := runTermPty(ctx, args, inR, outW)
		outW.CloseWithError(err)
		inR.Close()
	}()
	b := make([]byte, 1)
	if _, err := io.ReadFull(outR, b); err != nil || b[0] != termPtyReady {
		cancel()
		inW.Close()
		<-done
		if err == nil {
			err = errors.New("no ready byte")
		}
		return nil, err
	}
	reader := bufio.NewReader(outR)
	line, err := reader.ReadBytes('\n')
	var ready control.TermControl
	if err != nil || json.Unmarshal(line, &ready) != nil {
		cancel()
		inW.Close()
		return nil, errors.New("invalid ready")
	}
	if ready.T != "ready" {
		cancel()
		inW.Close()
		outR.Close()
		<-done
		return nil, &termAdmissionFailure{ready}
	}
	return &pipeTermHelper{in: inW, out: reader, output: outR, done: done, ready: ready, cancel: cancel}, nil
}

type pipeTermHelper struct {
	in     *io.PipeWriter
	out    io.Reader
	output io.Closer
	ready  control.TermControl
	done   chan struct{}
	once   sync.Once
	cancel context.CancelFunc
}

func (p *pipeTermHelper) Ready() control.TermControl  { return p.ready }
func (p *pipeTermHelper) Read(b []byte) (int, error)  { return p.out.Read(b) }
func (p *pipeTermHelper) Write(b []byte) (int, error) { return p.in.Write(b) }
func (p *pipeTermHelper) Close() error {
	p.once.Do(func() {
		p.cancel()
		p.in.Close()
		p.output.Close()
		<-p.done
	})
	return nil
}
