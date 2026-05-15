package wasihost

import (
	"encoding/binary"
	"io"
	"io/fs"
	"testing"
)

type stubFSFile struct{}

func (stubFSFile) Read(_ []byte) (int, error) { return 0, io.EOF }
func (stubFSFile) Stat() (fs.FileInfo, error)  { return nil, nil }
func (stubFSFile) Close() error                { return nil }

func newTestState(opts ...Option) (*State, []byte) {
	buf := make([]byte, 65536)
	s := New(func() []byte { return buf }, opts...)
	return s, buf
}

func TestGroupAFoundation(t *testing.T) {
	const (
		countOff    = 100
		bufSizeOff  = 108
		envPtrOff   = 200
		envBufOff   = 300
		prestatOff  = 400
		statOff     = 500
		pathBufOff  = 600
		randOff     = 700
	)

	t.Run("environ_sizes_get writes count and total length", func(t *testing.T) {
		s, buf := newTestState(WithEnv("A=1", "BC=2"))
		s.env = []string{"A=1", "BC=2"}
		errno := s.Xenviron_sizes_get(countOff, bufSizeOff)
		if errno != 0 {
			t.Fatalf("expected ESUCCESS, got %d", errno)
		}
		count := binary.LittleEndian.Uint32(buf[countOff : countOff+4])
		size := binary.LittleEndian.Uint32(buf[bufSizeOff : bufSizeOff+4])
		if count != 2 {
			t.Errorf("got count %d, want 2", count)
		}
		if size != 9 {
			t.Errorf("got size %d, want 9", size)
		}
	})

	t.Run("environ_get writes strings and pointers", func(t *testing.T) {
		s, buf := newTestState()
		s.env = []string{"A=1", "BC=2"}
		errno := s.Xenviron_get(envPtrOff, envBufOff)
		if errno != 0 {
			t.Fatalf("expected ESUCCESS, got %d", errno)
		}
		p1 := binary.LittleEndian.Uint32(buf[envPtrOff : envPtrOff+4])
		p2 := binary.LittleEndian.Uint32(buf[envPtrOff+4 : envPtrOff+8])
		if p1 != uint32(envBufOff) {
			t.Errorf("got p1 %d, want %d", p1, envBufOff)
		}
		if p2 != uint32(envBufOff+4) {
			t.Errorf("got p2 %d, want %d", p2, envBufOff+4)
		}
		s1 := string(buf[envBufOff : envBufOff+4])
		s2 := string(buf[envBufOff+4 : envBufOff+9])
		if s1 != "A=1\x00" {
			t.Errorf("got s1 %q, want %q", s1, "A=1\x00")
		}
		if s2 != "BC=2\x00" {
			t.Errorf("got s2 %q, want %q", s2, "BC=2\x00")
		}
	})

	t.Run("fd_prestat_get and fd_prestat_dir_name", func(t *testing.T) {
		s, buf := newTestState()
		s.mounts = []mountEntry{{guestPath: "tmp"}}
		s.preopens = []fdEntry{{path: "tmp", fdType: 3, mount: 0, preopen: true}}
		for len(s.fds) < 4 {
			s.fds = append(s.fds, fdEntry{})
		}
		s.fds[3] = fdEntry{path: "tmp", fdType: 3, mount: 0, preopen: true}

		t.Run("fd_prestat_get success", func(t *testing.T) {
			errno := s.Xfd_prestat_get(3, prestatOff)
			if errno != 0 {
				t.Fatalf("expected ESUCCESS, got %d", errno)
			}
			prestatType := binary.LittleEndian.Uint32(buf[prestatOff : prestatOff+4])
			pathLen := binary.LittleEndian.Uint32(buf[prestatOff+4 : prestatOff+8])
			if prestatType != 0 {
				t.Errorf("got type %d, want 0", prestatType)
			}
			if pathLen != 3 {
				t.Errorf("got pathLen %d, want 3", pathLen)
			}
		})

		t.Run("fd_prestat_get EBADF", func(t *testing.T) {
			errno := s.Xfd_prestat_get(4, prestatOff)
			if errno != 8 { // EBADF
				t.Errorf("got errno %d, want 8", errno)
			}
		})

		t.Run("fd_prestat_dir_name success", func(t *testing.T) {
			errno := s.Xfd_prestat_dir_name(3, pathBufOff, 3)
			if errno != 0 {
				t.Fatalf("expected ESUCCESS, got %d", errno)
			}
			got := string(buf[pathBufOff : pathBufOff+3])
			if got != "tmp" {
				t.Errorf("got %q, want %q", got, "tmp")
			}
		})
	})

	t.Run("fd_fdstat_get", func(t *testing.T) {
		s, buf := newTestState()
		for len(s.fds) <= 5 {
			s.fds = append(s.fds, fdEntry{})
		}
		s.fds[0] = fdEntry{fdType: 2} // stdin
		s.fds[1] = fdEntry{fdType: 2} // stdout
		s.fds[2] = fdEntry{fdType: 2} // stderr
		s.fds[3] = fdEntry{fdType: 3} // preopen
		s.fds[5] = fdEntry{fdType: 4, file: &stubFSFile{}}

		cases := []struct {
			fd   int32
			want uint16
			err  int32
		}{
			{0, 2, 0},
			{1, 2, 0},
			{2, 2, 0},
			{3, 3, 0},
			{5, 4, 0},
			{99, 0, 8},
		}

		for _, tc := range cases {
			errno := s.Xfd_fdstat_get(tc.fd, statOff)
			if errno != tc.err {
				t.Errorf("fd %d: got errno %d, want %d", tc.fd, errno, tc.err)
				continue
			}
			if errno == 0 {
				gotType := binary.LittleEndian.Uint16(buf[statOff : statOff+2])
				if gotType != tc.want {
					t.Errorf("fd %d: got type %d, want %d", tc.fd, gotType, tc.want)
				}
			}
		}
	})

	t.Run("fd_renumber", func(t *testing.T) {
		s, _ := newTestState()
		for len(s.fds) <= 6 {
			s.fds = append(s.fds, fdEntry{})
		}
		s.fds[5] = fdEntry{fdType: 4, path: "testfile"}
		original := s.fds[5]
		errno := s.Xfd_renumber(5, 6)
		if errno != 0 {
			t.Fatalf("expected ESUCCESS, got %d", errno)
		}
		if s.fds[6] != original {
			t.Errorf("fd 6 does not match original")
		}
		if (s.fds[5] != fdEntry{}) {
			t.Errorf("fd 5 is not empty after renumber")
		}
	})

	t.Run("proc_exit panics", func(t *testing.T) {
		s, _ := newTestState()
		defer func() {
			r := recover()
			if r == nil {
				t.Error("expected panic, got nil")
			}
			if exit, ok := r.(ExitError); !ok || exit.Code != 42 {
				t.Errorf("got panic %v, want ExitError{Code: 42}", r)
			}
		}()
		s.Xproc_exit(42)
	})

	t.Run("random_get", func(t *testing.T) {
		s, buf := newTestState()
		errno := s.Xrandom_get(randOff, 32)
		if errno != 0 {
			t.Fatalf("expected ESUCCESS, got %d", errno)
		}
		allZero := true
		for _, b := range buf[randOff : randOff+32] {
			if b != 0 {
				allZero = false
				break
			}
		}
		if allZero {
			t.Error("random_get filled with all zeros")
		}
	})

	t.Run("resolvePath", func(t *testing.T) {
		s, _ := newTestState()
		s.mounts = []mountEntry{
			{guestPath: "/"},
			{guestPath: "zeroperl"},
		}
		m, rel := s.resolvePath("/zeroperl/lib/x")
		if m == nil {
			t.Fatal("expected a mount, got nil")
		}
		if m.guestPath != "zeroperl" {
			t.Errorf("got mount %q, want %q", m.guestPath, "zeroperl")
		}
		if rel != "lib/x" {
			t.Errorf("got rel %q, want %q", rel, "lib/x")
		}
	})

	t.Run("readBytes ptr==0 returns nil", func(t *testing.T) {
		s, _ := newTestState()
		if got := s.readBytes(0, 10); got != nil {
			t.Errorf("readBytes(0, 10) = %v, want nil", got)
		}
	})

	t.Run("mountHostPaths non-root mount has no fallback", func(t *testing.T) {
		dir := t.TempDir()
		m := &mountEntry{guestPath: "/work", hostRoot: dir, writable: true}
		primary, fallback := mountHostPaths(m, "some/file.txt")
		if primary == "" {
			t.Error("primary should be non-empty for writable non-root mount")
		}
		if fallback != "" {
			t.Errorf("fallback = %q, want empty for non-root mount", fallback)
		}
	})

	t.Run("resolveDirfdPath non-preopen dir fd", func(t *testing.T) {
		s, _ := newTestState()
		s.mounts = []mountEntry{{guestPath: "/tmp", writable: false}}
		for len(s.fds) <= 5 {
			s.fds = append(s.fds, fdEntry{})
		}
		// fd 5 is a non-preopen dir fd whose stored path is "/tmp/subdir"
		s.fds[5] = fdEntry{fdType: fdDir, path: "/tmp/subdir", preopen: false}
		buf := make([]byte, 65536)
		s.mem = func() []byte { return buf }
		copy(buf[1000:], "child.txt")
		mount, rel := s.resolveDirfdPath(5, 1000, 9)
		if mount == nil {
			t.Fatal("expected non-nil mount")
		}
		if rel != "subdir/child.txt" {
			t.Errorf("rel = %q, want subdir/child.txt", rel)
		}
	})
}
