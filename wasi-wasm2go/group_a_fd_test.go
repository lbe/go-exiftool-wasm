package wasihost

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

// newWMState creates a State with a single writable mount at guest path "/tmp"
// rooted at a fresh t.TempDir(). fd 3 is the preopen for "/tmp".
// "/tmp" is NOT a root mount so mountHostPaths returns filepath.Join(tmpDir,rel)
// with no root-special-case fallback.
func newWMState(t *testing.T) (*State, []byte, string) {
	t.Helper()
	buf := make([]byte, 65536)
	tmpDir := t.TempDir()
	s := New(func() []byte { return buf },
		WithWritableMount("/tmp", tmpDir, os.DirFS(tmpDir)),
	)
	return s, buf, tmpDir
}

// openHostFile opens a named file relative to fd 3 (the "/tmp" preopen) with
// read-only rights. Returns the allocated guest fd number.
func openHostFile(t *testing.T, s *State, buf []byte, pathOff int32, name string, fdPtr int32) int32 {
	t.Helper()
	copy(buf[pathOff:], name)
	errno := s.Xpath_open(dirfd, 0, pathOff, int32(len(name)), 0, int64(rightFDRead), 0, 0, fdPtr)
	if errno != wasiESuccess {
		t.Fatalf("Xpath_open(%q) = %d, want ESUCCESS", name, errno)
	}
	return int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))
}

// TestMem verifies that Mem() returns the slice provided by the mem callback.
func TestMem(t *testing.T) {
	t.Parallel()
	buf := make([]byte, 65536)
	s := New(func() []byte { return buf })
	got := s.Mem()
	if len(got) != len(buf) || &got[0] != &buf[0] {
		t.Error("Mem() did not return the slice from the mem callback")
	}
}

// TestAllocFD exercises allocFD slot allocation, slot reuse after fd_close,
// and slice growth beyond the initial capacity.
func TestAllocFD(t *testing.T) {
	t.Parallel()
	const (
		fdPtr   = 1000
		pathOff = 2000
	)

	s, buf, tmpDir := newWMState(t)

	// Open 3 files -> allocates fds 4, 5, 6 (0-2=stdio, 3=preopen).
	var openedFDs []int32
	for i := 0; i < 3; i++ {
		name := fmt.Sprintf("alloc%d.txt", i)
		if err := os.WriteFile(filepath.Join(tmpDir, name), []byte("x"), 0644); err != nil {
			t.Fatal(err)
		}
		off := int32(pathOff + i*32)
		copy(buf[off:], name)
		errno := s.Xpath_open(dirfd, 0, off, int32(len(name)), 0, int64(rightFDRead), 0, 0, fdPtr)
		if errno != wasiESuccess {
			t.Fatalf("Xpath_open(%q) = %d", name, errno)
		}
		openedFDs = append(openedFDs, int32(binary.LittleEndian.Uint32(buf[fdPtr:fdPtr+4])))
	}

	if openedFDs[0] != 4 {
		t.Errorf("first allocFD = %d, want 4", openedFDs[0])
	}

	// Close fd 4 and re-open -> slot 4 must be reused.
	if errno := s.Xfd_close(openedFDs[0]); errno != wasiESuccess {
		t.Fatalf("Xfd_close = %d", errno)
	}
	name := "reuse.txt"
	if err := os.WriteFile(filepath.Join(tmpDir, name), []byte("y"), 0644); err != nil {
		t.Fatal(err)
	}
	copy(buf[pathOff:], name)
	errno := s.Xpath_open(dirfd, 0, pathOff, int32(len(name)), 0, int64(rightFDRead), 0, 0, fdPtr)
	if errno != wasiESuccess {
		t.Fatalf("Xpath_open(reuse) = %d", errno)
	}
	if reused := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4])); reused != 4 {
		t.Errorf("reused fd = %d, want 4", reused)
	}

	// Slice growth: open 10 more files to exceed initial cap (8+1=9).
	for i := 0; i < 10; i++ {
		n := fmt.Sprintf("grow%d.txt", i)
		os.WriteFile(filepath.Join(tmpDir, n), []byte("g"), 0644) //nolint
		off := int32(pathOff + 100 + i*24)
		copy(buf[off:], n)
		s.Xpath_open(dirfd, 0, off, int32(len(n)), 0, int64(rightFDRead), 0, 0, fdPtr) // no panic = pass
	}
}

