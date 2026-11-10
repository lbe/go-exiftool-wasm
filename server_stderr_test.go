package exiftool

import (
	"bytes"
	"fmt"
	"testing"
)

func TestV2METARepair_StderrBoundAndDrain(t *testing.T) {
	s, err := newServerIO()
	if err != nil {
		t.Fatal(err)
	}
	defer s.CloseAll()
	defer s.stdinW.Close()
	defer s.stdoutR.Close()
	payload := bytes.Repeat([]byte{'x'}, 256*1024)
	if n, err := s.WriteStderr(payload); err != nil || n != len(payload) {
		t.Fatalf("write: n=%d err=%v", n, err)
	}
	if got := s.stderrB.Len(); got > 64*1024 {
		t.Errorf("stderr payload retained %d bytes, exceeds 64 KiB", got)
	}
	if got := s.stderrB.Cap(); got > 64*1024 {
		t.Errorf("stderr backing retained %d bytes, exceeds 64 KiB", got)
	}
	_ = s.DrainStderr(0)
	if got := s.stderrB.Len(); got != 0 {
		t.Errorf("drained diagnostics still retain %d bytes", got)
	}
}

func TestV2METARepair_ClosedStdinControlledExit(t *testing.T) {
	for _, closeRead := range []bool{false, true} {
		t.Run(fmt.Sprintf("close-read-%t", closeRead), func(t *testing.T) {
			s, err := newServerIO()
			if err != nil {
				t.Fatal(err)
			}
			defer s.CloseAll()
			defer s.stdoutR.Close()
			if closeRead {
				s.CloseStdin()
			}
			_ = s.stdinW.Close()
			defer func() {
				got := recover()
				if ep, ok := got.(exitPanic); !ok || ep.code != 0 {
					t.Errorf("closed server stdin must produce controlled exit, got %#v", got)
				}
			}()
			_, _ = (&stdinAdapter{gio: s}).Read(make([]byte, 1))
		})
	}
}
