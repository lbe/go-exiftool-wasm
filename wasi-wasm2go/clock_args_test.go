package wasihost

import (
	"encoding/binary"
	"testing"
	"time"
)

func TestClockAndArgQueries(t *testing.T) {
	const (
		clockOff   = 100
		argcOff    = 200
		argvSzOff  = 208
		argvOff    = 300
		argvBufOff = 400
	)

	t.Run("Xclock_time_get realtime returns value > Jan 1 2020", func(t *testing.T) {
		s, buf := newTestState()
		errno := s.Xclock_time_get(0, 0, clockOff)
		if errno != wasiESuccess {
			t.Fatalf("Xclock_time_get(0) returned %d, want ESUCCESS", errno)
		}
		got := binary.LittleEndian.Uint64(buf[clockOff : clockOff+8])
		const jan2020 = uint64(1577836800000000000) // Jan 1, 2020 in nanoseconds
		if got <= jan2020 {
			t.Errorf("Xclock_time_get(0) wrote %d, want > %d", got, jan2020)
		}
	})

	t.Run("Xclock_time_get monotonic is non-decreasing", func(t *testing.T) {
		s, buf := newTestState()
		s.startTime = time.Now()
		errno := s.Xclock_time_get(1, 0, clockOff)
		if errno != wasiESuccess {
			t.Fatalf("Xclock_time_get(1) returned %d, want ESUCCESS", errno)
		}
		v1 := binary.LittleEndian.Uint64(buf[clockOff : clockOff+8])
		_ = s.Xclock_time_get(1, 0, clockOff)
		v2 := binary.LittleEndian.Uint64(buf[clockOff : clockOff+8])
		if v2 < v1 {
			t.Errorf("monotonic decreased: %d then %d", v1, v2)
		}
	})

	t.Run("Xclock_time_get unknown clock returns ENOSYS", func(t *testing.T) {
		s, _ := newTestState()
		errno := s.Xclock_time_get(99, 0, clockOff)
		if errno != wasiENoSys {
			t.Errorf("got %d, want ENOSYS (%d)", errno, wasiENoSys)
		}
	})

	t.Run("Xclock_res_get known clocks write 1 and return ESUCCESS", func(t *testing.T) {
		for _, id := range []int32{0, 1} {
			s, buf := newTestState()
			errno := s.Xclock_res_get(id, clockOff)
			if errno != wasiESuccess {
				t.Errorf("Xclock_res_get(%d) returned %d, want ESUCCESS", id, errno)
			}
			got := binary.LittleEndian.Uint64(buf[clockOff : clockOff+8])
			if got != 1 {
				t.Errorf("Xclock_res_get(%d) wrote %d, want 1", id, got)
			}
		}
	})

	t.Run("Xclock_res_get unknown clock returns ENOSYS", func(t *testing.T) {
		s, _ := newTestState()
		errno := s.Xclock_res_get(99, clockOff)
		if errno != wasiENoSys {
			t.Errorf("got %d, want ENOSYS (%d)", errno, wasiENoSys)
		}
	})

	t.Run("Xargs_sizes_get writes count and buf_size", func(t *testing.T) {
		s, buf := newTestState()
		s.args = []string{"prog", "--flag", "val"}
		errno := s.Xargs_sizes_get(argcOff, argvSzOff)
		if errno != wasiESuccess {
			t.Fatalf("Xargs_sizes_get returned %d, want ESUCCESS", errno)
		}
		count := binary.LittleEndian.Uint32(buf[argcOff : argcOff+4])
		size := binary.LittleEndian.Uint32(buf[argvSzOff : argvSzOff+4])
		if count != 3 {
			t.Errorf("got count %d, want 3", count)
		}
		if size != 16 {
			t.Errorf("got buf_size %d, want 16", size)
		}
	})

	t.Run("Xargs_get writes pointer array and null-terminated strings", func(t *testing.T) {
		s, buf := newTestState()
		s.args = []string{"prog", "--flag", "val"}
		_ = s.Xargs_get(argvOff, argvBufOff)
		// Check pointer array
		p0 := binary.LittleEndian.Uint32(buf[argvOff : argvOff+4])
		p1 := binary.LittleEndian.Uint32(buf[argvOff+4 : argvOff+8])
		p2 := binary.LittleEndian.Uint32(buf[argvOff+8 : argvOff+12])
		if p0 != uint32(argvBufOff) {
			t.Errorf("p0 = %d, want %d", p0, argvBufOff)
		}
		if p1 != uint32(argvBufOff+5) { // "prog\0" = 5 bytes
			t.Errorf("p1 = %d, want %d", p1, argvBufOff+5)
		}
		if p2 != uint32(argvBufOff+12) { // "prog\0"+"--flag\0" = 5+7 = 12
			t.Errorf("p2 = %d, want %d", p2, argvBufOff+12)
		}
		// Check strings
		prog := string(buf[argvBufOff : argvBufOff+5])
		flag := string(buf[argvBufOff+5 : argvBufOff+12])
		val  := string(buf[argvBufOff+12 : argvBufOff+16])
		if prog != "prog\x00" {
			t.Errorf("got prog %q, want %q", prog, "prog\x00")
		}
		if flag != "--flag\x00" {
			t.Errorf("got flag %q, want %q", flag, "--flag\x00")
		}
		if val != "val\x00" {
			t.Errorf("got val %q, want %q", val, "val\x00")
		}
	})
}