// TestWriteFilestat verifies the 64-byte filestat struct layout via Xfd_filestat_get.
func TestWriteFilestat(t *testing.T) {
	t.Parallel()
	const (
		statPtr = 1000
		pathOff = 2000
		fdPtr   = 3000
	)

	s, buf, tmpDir := newWMState(t)

	content := []byte("hello world")
	if err := os.WriteFile(filepath.Join(tmpDir, "stat.txt"), content, 0644); err != nil {
		t.Fatal(err)
	}

	fd := openHostFile(t, s, buf, pathOff, "stat.txt", fdPtr)

	if errno := s.Xfd_filestat_get(fd, statPtr); errno != wasiESuccess {
		t.Fatalf("Xfd_filestat_get(file) = %d", errno)
	}

	// filetype at offset 16 (uint64) == fdFile (4)
	ftype := binary.LittleEndian.Uint64(buf[statPtr+16 : statPtr+24])
	if byte(ftype) != fdFile {
		t.Errorf("filetype = %d, want fdFile (%d)", ftype, fdFile)
	}
	// size at offset 32
	size := binary.LittleEndian.Uint64(buf[statPtr+32 : statPtr+40])
	if size != uint64(len(content)) {
		t.Errorf("size = %d, want %d", size, len(content))
	}
	// mtime at offset 40 > 0
	mtime := binary.LittleEndian.Uint64(buf[statPtr+40 : statPtr+48])
	if mtime == 0 {
		t.Error("mtime = 0, want > 0")
	}

	// Preopen dir fd (3) -> fdDir.
	if errno := s.Xfd_filestat_get(3, statPtr); errno != wasiESuccess {
		t.Fatalf("Xfd_filestat_get(preopen) = %d", errno)
	}
	ftype = binary.LittleEndian.Uint64(buf[statPtr+16 : statPtr+24])
	if byte(ftype) != fdDir {
		t.Errorf("preopen filetype = %d, want fdDir (%d)", ftype, fdDir)
	}

	// Invalid fd -> wasiEBadf.
	if errno := s.Xfd_filestat_get(999, statPtr); errno != wasiEBadf {
		t.Errorf("invalid fd filestat_get = %d, want EBADF", errno)
	}
}

// TestFdClose exercises fd_close success, double-close, preopen protection,
// and out-of-range fd.
func TestFdClose(t *testing.T) {
	t.Parallel()
	const (
		fdPtr   = 1000
		pathOff = 2000
	)

	t.Run("success and slot cleared", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		os.WriteFile(filepath.Join(tmpDir, "cl.txt"), []byte("x"), 0644) //nolint
		fd := openHostFile(t, s, buf, pathOff, "cl.txt", fdPtr)
		if errno := s.Xfd_close(fd); errno != wasiESuccess {
			t.Errorf("first close = %d, want ESUCCESS", errno)
		}
		if errno := s.Xfd_close(fd); errno != wasiEBadf {
			t.Errorf("second close = %d, want EBADF", errno)
		}
	})

	t.Run("preopen cannot be closed", func(t *testing.T) {
		s, _, _ := newWMState(t)
		if errno := s.Xfd_close(3); errno != wasiEBadf {
			t.Errorf("close preopen = %d, want EBADF", errno)
		}
	})

	t.Run("out-of-range fd", func(t *testing.T) {
		s, _, _ := newWMState(t)
		if errno := s.Xfd_close(-1); errno != wasiEBadf {
			t.Errorf("close -1 = %d, want EBADF", errno)
		}
		if errno := s.Xfd_close(9999); errno != wasiEBadf {
			t.Errorf("close 9999 = %d, want EBADF", errno)
		}
	})
}

