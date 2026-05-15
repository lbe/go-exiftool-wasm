package wasihost

import (
    "encoding/binary"
    "os"
    "testing"
)

// setupOsFileFd creates a real OS-backed file fd entry at the given fd slot.
// Returns the file path for later verification.
func setupOsFileFd(t *testing.T, s *State, fdIdx int, content []byte) string {
    t.Helper()
    dir := t.TempDir()
    path := dir + "/testfile"
    if err := os.WriteFile(path, content, 0644); err != nil {
        t.Fatal(err)
    }
    f, err := os.OpenFile(path, os.O_RDWR, 0644)
    if err != nil {
        t.Fatal(err)
    }
    t.Cleanup(func() { f.Close() })
    for len(s.fds) <= fdIdx {
        s.fds = append(s.fds, fdEntry{})
    }
    s.fds[fdIdx] = fdEntry{fdType: 4, file: &osFile{f}}
    return path
}

func TestGroupEPositionedIO(t *testing.T) {
    const (
        iovDataOff = 1000  // where iov data is written into the guest buf
        iovPtrOff  = 2000  // where the iovec struct lives {bufPtr u32, bufLen u32}
        nresOff    = 3000  // nread / nwritten result pointer
        tellOff    = 4000  // Xfd_tell result pointer
    )

    // ── pread ─────────────────────────────────────────────────────────────
    t.Run("Xfd_pread reads at offset without advancing cursor", func(t *testing.T) {
        s, buf := newTestState()
        _ = setupOsFileFd(t, s, 5, []byte("ABCDEFGHIJ"))

        // Build iovec at iovPtrOff: {bufPtr=iovDataOff, bufLen=4}
        binary.LittleEndian.PutUint32(buf[iovPtrOff:], uint32(iovDataOff))
        binary.LittleEndian.PutUint32(buf[iovPtrOff+4:], 4)

        errno := s.Xfd_pread(5, iovPtrOff, 1, 4, nresOff)
        if errno != wasiESuccess {
            t.Fatalf("Xfd_pread returned %d, want ESUCCESS", errno)
        }
        got := string(buf[iovDataOff : iovDataOff+4])
        if got != "EFGH" {
            t.Errorf("Xfd_pread read %q, want %q", got, "EFGH")
        }
        nread := binary.LittleEndian.Uint32(buf[nresOff : nresOff+4])
        if nread != 4 {
            t.Errorf("nread = %d, want 4", nread)
        }
        // Tell must still be 0
        s.Xfd_tell(5, tellOff)
        offset := binary.LittleEndian.Uint64(buf[tellOff : tellOff+8])
        if offset != 0 {
            t.Errorf("fd_tell after pread = %d, want 0", offset)
        }
    })

    t.Run("Xfd_pread on stdin (fd=0) returns EINVAL", func(t *testing.T) {
        s, buf := newTestState()
        binary.LittleEndian.PutUint32(buf[iovPtrOff:], uint32(iovDataOff))
        binary.LittleEndian.PutUint32(buf[iovPtrOff+4:], 4)
        errno := s.Xfd_pread(0, iovPtrOff, 1, 0, nresOff)
        if errno != wasiEInval {
            t.Errorf("got errno %d, want EINVAL (%d)", errno, wasiEInval)
        }
    })

    // ── pwrite ────────────────────────────────────────────────────────────
    t.Run("Xfd_pwrite writes at offset without advancing cursor", func(t *testing.T) {
        s, buf := newTestState()
        filePath := setupOsFileFd(t, s, 5, []byte{}) // empty file

        // Put "XYZ" into the guest buffer at iovDataOff
        copy(buf[iovDataOff:], "XYZ")
        // Build iovec: {bufPtr=iovDataOff, bufLen=3}
        binary.LittleEndian.PutUint32(buf[iovPtrOff:], uint32(iovDataOff))
        binary.LittleEndian.PutUint32(buf[iovPtrOff+4:], 3)

        errno := s.Xfd_pwrite(5, iovPtrOff, 1, 3, nresOff)
        if errno != wasiESuccess {
            t.Fatalf("Xfd_pwrite returned %d, want ESUCCESS", errno)
        }
        // File should now be "\x00\x00\x00XYZ"
        data, err := os.ReadFile(filePath)
        if err != nil {
            t.Fatal(err)
        }
        want := "\x00\x00\x00XYZ"
        if string(data) != want {
            t.Errorf("file content %q, want %q", data, want)
        }
        // Tell must still be 0
        s.Xfd_tell(5, tellOff)
        offset := binary.LittleEndian.Uint64(buf[tellOff : tellOff+8])
        if offset != 0 {
            t.Errorf("fd_tell after pwrite = %d, want 0", offset)
        }
    })

    t.Run("Xfd_pwrite on stdout (fd=1) returns EINVAL", func(t *testing.T) {
        s, buf := newTestState()
        copy(buf[iovDataOff:], "XYZ")
        binary.LittleEndian.PutUint32(buf[iovPtrOff:], uint32(iovDataOff))
        binary.LittleEndian.PutUint32(buf[iovPtrOff+4:], 3)
        errno := s.Xfd_pwrite(1, iovPtrOff, 1, 0, nresOff)
        if errno != wasiEInval {
            t.Errorf("got errno %d, want EINVAL (%d)", errno, wasiEInval)
        }
    })

    // ── Group E stubs ─────────────────────────────────────────────────────
    t.Run("Xsched_yield returns ESUCCESS", func(t *testing.T) {
        s, _ := newTestState()
        if s.Xsched_yield() != wasiESuccess {
            t.Error("Xsched_yield returned non-zero")
        }
    })

    t.Run("Xfd_datasync on osFile-backed fd returns ESUCCESS", func(t *testing.T) {
        s, _ := newTestState()
        _ = setupOsFileFd(t, s, 5, []byte("data"))
        if errno := s.Xfd_datasync(5); errno != wasiESuccess {
            t.Errorf("got %d, want ESUCCESS", errno)
        }
    })

    t.Run("Xfd_datasync on FSFileWrap-backed fd returns ESUCCESS", func(t *testing.T) {
        s, _ := newTestState()
        dir := t.TempDir()
        if err := os.WriteFile(dir+"/f.txt", []byte("x"), 0644); err != nil {
            t.Fatal(err)
        }
        fsys := os.DirFS(dir)
        f, err := fsys.Open("f.txt")
        if err != nil {
            t.Fatal(err)
        }
        t.Cleanup(func() { f.Close() })
        for len(s.fds) <= 5 {
            s.fds = append(s.fds, fdEntry{})
        }
        s.fds[5] = fdEntry{fdType: 4, file: &FSFileWrap{File: f}}
        if errno := s.Xfd_datasync(5); errno != wasiESuccess {
            t.Errorf("got %d, want ESUCCESS", errno)
        }
    })

    t.Run("Xfd_advise returns ESUCCESS", func(t *testing.T) {
        s, _ := newTestState()
        _ = setupOsFileFd(t, s, 5, []byte("data"))
        if s.Xfd_advise(5, 0, 4, 0) != wasiESuccess {
            t.Error("Xfd_advise returned non-zero")
        }
    })

    t.Run("Xfd_allocate returns ESUCCESS", func(t *testing.T) {
        s, _ := newTestState()
        _ = setupOsFileFd(t, s, 5, []byte{})
        if s.Xfd_allocate(5, 0, 16) != wasiESuccess {
            t.Error("Xfd_allocate returned non-zero")
        }
    })

    t.Run("Xfd_fdstat_set_rights returns ESUCCESS", func(t *testing.T) {
        s, _ := newTestState()
        _ = setupOsFileFd(t, s, 5, []byte("data"))
        if s.Xfd_fdstat_set_rights(5, 0, 0) != wasiESuccess {
            t.Error("Xfd_fdstat_set_rights returned non-zero")
        }
    })

    t.Run("Xproc_raise returns ENOSYS", func(t *testing.T) {
        s, _ := newTestState()
        if errno := s.Xproc_raise(9); errno != wasiENoSys {
            t.Errorf("got %d, want ENOSYS (%d)", errno, wasiENoSys)
        }
    })

    t.Run("Xsock_* functions return ENOSYS", func(t *testing.T) {
        s, buf := newTestState()
        if s.Xsock_accept(5, 0, nresOff) != wasiENoSys {
            t.Error("Xsock_accept: want ENOSYS")
        }
        if s.Xsock_recv(5, iovPtrOff, 1, 0, nresOff, nresOff+4) != wasiENoSys {
            t.Error("Xsock_recv: want ENOSYS")
        }
        if s.Xsock_send(5, iovPtrOff, 1, 0, nresOff) != wasiENoSys {
            t.Error("Xsock_send: want ENOSYS")
        }
        if s.Xsock_shutdown(5, 0) != wasiENoSys {
            t.Error("Xsock_shutdown: want ENOSYS")
        }
        _ = buf
    })

    t.Run("Xfd_pread ReadAt-not-supported returns ESUCCESS nread 0", func(t *testing.T) {
        // FSFileWrap does not support ReadAt, so the !ok break path is taken.
        s, buf := newTestState()
        dir := t.TempDir()
        if err := os.WriteFile(dir+"/f.txt", []byte("ABCDE"), 0644); err != nil {
            t.Fatal(err)
        }
        fsys := os.DirFS(dir)
        f, err := fsys.Open("f.txt")
        if err != nil {
            t.Fatal(err)
        }
        t.Cleanup(func() { f.Close() })
        for len(s.fds) <= 5 {
            s.fds = append(s.fds, fdEntry{})
        }
        s.fds[5] = fdEntry{fdType: 4, file: &FSFileWrap{File: f}}
        binary.LittleEndian.PutUint32(buf[iovPtrOff:], uint32(iovDataOff))
        binary.LittleEndian.PutUint32(buf[iovPtrOff+4:], 4)
        errno := s.Xfd_pread(5, iovPtrOff, 1, 0, nresOff)
        if errno != wasiESuccess {
            t.Errorf("Xfd_pread FSFileWrap = %d, want ESUCCESS", errno)
        }
        nread := binary.LittleEndian.Uint32(buf[nresOff : nresOff+4])
        if nread != 0 {
            t.Errorf("nread = %d, want 0 (ReadAt not supported)", nread)
        }
    })

    t.Run("Xfd_pwrite WriteAt-not-supported returns ESUCCESS nwritten 0", func(t *testing.T) {
        // FSFileWrap does not support WriteAt, so the !ok break path is taken.
        s, buf := newTestState()
        dir := t.TempDir()
        if err := os.WriteFile(dir+"/w.txt", []byte("ABCDE"), 0644); err != nil {
            t.Fatal(err)
        }
        fsys := os.DirFS(dir)
        f, err := fsys.Open("w.txt")
        if err != nil {
            t.Fatal(err)
        }
        t.Cleanup(func() { f.Close() })
        for len(s.fds) <= 5 {
            s.fds = append(s.fds, fdEntry{})
        }
        s.fds[5] = fdEntry{fdType: 4, file: &FSFileWrap{File: f}}
        copy(buf[iovDataOff:], "XYZ")
        binary.LittleEndian.PutUint32(buf[iovPtrOff:], uint32(iovDataOff))
        binary.LittleEndian.PutUint32(buf[iovPtrOff+4:], 3)
        errno := s.Xfd_pwrite(5, iovPtrOff, 1, 0, nresOff)
        if errno != wasiESuccess {
            t.Errorf("Xfd_pwrite FSFileWrap = %d, want ESUCCESS", errno)
        }
        nwritten := binary.LittleEndian.Uint32(buf[nresOff : nresOff+4])
        if nwritten != 0 {
            t.Errorf("nwritten = %d, want 0 (WriteAt not supported)", nwritten)
        }
    })
}
