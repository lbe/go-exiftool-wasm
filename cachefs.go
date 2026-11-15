package exiftool

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"path"
	"sync"
	"time"

	"github.com/lbe/cfsread"
	"github.com/lbe/cfsread/decompress"
	"github.com/lbe/cfsread/decompress/lz4"
)

// cachedFS is an fs.FS that serves regular files through a cfsread.Reader, which
// decompresses LZ4 files and keeps the results in an LRU cache. Directories come
// straight from the underlying FS. perlFS uses cachedFS for the embedded
// perl-wasi-prefix tree. cfsread coalesces concurrent reads of the same path, so
// one goroutine does the I/O and decompression. cachedFS is safe for concurrent use.
type cachedFS struct {
	reader     *cfsread.Reader
	src        cfsread.Source
	underlying fs.FS

	mu     sync.RWMutex
	closed bool
}

// newCachedFS returns a cachedFS over underlying, with a cfsread.Reader built from
// opts. id names this source's cache namespace and must not be empty. newCachedFS
// replaces opts.Registry with a registry that decodes LZ4.
//
// Call Close to release the reader. An instance that lives as long as the process,
// such as the one perlFS creates, does not need it.
func newCachedFS(id string, underlying fs.FS, opts cfsread.Options) *cachedFS {
	reg := decompress.NewRegistry()
	if err := reg.Register(lz4.New()); err != nil {
		panic("cachefs: failed to register default LZ4 decompressor: " + err.Error())
	}
	opts.Registry = reg

	return &cachedFS{
		reader:     cfsread.New(opts),
		src:        cfsread.Source{ID: id, FS: underlying},
		underlying: underlying,
	}
}

// Open opens a directory from the underlying FS, because cfsread reads only regular
// files. For a regular file it returns the cached contents, decompressed if a
// registered decompressor matches; only the first Open of a name does I/O. Open
// reads with context.Background, because fs.FS takes no context.
//
// Open returns an *fs.PathError wrapping fs.ErrNotExist for a missing file, and
// one wrapping fs.ErrClosed after Close.
func (c *cachedFS) Open(name string) (fs.File, error) {
	c.mu.RLock()
	closed := c.closed
	c.mu.RUnlock()
	if closed {
		return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrClosed}
	}

	info, err := fs.Stat(c.underlying, name)
	if err != nil {
		return nil, err
	}

	if info.IsDir() {
		return c.underlying.Open(name)
	}

	data, err := c.reader.Read(context.Background(), c.src, name)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
		}
		return nil, err
	}

	fi := &cachedFileInfo{
		name:    path.Base(name),
		size:    int64(len(data)),
		mode:    info.Mode(),
		modTime: info.ModTime(),
	}

	return &cachedFile{
		Reader: bytes.NewReader(data),
		info:   fi,
	}, nil
}

// Close releases the cfsread.Reader. Later calls to Open fail with fs.ErrClosed.
// Calling Close again does nothing and returns nil.
func (c *cachedFS) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	c.mu.Unlock()

	return c.reader.Close()
}

// cachedFile is an open file whose contents come from the cfsread cache. The
// cache owns the bytes, so nothing may modify them. The embedded bytes.Reader
// serves Read.
type cachedFile struct {
	*bytes.Reader
	info fs.FileInfo
}

// Close does nothing, because the data stays in the cache.
func (c *cachedFile) Close() error {
	return nil
}

// Stat returns the file info for the cached file.
func (c *cachedFile) Stat() (fs.FileInfo, error) {
	return c.info, nil
}

// cachedFileInfo describes a cached file. Size is the decompressed length, and
// ModTime comes from the underlying FS when the file was opened.
type cachedFileInfo struct {
	name    string
	size    int64
	mode    fs.FileMode
	modTime time.Time
}

func (i *cachedFileInfo) Name() string {
	return i.name
}

func (i *cachedFileInfo) Size() int64 {
	return i.size
}

func (i *cachedFileInfo) Mode() fs.FileMode {
	return i.mode
}

func (i *cachedFileInfo) ModTime() time.Time {
	return i.modTime
}

func (i *cachedFileInfo) IsDir() bool {
	return false
}

func (i *cachedFileInfo) Sys() any {
	return nil
}