// TestFdRead covers stdin, nil-stdin, osFile ReadAt sequential reads, and EBADF.
func TestFdRead(t *testing.T) {
	t.Parallel()
	const (
		iovsOff  = 1024
		dataBuf  = 2048
		nreadOff = 512
		fdPtr    = 3000
		pathOff  = 4000
	)

	t.Run("stdin path", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf }, WithStdin(strings.NewReader("hello")))
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 5)
		if errno := s.Xfd_read(0, iovsOff, 1, nreadOff); errno != wasiESuccess {
			t.Fatalf("Xfd_read stdin = %d", errno)
		}
		if got := string(buf[dataBuf : dataBuf+5]); got != "hello" {
			t.Errorf("data = %q, want hello", got)
		}
		if n := binary.LittleEndian.Uint32(buf[nreadOff : nreadOff+4]); n != 5 {
			t.Errorf("nread = %d, want 5", n)
		}
	})

	t.Run("stdin nil returns success nread 0", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf }) // no WithStdin
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 5)
		if errno := s.Xfd_read(0, iovsOff, 1, nreadOff); errno != wasiESuccess {
			t.Errorf("nil stdin read = %d, want ESUCCESS", errno)
		}
		if n := binary.LittleEndian.Uint32(buf[nreadOff : nreadOff+4]); n != 0 {
			t.Errorf("nread nil stdin = %d, want 0", n)
		}
	})

	t.Run("osFile ReadAt advances offset", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		os.WriteFile(filepath.Join(tmpDir, "rtest.txt"), []byte("ABCDEFGHIJ"), 0644) //nolint
		fd := openHostFile(t, s, buf, pathOff, "rtest.txt", fdPtr)

		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 4)

		if errno := s.Xfd_read(fd, iovsOff, 1, nreadOff); errno != wasiESuccess {
			t.Fatalf("first read = %d", errno)
		}
		if got := string(buf[dataBuf : dataBuf+4]); got != "ABCD" {
			t.Errorf("first read = %q, want ABCD", got)
		}
		// Second read continues from offset 4.
		if errno := s.Xfd_read(fd, iovsOff, 1, nreadOff); errno != wasiESuccess {
			t.Fatalf("second read = %d", errno)
		}
		if got := string(buf[dataBuf : dataBuf+4]); got != "EFGH" {
			t.Errorf("second read = %q, want EFGH", got)
		}
	})

	t.Run("EBADF invalid fd", func(t *testing.T) {
		s, buf, _ := newWMState(t)
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 4)
		if errno := s.Xfd_read(999, iovsOff, 1, nreadOff); errno != wasiEBadf {
			t.Errorf("invalid fd read = %d, want EBADF", errno)
		}
	})

	t.Run("EBADF nil file slot", func(t *testing.T) {
		s, buf, _ := newWMState(t)
		for len(s.fds) <= 5 {
			s.fds = append(s.fds, fdEntry{})
		}
		s.fds[5] = fdEntry{fdType: fdFile, file: nil}
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 4)
		if errno := s.Xfd_read(5, iovsOff, 1, nreadOff); errno != wasiEBadf {
			t.Errorf("nil file read = %d, want EBADF", errno)
		}
	})
}

