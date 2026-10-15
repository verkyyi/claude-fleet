package agent

import (
	"context"
	"errors"
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
		return
	}
	termAttachArgv = func(_, view, target string) []string { return argv(view, target) }
	startTermHelper = inProcessTermHelper
}

var (
	defaultStartTermHelper = startTermHelper
	defaultTermAttachArgv  = termAttachArgv
)

func inProcessTermHelper(_ context.Context, view, target string, cols, rows int) (termHelper, error) {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, err := RunTermPty([]string{"--view", view, "--target", target}, inR, outW)
		outW.CloseWithError(err)
		inR.Close()
	}()
	b := make([]byte, 1)
	if _, err := io.ReadFull(outR, b); err != nil || b[0] != termPtyReady {
		inW.Close()
		<-done
		if err == nil {
			err = errors.New("no ready byte")
		}
		return nil, err
	}
	return &pipeTermHelper{in: inW, out: outR, done: done}, nil
}

type pipeTermHelper struct {
	in   *io.PipeWriter
	out  *io.PipeReader
	done chan struct{}
	once sync.Once
}

func (p *pipeTermHelper) Read(b []byte) (int, error)  { return p.out.Read(b) }
func (p *pipeTermHelper) Write(b []byte) (int, error) { return p.in.Write(b) }
func (p *pipeTermHelper) Close() error {
	p.once.Do(func() {
		p.in.Close()
		go io.Copy(io.Discard, p.out) // drain whatever the terminal still says
		<-p.done
	})
	return nil
}
