package exiftool

import (
	"bufio"
	"bytes"
	"io"
	"testing"
)

func TestSplitReadyToken(t *testing.T) {
	data := []byte("output line 1\noutput line 2\n{ready1854673209}\n")
	advance, token, err := splitReadyToken(data, false)
	if err != nil {
		t.Fatal(err)
	}
	if advance != len(data) {
		t.Errorf("advance: got %d, want %d", advance, len(data))
	}
	if got, want := string(token), "output line 1\noutput line 2\n"; got != want {
		t.Errorf("token: got %q, want %q", got, want)
	}
}

func TestSplitReadyTokenPartial(t *testing.T) {
	// No ready token in data
	data := []byte("output line 1\n")
	advance, token, err := splitReadyToken(data, false)
	if err != nil {
		t.Fatal(err)
	}
	if advance != 0 {
		t.Errorf("advance: got %d, want 0", advance)
	}
	if token != nil {
		t.Errorf("token: got %q, want nil", token)
	}
}

func TestSplitReadyTokenAtEOF(t *testing.T) {
	// Data without ready token at EOF
	data := []byte("output line 1\n")
	advance, token, err := splitReadyToken(data, true)
	if err != io.EOF {
		t.Errorf("err: got %v, want io.EOF", err)
	}
	if advance != 0 {
		t.Errorf("advance: got %d, want 0", advance)
	}
	if got, want := string(token), "output line 1\n"; got != want {
		t.Errorf("token: got %q, want %q", got, want)
	}
}

func TestSplitReadyTokenAtEOFWithToken(t *testing.T) {
	data := []byte("output\n{ready1854673209}\n")
	advance, token, err := splitReadyToken(data, true)
	if err != bufio.ErrFinalToken {
		t.Errorf("err: got %v, want bufio.ErrFinalToken", err)
	}
	if got, want := string(token), "output\n"; got != want {
		t.Errorf("token: got %q, want %q", got, want)
	}
	_ = advance
}

func TestSplitReadyTokenEmpty(t *testing.T) {
	data := []byte("")
	advance, token, err := splitReadyToken(data, false)
	if err != nil {
		t.Fatal(err)
	}
	if advance != 0 {
		t.Errorf("advance: got %d, want 0", advance)
	}
	if token != nil {
		t.Errorf("token: got %q, want nil", token)
	}
}

func TestSplitReadyTokenEmptyAtEOF(t *testing.T) {
	data := []byte("")
	advance, token, err := splitReadyToken(data, true)
	if err != io.EOF {
		t.Errorf("err: got %v, want io.EOF", err)
	}
	if advance != 0 {
		t.Errorf("advance: got %d, want 0", advance)
	}
	if len(token) != 0 {
		t.Errorf("token: got %q, want empty", token)
	}
}

func TestSplitReadyTokenOnlyToken(t *testing.T) {
	data := []byte("{ready1854673209}\n")
	advance, token, err := splitReadyToken(data, false)
	if err != nil {
		t.Fatal(err)
	}
	if advance != len(data) {
		t.Errorf("advance: got %d, want %d", advance, len(data))
	}
	if len(token) != 0 {
		t.Errorf("token: got %q, want empty", token)
	}
}

func TestSplitReadyTokenMultipleTokens(t *testing.T) {
	// First call should return the first token
	data := []byte("first\n{ready1854673209}\nsecond\n{ready1854673209}\n")
	advance, token, err := splitReadyToken(data, false)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(token), "first\n"; got != want {
		t.Errorf("first token: got %q, want %q", got, want)
	}

	// Process remaining data
	remaining := data[advance:]
	advance2, token2, err2 := splitReadyToken(remaining, false)
	if err2 != nil {
		t.Fatal(err2)
	}
	if got, want := string(token2), "second\n"; got != want {
		t.Errorf("second token: got %q, want %q", got, want)
	}
	_ = advance2
}

func TestSplitReadyTokenNoNewlineAfterToken(t *testing.T) {
	// Ready token without trailing newline - should not match
	data := []byte("output\n{ready1854673209}")
	advance, token, err := splitReadyToken(data, false)
	if err != nil {
		t.Fatal(err)
	}
	if advance != 0 {
		t.Errorf("advance: got %d, want 0", advance)
	}
	if token != nil {
		t.Errorf("token: got %q, want nil", token)
	}
}

func TestSplitReadyTokenWithStderr(t *testing.T) {
	// Simulates stderr output before ready token
	data := []byte("Warning: some warning\n{ready1854673209}\n")
	advance, token, err := splitReadyToken(data, false)
	if err != nil {
		t.Fatal(err)
	}
	if advance == 0 {
		t.Error("expected non-zero advance")
	}
	if got, want := string(token), "Warning: some warning\n"; got != want {
		t.Errorf("token: got %q, want %q", got, want)
	}
}

func TestScannerWithSplitReadyToken(t *testing.T) {
	data := []byte("line1\nline2\n{ready1854673209}\n")
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Split(splitReadyToken)

	if !scanner.Scan() {
		t.Fatal("expected scan to succeed")
	}
	if got, want := scanner.Text(), "line1\nline2\n"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestScannerWithSplitReadyTokenMultiple(t *testing.T) {
	data := []byte("first\n{ready1854673209}\nsecond\n{ready1854673209}\n")
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Split(splitReadyToken)

	// First scan
	if !scanner.Scan() {
		t.Fatal("first scan failed")
	}
	if got, want := scanner.Text(), "first\n"; got != want {
		t.Errorf("first: got %q, want %q", got, want)
	}

	// Second scan
	if !scanner.Scan() {
		t.Fatal("second scan failed")
	}
	if got, want := scanner.Text(), "second\n"; got != want {
		t.Errorf("second: got %q, want %q", got, want)
	}
}