// TestFdWrite covers stdout, stderr, nil-stdout, osFile WriteAt, and EBADF.
func TestFdWrite(t *testing.T) {
	t.Parallel()
	const (
		iovsOff     = 1024
		dataBuf     = 2048
		nwrittenOff = 512
		fdPtr       = 3000
		pathOff     = 4000
	)

	t.Run("stdout path", func(t *testing.T) {
		buf := make([]byte, 65536)
		var out bytes.Buffer
		s := New(func() []byte { return buf }, WithStdout(&out))
		copy(buf[dataBuf:], "hello")
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 5)
		if errno := s.Xfd_write(1, iovsOff, 1, nwrittenOff); errno != wasiESuccess {
			t.Fatalf("Xfd_write stdout = %d", errno)
		}
		if got := out.String(); got != "hello" {
			t.Errorf("stdout = %q, want hello", got)
		}
		if n := binary.LittleEndian.Uint32(buf[nwrittenOff : nwrittenOff+4]); n != 5 {
			t.Errorf("nwritten = %d, want 5", n)
		}
	})

	t.Run("stderr path", func(t *testing.T) {
		buf := make([]byte, 65536)
		var errOut bytes.Buffer
		s := New(func() []byte { return buf }, WithStderr(&errOut))
		copy(buf[dataBuf:], "world")
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 5)
		if errno := s.Xfd_write(2, iovsOff, 1, nwrittenOff); errno != wasiESuccess {
			t.Fatalf("Xfd_write stderr = %d", errno)
		}
		if got := errOut.String(); got != "world" {
			t.Errorf("stderr = %q, want world", got)
		}
	})

	t.Run("stdout nil no panic", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf }) // no WithStdout
		copy(buf[dataBuf:], "data")
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 4)
		if errno := s.Xfd_write(1, iovsOff, 1, nwrittenOff); errno != wasiESuccess {
			t.Errorf("nil stdout write = %d, want ESUCCESS", errno)
		}
		if n := binary.LittleEndian.Uint32(buf[nwrittenOff : nwrittenOff+4]); n != 0 {
			t.Errorf("nwritten nil stdout = %d, want 0", n)
		}
	})

	t.Run("osFile WriteAt", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		fname := "wtest.txt"
		os.WriteFile(filepath.Join(tmpDir, fname), []byte{}, 0644) //nolint
		copy(buf[pathOff:], fname)
		errno := s.Xpath_open(dirfd, 0, pathOff, int32(len(fname)),
			int32(oflagTrunc), int64(rightFDWrite|rightFDRead), 0, 0, fdPtr)
		if errno != wasiESuccess {
			t.Fatalf("Xpath_open write = %d", errno)
		}
		fd := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))
		copy(buf[dataBuf:], "XYZ")
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 3)
		if errno := s.Xfd_write(fd, iovsOff, 1, nwrittenOff); errno != wasiESuccess {
			t.Fatalf("Xfd_write osFile = %d", errno)
		}
		data, _ := os.ReadFile(filepath.Join(tmpDir, fname))
		if string(data) != "XYZ" {
			t.Errorf("file content = %q, want XYZ", data)
		}
		const tellOff = 8000
		s.Xfd_tell(fd, tellOff)
		if pos := binary.LittleEndian.Uint64(buf[tellOff : tellOff+8]); pos != 3 {
			t.Errorf("tell after write = %d, want 3", pos)
		}
	})

	t.Run("EBADF invalid fd", func(t *testing.T) {
		s, buf, _ := newWMState(t)
		copy(buf[dataBuf:], "data")
		binary.LittleEndian.PutUint32(buf[iovsOff:], uint32(dataBuf))
		binary.LittleEndian.PutUint32(buf[iovsOff+4:], 4)
		if errno := s.Xfd_write(999, iovsOff, 1, nwrittenOff); errno != wasiEBadf {
			t.Errorf("invalid fd write = %d, want EBADF", errno)
		}
	})
}

// TestFdSeek covers SEEK_SET, SEEK_CUR, SEEK_END, EISDIR, EINVAL, and EBADF.
func TestFdSeek(t *testing.T) {
	t.Parallel()
	const (
		resultPtr = 500
		fdPtr     = 1000
		pathOff   = 2000
	)

	setupSeekFile := func(t *testing.T) (*State, []byte, int32) {
		t.Helper()
		s, buf, tmpDir := newWMState(t)
		os.WriteFile(filepath.Join(tmpDir, "seek.txt"), []byte("ABCDEFGHIJ"), 0644) //nolint
		fd := openHostFile(t, s, buf, pathOff, "seek.txt", fdPtr)
		return s, buf, fd
	}

	t.Run("SEEK_SET", func(t *testing.T) {
		s, buf, fd := setupSeekFile(t)
		if errno := s.Xfd_seek(fd, 4, 0, resultPtr); errno != wasiESuccess {
			t.Fatalf("SEEK_SET = %d", errno)
		}
		if pos := binary.LittleEndian.Uint64(buf[resultPtr : resultPtr+8]); pos != 4 {
			t.Errorf("SEEK_SET result = %d, want 4", pos)
		}
	})

	t.Run("SEEK_CUR", func(t *testing.T) {
		s, buf, fd := setupSeekFile(t)
		s.Xfd_seek(fd, 4, 0, resultPtr) // move to 4
		if errno := s.Xfd_seek(fd, 2, 1, resultPtr); errno != wasiESuccess {
			t.Fatalf("SEEK_CUR = %d", errno)
		}
		if pos := binary.LittleEndian.Uint64(buf[resultPtr : resultPtr+8]); pos != 6 {
			t.Errorf("SEEK_CUR result = %d, want 6", pos)
		}
	})

	t.Run("SEEK_END", func(t *testing.T) {
		s, buf, fd := setupSeekFile(t)
		if errno := s.Xfd_seek(fd, -3, 2, resultPtr); errno != wasiESuccess {
			t.Fatalf("SEEK_END = %d", errno)
		}
		if pos := binary.LittleEndian.Uint64(buf[resultPtr : resultPtr+8]); pos != 7 {
			t.Errorf("SEEK_END result = %d, want 7", pos)
		}
	})

	t.Run("EISDIR on directory fd", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		os.Mkdir(filepath.Join(tmpDir, "adir"), 0755) //nolint
		copy(buf[pathOff:], "adir")
		errno := s.Xpath_open(dirfd, 0, pathOff, 4, int32(oflagDir), 0, 0, 0, fdPtr)
		if errno != wasiESuccess {
			t.Fatalf("Xpath_open dir = %d", errno)
		}
		fd := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))
		if errno := s.Xfd_seek(fd, 0, 0, resultPtr); errno != wasiEIsdir {
			t.Errorf("seek dir = %d, want EISDIR", errno)
		}
	})

	t.Run("EINVAL non-seeker fd", func(t *testing.T) {
		// stubFSFile (defined in group_a_test.go) does not implement io.Seeker.
		s, _, _ := newWMState(t)
		for len(s.fds) <= 5 {
			s.fds = append(s.fds, fdEntry{})
		}
		s.fds[5] = fdEntry{fdType: fdFile, file: &stubFSFile{}}
		if errno := s.Xfd_seek(5, 0, 0, resultPtr); errno != wasiEInval {
			t.Errorf("non-seeker seek = %d, want EINVAL", errno)
		}
	})

	t.Run("EBADF invalid fd", func(t *testing.T) {
		s, _, _ := newWMState(t)
		if errno := s.Xfd_seek(999, 0, 0, resultPtr); errno != wasiEBadf {
			t.Errorf("invalid fd seek = %d, want EBADF", errno)
		}
	})
}

