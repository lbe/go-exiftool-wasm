package guestarena

import (
	"context"
	"fmt"

	"github.com/tetratelabs/wazero/api"
)

// DefaultInitialCapacity is the initial guest allocation size used by an Arena.
const DefaultInitialCapacity uint32 = 64 * 1024

// Memory abstracts the subset of guest linear-memory operations the arena needs.
type Memory interface {
	Read(offset, byteCount uint32) ([]byte, bool)
	Write(offset uint32, v []byte) bool
	PutByte(offset uint32, v byte) bool
	WriteUint32Le(offset, v uint32) bool
	WriteString(offset uint32, v string) bool
}

// AllocFunc allocates size bytes in guest memory and returns the guest pointer.
type AllocFunc func(context.Context, int) (uint32, error)

// FreeFunc releases a guest allocation previously returned by [AllocFunc].
type FreeFunc func(context.Context, uint32) error

// Arena owns one reusable guest allocation plus a reusable host scratch buffer.
type Arena struct {
	mem    Memory
	malloc AllocFunc
	free   FreeFunc

	base   uint32
	cap    uint32
	offset uint32
	closed bool

	scratch []byte
}

// EvalLayout describes the guest pointers needed to invoke zeroperl_eval.
type EvalLayout struct {
	ScriptPtr uint32
	ArgvPtr   uint32
}

type wazeroMemory struct {
	api.Memory
}

func (m wazeroMemory) PutByte(offset uint32, v byte) bool {
	return m.WriteByte(offset, v)
}

// New creates an arena using explicit guest-memory and allocator hooks.
func New(mem Memory, malloc AllocFunc, free FreeFunc) *Arena {
	return &Arena{
		mem:    mem,
		malloc: malloc,
		free:   free,
	}
}

// NewWazero binds wazero guest memory plus malloc/free exports into an [Arena].
func NewWazero(mem api.Memory, mallocFn, freeFn api.Function) *Arena {
	return New(
		wazeroMemory{Memory: mem},
		func(ctx context.Context, size int) (uint32, error) {
			res, err := mallocFn.Call(ctx, uint64(size))
			if err != nil {
				return 0, fmt.Errorf("malloc failed for %d bytes: %w", size, err)
			}
			return uint32(res[0]), nil
		},
		func(ctx context.Context, ptr uint32) error {
			_, err := freeFn.Call(ctx, uint64(ptr))
			return err
		},
	)
}

// Mark returns the current arena offset for later reset.
func (a *Arena) Mark() uint32 {
	return a.offset
}

// Reset rewinds the transient allocation offset to mark.
func (a *Arena) Reset(mark uint32) {
	if mark <= a.offset {
		a.offset = mark
	}
}

// Ensure grows the guest allocation so that size bytes are addressable from the start.
func (a *Arena) Ensure(ctx context.Context, size uint32) error {
	if a.closed {
		return fmt.Errorf("guest arena is closed")
	}
	if size <= a.cap {
		return nil
	}
	newCap := nextPowerOfTwo(max(size, DefaultInitialCapacity))
	newBase, err := a.malloc(ctx, int(newCap))
	if err != nil {
		return err
	}
	if a.base != 0 && a.offset > 0 {
		existing, ok := a.mem.Read(a.base, a.offset)
		if !ok {
			_ = a.free(ctx, newBase)
			return fmt.Errorf("failed to read %d bytes from guest arena", a.offset)
		}
		buf := append([]byte(nil), existing...)
		if !a.mem.Write(newBase, buf) {
			_ = a.free(ctx, newBase)
			return fmt.Errorf("failed to copy %d bytes into grown guest arena", a.offset)
		}
	}
	oldBase := a.base
	a.base = newBase
	a.cap = newCap
	if oldBase != 0 {
		if err := a.free(ctx, oldBase); err != nil {
			return fmt.Errorf("failed to free guest arena at address %d: %w", oldBase, err)
		}
	}
	return nil
}

// Alloc reserves size bytes in guest memory aligned to align and returns the guest pointer.
func (a *Arena) Alloc(ctx context.Context, size, align uint32) (uint32, error) {
	if align == 0 {
		align = 1
	}
	offset := alignOffset(a.offset, align)
	end := offset + size
	if err := a.Ensure(ctx, end); err != nil {
		return 0, err
	}
	ptr := a.base + offset
	a.offset = end
	return ptr, nil
}

// WriteCString writes s plus a trailing NUL byte into guest memory.
func (a *Arena) WriteCString(ctx context.Context, s string) (uint32, error) {
	ptr, err := a.Alloc(ctx, uint32(len(s)+1), 1)
	if err != nil {
		return 0, err
	}
	if !a.mem.WriteString(ptr, s) || !a.mem.PutByte(ptr+uint32(len(s)), 0) {
		return 0, fmt.Errorf("failed to write %d-byte string at address %d", len(s), ptr)
	}
	return ptr, nil
}

// WriteBytes writes b into guest memory without a terminator.
func (a *Arena) WriteBytes(ctx context.Context, b []byte) (uint32, error) {
	ptr, err := a.Alloc(ctx, uint32(len(b)), 1)
	if err != nil {
		return 0, err
	}
	if !a.mem.Write(ptr, b) {
		return 0, fmt.Errorf("failed to write %d bytes at address %d", len(b), ptr)
	}
	return ptr, nil
}

