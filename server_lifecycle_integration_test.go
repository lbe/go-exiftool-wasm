//go:build integration

package exiftool

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func repairJoined(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("old evaluator did not terminate at its host-I/O boundary")
	}
}

func TestV2METARepair_RestartJoinsGeneration(t *testing.T) {
	if repairSubprocess(t, "restart-join") {
		return
	}
	s := repairServer(t)
	old := s.generation.evalDone
	path := filepath.Join(os.Getenv("EXIFTOOL_REPAIR_ROOT"), "storage", "a", "sample.jpg")
	if _, err := s.Command("-Artist", path); err != nil {
		t.Error(err)
	}
	select {
	case <-old:
	default:
		t.Error("replacement started before previous evaluator joined")
	}
	old = s.generation.evalDone
	if err := s.generation.stdinW.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Command("-ver"); err == nil {
		t.Error("closed-stdin command should fail before recovering")
	}
	select {
	case <-old:
	default:
		t.Error("I/O restart installed replacement before previous evaluator joined")
	}
	if _, err := s.Command("-ver"); err != nil {
		t.Fatal(err)
	}
	old = s.generation.evalDone
	if err := s.Shutdown(); err != nil {
		t.Fatal(err)
	}
	repairJoined(t, old)
}

func TestV2METARepair_PipeCloseFirst(t *testing.T) {
	if repairSubprocess(t, "pipe-close-first") {
		return
	}
	s := repairServer(t)
	old := s.generation.evalDone
	// Close the read end before sending any shutdown instruction.
	s.generation.sio.CloseAll()
	repairJoined(t, old)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestV2METARepair_ForceCloseJoinsAtIO(t *testing.T) {
	if repairSubprocess(t, "force-close") {
		return
	}
	s := repairServer(t)
	old := s.generation.evalDone
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	repairJoined(t, old)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Command("-ver"); err == nil {
		t.Fatal("command after close succeeded")
	}
	if err := s.Shutdown(); err == nil {
		t.Fatal("shutdown after close succeeded")
	}
}

type repairShutdownWriter struct {
	io.WriteCloser
	done <-chan struct{}
}

func (w repairShutdownWriter) Write(p []byte) (int, error) {
	n, err := w.WriteCloser.Write(p)
	if err == nil && bytes.Contains(p, []byte("-stay_open\nfalse\n")) {
		// The evaluator acknowledges shutdown while the pipe remains open.
		<-w.done
	}
	return n, err
}

func TestV2METARepair_ShutdownConsumedBeforeClose(t *testing.T) {
	if repairSubprocess(t, "shutdown-first") {
		return
	}
	s := repairServer(t)
	old := s.generation.evalDone
	s.generation.stdinW = repairShutdownWriter{WriteCloser: s.generation.stdinW, done: old}
	if err := s.Shutdown(); err != nil {
		t.Fatal(err)
	}
	repairJoined(t, old)
}

func TestV2METARepair_ScannerErrorsJoin(t *testing.T) {
	if repairSubprocess(t, "scanner-errors") {
		return
	}
	for _, readErr := range []error{io.EOF, errors.New("repair scanner read failure")} {
		s := repairServer(t)
		old := s.generation.evalDone
		s.generation.stdout = newStayOpenStdoutScanner(repairErrorReader{readErr})
		_, err := s.Command("-ver")
		if err == nil {
			t.Error("scanner failure became success")
		}
		if readErr != io.EOF && !errors.Is(err, readErr) {
			t.Errorf("lost scanner error identity: %v", err)
		}
		select {
		case <-old:
		default:
			t.Error("scanner error installed replacement before old evaluator joined")
		}
		if _, err := s.Command("-ver"); err != nil {
			t.Fatal(err)
		}
		if err := s.Shutdown(); err != nil {
			t.Fatal(err)
		}
	}
}

type repairErrorReader struct{ err error }

func (r repairErrorReader) Read([]byte) (int, error) { return 0, r.err }