// TestFdReaddir covers basic dirent listing, tiny buffer, preopen lazy load,
// and EBADF.
func TestFdReaddir(t *testing.T) {
	t.Parallel()
	const (
		rdBufPtr = 1000
		rdBufLen = 4096
		usedPtr  = 8000
		fdPtr    = 9000
		pathOff  = 9500
	)

	t.Run("lists entries and parses first dirent", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		os.Mkdir(filepath.Join(tmpDir, "sub"), 0755)                           //nolint
		os.WriteFile(filepath.Join(tmpDir, "sub", "a.txt"), []byte("a"), 0644) //nolint
		os.WriteFile(filepath.Join(tmpDir, "sub", "b.txt"), []byte("b"), 0644) //nolint

		copy(buf[pathOff:], "sub")
		errno := s.Xpath_open(dirfd, 0, pathOff, 3, int32(oflagDir), 0, 0, 0, fdPtr)
		if errno != wasiESuccess {
			t.Fatalf("Xpath_open sub = %d", errno)
		}
		fd := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))

		errno = s.Xfd_readdir(fd, rdBufPtr, rdBufLen, 0, usedPtr)
		if errno != wasiESuccess {
			t.Fatalf("Xfd_readdir = %d", errno)
		}
		used := binary.LittleEndian.Uint32(buf[usedPtr : usedPtr+4])
		if used == 0 {
			t.Fatal("bufUsed = 0, expected entries")
		}
		// Parse first dirent: nameLen at offset 16, name at offset 24.
		nameLen := binary.LittleEndian.Uint32(buf[rdBufPtr+16 : rdBufPtr+20])
		if nameLen == 0 {
			t.Fatal("first dirent nameLen = 0")
		}
		name := string(buf[rdBufPtr+24 : rdBufPtr+24+int32(nameLen)])
		if name != "a.txt" && name != "b.txt" {
			t.Errorf("first entry = %q, want a.txt or b.txt", name)
		}
	})

	t.Run("buffer too small returns bufUsed 0", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		os.Mkdir(filepath.Join(tmpDir, "sub2"), 0755)                                  //nolint
		os.WriteFile(filepath.Join(tmpDir, "sub2", "longname.txt"), []byte("x"), 0644) //nolint

		copy(buf[pathOff:], "sub2")
		s.Xpath_open(dirfd, 0, pathOff, 4, int32(oflagDir), 0, 0, 0, fdPtr) //nolint
		fd := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))

		// 1-byte buffer -- too small for any dirent.
		errno := s.Xfd_readdir(fd, rdBufPtr, 1, 0, usedPtr)
		if errno != wasiESuccess {
			t.Fatalf("readdir tiny = %d", errno)
		}
		if used := binary.LittleEndian.Uint32(buf[usedPtr : usedPtr+4]); used != 0 {
			t.Errorf("bufUsed = %d, want 0 for tiny buffer", used)
		}
	})

	t.Run("preopen lazy load does not panic", func(t *testing.T) {
		s, buf, _ := newWMState(t)
		// fd 3 is the preopen for "/tmp"; DirEntriesFile is created on first call.
		errno := s.Xfd_readdir(3, rdBufPtr, rdBufLen, 0, usedPtr)
		if errno != wasiESuccess && errno != wasiEIo {
			t.Errorf("preopen readdir = %d, want ESUCCESS or EIO", errno)
		}
		_ = buf // used via s.mem closure
	})

	t.Run("EBADF invalid fd", func(t *testing.T) {
		s, buf, _ := newWMState(t)
		if errno := s.Xfd_readdir(999, rdBufPtr, rdBufLen, 0, usedPtr); errno != wasiEBadf {
			t.Errorf("invalid fd readdir = %d, want EBADF", errno)
		}
		_ = buf
	})
}