// WriteNULTerminatedBytes writes b followed by a trailing NUL byte into guest memory.
func (a *Arena) WriteNULTerminatedBytes(ctx context.Context, b []byte) (uint32, error) {
	ptr, err := a.Alloc(ctx, uint32(len(b)+1), 1)
	if err != nil {
		return 0, err
	}
	if !a.mem.Write(ptr, b) || !a.mem.PutByte(ptr+uint32(len(b)), 0) {
		return 0, fmt.Errorf("failed to write %d bytes at address %d", len(b), ptr)
	}
	return ptr, nil
}

// WriteUint32Table writes values as little-endian uint32 entries starting at ptr.
func (a *Arena) WriteUint32Table(_ context.Context, ptr uint32, values []uint32) error {
	for i, value := range values {
		if !a.mem.WriteUint32Le(ptr+uint32(i*4), value) {
			return fmt.Errorf("failed to write uint32 value %d at index %d", value, i)
		}
	}
	return nil
}

// Bytes returns a guest-memory view of size bytes starting at ptr.
func (a *Arena) Bytes(ptr, size uint32) ([]byte, error) {
	b, ok := a.mem.Read(ptr, size)
	if !ok {
		return nil, fmt.Errorf("failed to read %d bytes at address %d", size, ptr)
	}
	return b, nil
}

// BuildExecutePayload builds one newline-delimited stay_open command payload in scratch.
func (a *Arena) BuildExecutePayload(lines []string, execute string) []byte {
	n := len(execute) + 1
	for _, line := range lines {
		n += len(line) + 1
	}

	if cap(a.scratch) < n {
		a.scratch = make([]byte, n, n*2)
	} else {
		a.scratch = a.scratch[:n]
	}

	i := 0
	for _, line := range lines {
		i += copy(a.scratch[i:], line)
		a.scratch[i] = '\n'
		i++
	}
	i += copy(a.scratch[i:], execute)
	a.scratch[i] = '\n'

	return a.scratch
}

// Close frees the backing guest allocation exactly once.
func (a *Arena) Close(ctx context.Context) error {
	if a.closed {
		return nil
	}
	a.closed = true
	base := a.base
	a.base = 0
	a.cap = 0
	a.offset = 0
	if base == 0 {
		return nil
	}
	return a.free(ctx, base)
}

// PackEvalData packs the startup script and argv table into guest memory.
func PackEvalData(ctx context.Context, arena *Arena, script []byte, args []string) (EvalLayout, error) {
	mark := arena.Mark()

	size := uint32(len(script) + 1)
	argvOffset := size
	if len(args) > 0 {
		argvOffset = alignOffset(argvOffset, 4)
		size = argvOffset + uint32(len(args)*4)
	}

	for _, arg := range args {
		size += uint32(len(arg) + 1)
	}
	if err := arena.Ensure(ctx, mark+size); err != nil {
		return EvalLayout{}, err
	}

	scriptPtr, err := arena.WriteNULTerminatedBytes(ctx, script)
	if err != nil {
		arena.Reset(mark)
		return EvalLayout{}, err
	}

	var argvPtr uint32
	argPtrs := make([]uint32, len(args))
	if len(args) > 0 {
		argvPtr, err = arena.Alloc(ctx, uint32(len(args)*4), 4)
		if err != nil {
			arena.Reset(mark)
			return EvalLayout{}, err
		}
	}

	for i, arg := range args {
		argPtrs[i], err = arena.WriteCString(ctx, arg)
		if err != nil {
			arena.Reset(mark)
			return EvalLayout{}, err
		}
	}

	if len(argPtrs) > 0 {
		if err := arena.WriteUint32Table(ctx, argvPtr, argPtrs); err != nil {
			arena.Reset(mark)
			return EvalLayout{}, err
		}
	}

	return EvalLayout{ScriptPtr: scriptPtr, ArgvPtr: argvPtr}, nil
}

// PackExecutePayload writes one newline-delimited stay_open command payload into guest memory.
func PackExecutePayload(ctx context.Context, arena *Arena, lines []string, execute string) (ptr, size uint32, err error) {
	total := uint32(len(execute) + 1)
	for _, line := range lines {
		total += uint32(len(line) + 1)
	}
	ptr, err = arena.WriteBytes(ctx, make([]byte, total))
	if err != nil {
		return 0, 0, err
	}

	buf, err := arena.Bytes(ptr, total)
	if err != nil {
		return 0, 0, err
	}

	i := 0
	for _, line := range lines {
		i += copy(buf[i:], line)
		buf[i] = '\n'
		i++
	}
	i += copy(buf[i:], execute)
	buf[i] = '\n'
	return ptr, total, nil
}

func alignOffset(offset, align uint32) uint32 {
	mask := align - 1
	return (offset + mask) &^ mask
}

func nextPowerOfTwo(v uint32) uint32 {
	if v <= 1 {
		return 1
	}
	v--
	v |= v >> 1
	v |= v >> 2
	v |= v >> 4
	v |= v >> 8
	v |= v >> 16
	return v + 1
}

func max(a, b uint32) uint32 {
	if a > b {
		return a
	}
	return b
}
