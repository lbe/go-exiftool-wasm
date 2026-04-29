// cachefs.go provides cachedFS, an internal fs.FS implementation that wraps any underlying
// fs.FS with transparent LZ4 decompression and LRU caching via github.com/lbe/cfsread.
//
// cachedFS is used by perlFS() to serve the embedded perl-wasi-prefix tree: the
// embedded .pm files are stored LZ4-compressed in the binary, and cachedFS
// decompresses them on first access and caches the result for subsequent reads.
// Concurrent accesses to the same path are coalesced via singleflight so only
// one goroutine performs I/O and decompression.
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

// cachedFS wraps an underlying fs.FS with a cfsread.Reader that provides
// magic-byte decompression (e.g., LZ4) and an LRU byte cache. It implements
// fs.FS and is safe for concurrent use. Directories are passed through directly
// to the underlying FS; regular files are served via the cfsread cache.
type cachedFS struct {
	reader     *cfsread.Reader
	src        cfsread.Source
	underlying fs.FS

	mu     sync.RWMutex
	closed bool
}

// newCachedFS creates a new cachedFS that wraps underlying with a cfsread.Reader
// configured by opts. id is the cache namespace for this source and must be
// non-empty; it is used to isolate cache entries from other cachedFS instances.
//
// newCachedFS always configures a default registry with LZ4 support for
// transparent decompression of the embedded perl-wasi-prefix tree.
//
// The caller owns the returned cachedFS and should call Close when done to
// release the underlying cfsread.Reader. For process-lifetime singletons (such
// as perlFS()), Close is not required.
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

// Open opens the named file or directory. If name refers to a directory in the
// underlying FS, Open delegates to the underlying FS directly (cfsread handles
// only regular files). For regular files, Open calls cfsread.Reader.Read using
// context.Background() (the fs.FS interface does not accept a context); the
// file bytes are decompressed if a matching decompressor is registered, then
// cached. Subsequent Opens of the same name return cached bytes without I/O.
//
// Returns fs.ErrNotExist (wrapped in *fs.PathError) if the file does not exist,
// and fs.ErrClosed (wrapped in *fs.PathError) after Close has been called.
func (c *cachedFS) Open(name string) (fs.File, error) {
	c.mu.RLock()
	closed := c.closed
	c.mu.RUnlock()
	if closed {
		return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrClosed}
	}

	// Try to stat via underlying FS to determine if it's a file or directory
	info, err := fs.Stat(c.underlying, name)
	if err != nil {
		// If not found, return the same error
		return nil, err
	}

	if info.IsDir() {
		// Delegate to underlying FS for directories
		return c.underlying.Open(name)
	}

	// Regular file: use cfsread for caching and decompression
	data, err := c.reader.Read(context.Background(), c.src, name)
	if err != nil {
		// Map to fs.ErrNotExist if appropriate
		if errors.Is(err, fs.ErrNotExist) {
			return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
		}
		return nil, err
	}

	// Build cachedFile with file info
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

// Close marks the cachedFS as closed and releases the underlying cfsread.Reader.
// Subsequent Open calls on a closed cachedFS will return an error. It is safe to
// call Close more than once. If Close is not called, the Reader remains live for
// the process lifetime (acceptable for module-level singletons).
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

// cachedFile implements fs.File for a file whose contents have been read and
// (optionally) decompressed by the cfsread.Reader. The byte slice is owned by
// the cfsread cache and must not be mutated. Read is delegated to an embedded
// bytes.Reader; Close is a no-op because the data lives in the cache.
type cachedFile struct {
	*bytes.Reader
	info fs.FileInfo
}

// Close is a no-op for cached files as they're backed by in-memory byte slices.
func (c *cachedFile) Close() error {
	return nil
}

// Stat returns the file info for the cached file.
func (c *cachedFile) Stat() (fs.FileInfo, error) {
	return c.info, nil
}

// cachedFileInfo implements fs.FileInfo for a cached file. Size reflects the
// decompressed byte length. ModTime is taken from the underlying FS entry at
// the time of the Open call.
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