// TestXpathFilestatGet exercises path_filestat_get for read-only mounts,
// writable mounts, overlay fallback, and ENOENT.
func TestXpathFilestatGet(t *testing.T) {
	t.Parallel()
	const (
		pathOff = 1000
		statPtr = 2000
	)

	t.Run("read-only mount file", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf },
			WithMount("/tmp", fstest.MapFS{
				"a.txt": &fstest.MapFile{Data: []byte("content")},
			}),
		)
		copy(buf[pathOff:], "a.txt")
		if errno := s.Xpath_filestat_get(3, 0, pathOff, 5, statPtr); errno != wasiESuccess {
			t.Fatalf("Xpath_filestat_get ro = %d", errno)
		}
		ftype := binary.LittleEndian.Uint64(buf[statPtr+16 : statPtr+24])
		if byte(ftype) != fdFile {
			t.Errorf("filetype = %d, want fdFile (%d)", ftype, fdFile)
		}
	})

	t.Run("writable mount host file", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		content := []byte("real data")
		os.WriteFile(filepath.Join(tmpDir, "real.txt"), content, 0644) //nolint
		copy(buf[pathOff:], "real.txt")
		if errno := s.Xpath_filestat_get(3, 0, pathOff, 8, statPtr); errno != wasiESuccess {
			t.Fatalf("Xpath_filestat_get writable = %d", errno)
		}
		size := binary.LittleEndian.Uint64(buf[statPtr+32 : statPtr+40])
		if size != uint64(len(content)) {
			t.Errorf("size = %d, want %d", size, len(content))
		}
	})

	t.Run("writable mount overlay fallback", func(t *testing.T) {
		buf := make([]byte, 65536)
		tmpDir := t.TempDir()
		overlay := fstest.MapFS{
			"lib/perl.pm": &fstest.MapFile{Data: []byte("# perl")},
		}
		s := New(func() []byte { return buf },
			WithWritableMount("/tmp", tmpDir, overlay),
		)
		p := "lib/perl.pm"
		copy(buf[pathOff:], p)
		if errno := s.Xpath_filestat_get(3, 0, pathOff, int32(len(p)), statPtr); errno != wasiESuccess {
			t.Fatalf("Xpath_filestat_get overlay = %d", errno)
		}
	})

	t.Run("ENOENT missing path", func(t *testing.T) {
		s, buf, _ := newWMState(t)
		copy(buf[pathOff:], "missing.txt")
		if errno := s.Xpath_filestat_get(3, 0, pathOff, 11, statPtr); errno != wasiENoEnt {
			t.Errorf("missing = %d, want ENOENT", errno)
		}
	})
}

