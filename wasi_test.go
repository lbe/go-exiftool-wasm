package exiftool

import (
	"context"
	"testing"
	"time"
)

// panicsWithCancel reports whether f panics with cancelPanic.
func panicsWithCancel(f func()) (canceled bool) {
	defer func() {
		_, canceled = recover().(cancelPanic)
	}()
	f()
	return false
}

func TestWASIStateNanosleepWithoutCancelSleeps(t *testing.T) {
	ws := &wasiState{ctx: context.Background()}
	start := time.Now()
	if panicsWithCancel(func() { ws.nanosleep(int64(5 * time.Millisecond)) }) {
		t.Fatal("nanosleep panicked with cancelPanic under context.Background")
	}
	if elapsed := time.Since(start); elapsed < 5*time.Millisecond {
		t.Errorf("nanosleep returned after %v, want at least 5ms", elapsed)
	}
}

func TestWASIStateNanosleepStopsWhenContextIsDone(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	ws := &wasiState{ctx: ctx}
	start := time.Now()
	if !panicsWithCancel(func() { ws.nanosleep(int64(time.Hour)) }) {
		t.Fatal("nanosleep did not panic with cancelPanic")
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("nanosleep stopped after %v, want well under 5s", elapsed)
	}
}

func TestWASIStateCheckCanceled(t *testing.T) {
	if panicsWithCancel((&wasiState{ctx: context.Background()}).checkCanceled) {
		t.Error("checkCanceled panicked under context.Background")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if !panicsWithCancel((&wasiState{ctx: ctx}).checkCanceled) {
		t.Error("checkCanceled did not panic after cancel")
	}
}
