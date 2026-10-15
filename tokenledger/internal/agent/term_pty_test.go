//go:build unix

package agent

import (
	"bufio"
	"io"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// RunTermPty on a real pseudo-terminal (claude-fleet#3838): the one command runs
// on it, keystrokes and resizes arrive by frame, the output comes back raw, and
// stdin's end hangs the terminal up — nothing of its process group is left.
func TestTermPtyRunsTheOneCommand(t *testing.T) {
	tok := "termpty-" + time.Now().Format("150405.000000")
	old := termAttachArgv
	defer func() { termAttachArgv = old }()
	var gotView, gotTarget string
	termAttachArgv = func(_, view, target string) []string {
		gotView, gotTarget = view, target
		return []string{"/bin/sh", "-c", `stty size; while read l; do case "$l" in size) stty size ;; *) echo "got:$l" ;; esac; done`, tok}
	}
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	done := make(chan int, 1)
	go func() {
		code, _ := RunTermPty([]string{"--view", "web-1", "--target", "worker:fid-1", "--cols", "90", "--rows", "20"}, inR, outW)
		outW.Close()
		done <- code
	}()
	br := bufio.NewReader(outR)
	if b, err := br.ReadByte(); err != nil || b != termPtyReady {
		t.Fatalf("first byte %#x, %v; want ready", b, err)
	}
	if gotView != "web-1" || gotTarget != "worker:fid-1" {
		t.Fatalf("the command got %q %q", gotView, gotTarget)
	}
	// One reader for the whole test: the terminal's output, byte by byte.
	bytesCh := make(chan byte, 1<<16)
	go func() {
		defer close(bytesCh)
		for {
			b, err := br.ReadByte()
			if err != nil {
				return
			}
			bytesCh <- b
		}
	}()
	var seen strings.Builder
	want := func(s string) {
		t.Helper()
		dl := time.After(5 * time.Second)
		for !strings.Contains(seen.String(), s) {
			select {
			case b, ok := <-bytesCh:
				if !ok {
					t.Fatalf("output %q ended before %q", seen.String(), s)
				}
				seen.WriteByte(b)
			case <-dl:
				t.Fatalf("output %q never said %q", seen.String(), s)
			}
		}
	}
	want("20 90")
	inW.Write(termResizeFrame(132, 41))
	inW.Write(termFrame(termFrameData, []byte("size\n")))
	want("41 132")
	inW.Write(termFrame(termFrameData, []byte("你好\n")))
	want("got:你好")
	if out, _ := exec.Command("pgrep", "-f", tok).Output(); len(strings.Fields(string(out))) == 0 {
		t.Fatal("the command is not running")
	}
	inW.Close()
	go func() {
		for range bytesCh {
		}
	}()
	select {
	case <-done:
	case <-time.After(termPtyHangup + 3*time.Second):
		t.Fatal("term-pty did not end after stdin closed")
	}
	if out, _ := exec.Command("pgrep", "-f", tok).Output(); len(strings.Fields(string(out))) != 0 {
		t.Fatalf("processes left after the hang-up: %s", out)
	}
}

func TestTermPtyArgs(t *testing.T) {
	for _, bad := range [][]string{
		{"--view", "web-1"},
		{"--view", "web-1", "--target", "/bin/sh"},
		{"--view", "../x", "--target", "personal"},
		{"--view", "web-1", "--target", "personal", "--exec", "sh"},
		{"--view", "web-1", "--target", "personal", "--cols", "99999", "--rows", "10"},
	} {
		if _, _, _, _, err := termPtyArgs(bad); err == nil {
			t.Errorf("%v accepted", bad)
		}
	}
	if v, tg, _, _, err := termPtyArgs([]string{"--view", "web-ab12", "--target", "personal"}); err != nil || v != "web-ab12" || tg != "personal" {
		t.Fatalf("good args: %q %q %v", v, tg, err)
	}
}

func TestTermPtyLocaleEnv(t *testing.T) {
	for _, tc := range []struct {
		name           string
		env, installed []string
		want           string
	}{
		{"LC_ALL C overrides LANG", []string{"LC_ALL=C", "LANG=zh_CN.UTF-8"}, []string{"C", "zh_CN.utf8"}, "zh_CN.utf8"},
		{"LC_CTYPE C overrides LANG", []string{"LC_CTYPE=C", "LANG=en_US.UTF-8"}, []string{"en_US.UTF-8"}, "en_US.UTF-8"},
		{"LC_ALL precedence", []string{"LC_ALL=zh_CN.UTF-8", "LC_CTYPE=en_US.UTF-8", "LANG=C.UTF-8"}, []string{"C.utf8", "zh_CN.utf8", "en_US.utf8"}, "zh_CN.utf8"},
		{"macOS no C UTF8", []string{"LANG=C"}, []string{"C", "en_US.UTF-8"}, "en_US.UTF-8"},
		{"Linux spelling", nil, []string{"C", "C.utf8"}, "C.utf8"},
		{"uninstalled inherited locale", []string{"LC_ALL=bogus.UTF-8"}, []string{"C", "en_US.UTF-8"}, "en_US.UTF-8"},
		{"no UTF8", nil, []string{"C", "POSIX"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env, err := termPtyLocaleEnv(append(tc.env, "TMUX=wrong", "TMUX_PANE=%1", "TERM=dumb", "KEEP=yes"), tc.installed)
			if tc.want == "" {
				if err == nil {
					t.Fatal("accepted host without UTF-8")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			got := strings.Join(env, "\n")
			for _, key := range []string{"LANG", "LC_CTYPE", "LC_ALL"} {
				if strings.Count(got, key+"=") != 1 || !strings.Contains(got, key+"="+tc.want) {
					t.Fatalf("wrong locale: %v", env)
				}
			}
			if strings.Contains(got, "TMUX") || !strings.Contains(got, "TERM=xterm-256color") || !strings.Contains(got, "KEEP=yes") {
				t.Fatal(env)
			}
		})
	}
}

func TestTermGrantSpentOnce(t *testing.T) {
	var g spentGrants
	now := time.Now()
	if !g.spend("r1", now) {
		t.Fatal("a fresh relay id refused")
	}
	if g.spend("r1", now.Add(time.Minute)) {
		t.Fatal("a relay id spent twice")
	}
	if !g.spend("r1", now.Add(termGrantSpentTTL+time.Second)) {
		t.Fatal("a relay id long expired still remembered")
	}
}