// TestXpathOpen covers /dev/null, read-only mount, writable mount, oflagCreat,
// directory open, and ENOENT.
func TestXpathOpen(t *testing.T) {
	t.Parallel()
	const (
		pathOff = 1000
		fdPtr   = 2000
		statPtr = 3000
	)

	t.Run("/dev/null", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf })
		p := "/dev/null"
		copy(buf[pathOff:], p)
		if errno := s.Xpath_open(0, 0, pathOff, int32(len(p)), 0, 0, 0, 0, fdPtr); errno != wasiESuccess {
			t.Fatalf("Xpath_open /dev/null = %d", errno)
		}
		fd := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))
		if s.fds[fd].fdType != fdCharDev {
			t.Errorf("fdType = %d, want fdCharDev (%d)", s.fds[fd].fdType, fdCharDev)
		}
	})

	t.Run("read-only mount file", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf },
			WithMount("/tmp", fstest.MapFS{
				"a.txt": &fstest.MapFile{Data: []byte("hello")},
			}),
		)
		copy(buf[pathOff:], "a.txt")
		if errno := s.Xpath_open(3, 0, pathOff, 5, 0, int64(rightFDRead), 0, 0, fdPtr); errno != wasiESuccess {
			t.Fatalf("Xpath_open ro = %d", errno)
		}
		fd := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))
		if errno := s.Xfd_filestat_get(fd, statPtr); errno != wasiESuccess {
			t.Fatalf("Xfd_filestat_get = %d", errno)
		}
		if size := binary.LittleEndian.Uint64(buf[statPtr+32 : statPtr+40]); size == 0 {
			t.Error("size = 0, want > 0")
		}
	})

	t.Run("writable mount existing host file backed by osFile", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		os.WriteFile(filepath.Join(tmpDir, "host.txt"), []byte("data"), 0644) //nolint
		copy(buf[pathOff:], "host.txt")
		if errno := s.Xpath_open(dirfd, 0, pathOff, 8, 0, int64(rightFDRead), 0, 0, fdPtr); errno != wasiESuccess {
			t.Fatalf("Xpath_open host = %d", errno)
		}
		fd := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))
		if _, ok := s.fds[fd].file.(*osFile); !ok {
			t.Errorf("expected *osFile, got %T", s.fds[fd].file)
		}
	})

	t.Run("oflagCreat creates new file", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		copy(buf[pathOff:], "new.txt")
		errno := s.Xpath_open(dirfd, 0, pathOff, 7, int32(oflagCreat),
			int64(rightFDWrite|rightFDRead), 0, 0, fdPtr)
		if errno != wasiESuccess {
			t.Fatalf("Xpath_open creat = %d", errno)
		}
		if _, err := os.Stat(filepath.Join(tmpDir, "new.txt")); err != nil {
			t.Errorf("file not created: %v", err)
		}
	})

	t.Run("directory open stores fdDir", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		os.Mkdir(filepath.Join(tmpDir, "mydir"), 0755) //nolint
		copy(buf[pathOff:], "mydir")
		errno := s.Xpath_open(dirfd, 0, pathOff, 5, int32(oflagDir), 0, 0, 0, fdPtr)
		if errno != wasiESuccess {
			t.Fatalf("Xpath_open dir = %d", errno)
		}
		fd := int32(binary.LittleEndian.Uint32(buf[fdPtr : fdPtr+4]))
		if s.fds[fd].fdType != fdDir {
			t.Errorf("fdType = %d, want fdDir (%d)", s.fds[fd].fdType, fdDir)
		}
	})

	t.Run("ENOENT not found", func(t *testing.T) {
		s, buf, _ := newWMState(t)
		copy(buf[pathOff:], "nonexistent.txt")
		if errno := s.Xpath_open(dirfd, 0, pathOff, 15, 0, int64(rightFDRead), 0, 0, fdPtr); errno != wasiENoEnt {
			t.Errorf("ENOENT = %d, want ENOENT", errno)
		}
	})
}

// TestXpathRename covers success, EROFS on read-only mount, and ENOENT with no
// mounts.
func TestXpathRename(t *testing.T) {
	t.Parallel()
	const (
		srcOff = 100
		dstOff = 200
	)

	t.Run("success", func(t *testing.T) {
		s, buf, tmpDir := newWMState(t)
		src := filepath.Join(tmpDir, "src.txt")
		os.WriteFile(src, []byte("data"), 0644) //nolint
		srcPathOff, srcLen := writePath(buf, srcOff, "src.txt")
		dstPathOff, dstLen := writePath(buf, dstOff, "dst.txt")
		if errno := s.Xpath_rename(dirfd, srcPathOff, srcLen, dirfd, dstPathOff, dstLen); errno != wasiESuccess {
			t.Fatalf("Xpath_rename = %d", errno)
		}
		if _, err := os.Stat(src); !os.IsNotExist(err) {
			t.Error("src still exists after rename")
		}
		if _, err := os.Stat(filepath.Join(tmpDir, "dst.txt")); err != nil {
			t.Errorf("dst not found: %v", err)
		}
	})

	t.Run("EROFS read-only mount", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf }, WithMount("/tmp", fstest.MapFS{}))
		srcPathOff, srcLen := writePath(buf, srcOff, "a.txt")
		dstPathOff, dstLen := writePath(buf, dstOff, "b.txt")
		if errno := s.Xpath_rename(3, srcPathOff, srcLen, 3, dstPathOff, dstLen); errno != wasiEROFS {
			t.Errorf("EROFS = %d, want EROFS", errno)
		}
	})

	t.Run("ENOENT no mounts", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf })
		srcPathOff, srcLen := writePath(buf, srcOff, "a.txt")
		dstPathOff, dstLen := writePath(buf, dstOff, "b.txt")
		if errno := s.Xpath_rename(0, srcPathOff, srcLen, 0, dstPathOff, dstLen); errno != wasiENoEnt {
			t.Errorf("ENOENT = %d, want ENOENT", errno)
		}
	})
}

// TestXpollOneoff covers clock subscription, fd_read with valid/invalid fd,
// and multiple subscriptions.
func TestXpollOneoff(t *testing.T) {
	t.Parallel()
	const (
		inPtr      = 100
		outPtr     = 1000
		neventsPtr = 2000
	)

	t.Run("clock subscription", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf })
		// eventType=0 at [inPtr+40], timeout=1ns at [inPtr+16]
		binary.LittleEndian.PutUint32(buf[inPtr+40:], 0)
		binary.LittleEndian.PutUint64(buf[inPtr+16:], 1)
		if errno := s.Xpoll_oneoff(inPtr, outPtr, 1, neventsPtr); errno != wasiESuccess {
			t.Fatalf("Xpoll_oneoff clock = %d", errno)
		}
		if n := binary.LittleEndian.Uint32(buf[neventsPtr : neventsPtr+4]); n != 1 {
			t.Errorf("nevents = %d, want 1", n)
		}
		if e := binary.LittleEndian.Uint16(buf[outPtr+8 : outPtr+10]); e != 0 {
			t.Errorf("event errno = %d, want 0", e)
		}
	})

	t.Run("fd_read valid fd", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf })
		binary.LittleEndian.PutUint32(buf[inPtr+40:], 1) // fd_read
		binary.LittleEndian.PutUint32(buf[inPtr+8:], 0)  // fd=0 (exists)
		if errno := s.Xpoll_oneoff(inPtr, outPtr, 1, neventsPtr); errno != wasiESuccess {
			t.Fatalf("Xpoll_oneoff fd_read = %d", errno)
		}
		if e := binary.LittleEndian.Uint16(buf[outPtr+8 : outPtr+10]); e != 0 {
			t.Errorf("event errno = %d, want 0", e)
		}
	})

	t.Run("fd_read invalid fd", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf })
		binary.LittleEndian.PutUint32(buf[inPtr+40:], 1)  // fd_read
		binary.LittleEndian.PutUint32(buf[inPtr+8:], 99)  // invalid fd
		if errno := s.Xpoll_oneoff(inPtr, outPtr, 1, neventsPtr); errno != wasiESuccess {
			t.Fatalf("Xpoll_oneoff = %d", errno)
		}
		if e := binary.LittleEndian.Uint16(buf[outPtr+8 : outPtr+10]); e != uint16(wasiEBadf) {
			t.Errorf("event errno = %d, want EBADF (%d)", e, wasiEBadf)
		}
	})

	t.Run("multiple subscriptions", func(t *testing.T) {
		buf := make([]byte, 65536)
		s := New(func() []byte { return buf })
		// Sub 0: clock, 1ns
		binary.LittleEndian.PutUint32(buf[inPtr+40:], 0)
		binary.LittleEndian.PutUint64(buf[inPtr+16:], 1)
		// Sub 1: fd_read, fd=0
		binary.LittleEndian.PutUint32(buf[inPtr+48+40:], 1)
		binary.LittleEndian.PutUint32(buf[inPtr+48+8:], 0)
		if errno := s.Xpoll_oneoff(inPtr, outPtr, 2, neventsPtr); errno != wasiESuccess {
			t.Fatalf("Xpoll_oneoff multi = %d", errno)
		}
		if n := binary.LittleEndian.Uint32(buf[neventsPtr : neventsPtr+4]); n != 2 {
			t.Errorf("nevents = %d, want 2", n)
		}
	})
}
