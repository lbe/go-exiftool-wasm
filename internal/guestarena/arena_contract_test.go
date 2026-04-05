package guestarena

import (
	"bytes"
	"context"
	"testing"
)

func TestArenaLazyAllocation(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	if got := len(alloc.mallocs); got != 0 {
		t.Fatalf("unexpected mallocs before use: %d", got)
	}

	if err := arena.Ensure(context.Background(), 1); err != nil {
		t.Fatalf("Ensure: %v", err)
	}

	if got, want := len(alloc.mallocs), 1; got != want {
		t.Fatalf("malloc count: got %d, want %d", got, want)
	}
	if got, want := alloc.mallocs[0], DefaultInitialCapacity; got != want {
		t.Fatalf("first block size: got %d, want %d", got, want)
	}
}

func TestArenaAlignedAllocation(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	ptr0, err := arena.Alloc(context.Background(), 3, 8)
	if err != nil {
		t.Fatalf("Alloc #0: %v", err)
	}
	if got, want := ptr0, uint32(0x1000); got != want {
		t.Fatalf("first ptr: got 0x%x, want 0x%x", got, want)
	}

	ptr1, err := arena.Alloc(context.Background(), 1, 8)
	if err != nil {
		t.Fatalf("Alloc #1: %v", err)
	}
	if got, want := ptr1, uint32(0x1008); got != want {
		t.Fatalf("second ptr: got 0x%x, want 0x%x", got, want)
	}
}

func TestArenaGrowthPreservesWrittenBytes(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	ptr, err := arena.WriteCString(context.Background(), "hello")
	if err != nil {
		t.Fatalf("WriteCString: %v", err)
	}
	if _, err := arena.Alloc(context.Background(), DefaultInitialCapacity, 1); err != nil {
		t.Fatalf("growth alloc: %v", err)
	}

	if got, want := len(alloc.mallocs), 2; got != want {
		t.Fatalf("malloc count: got %d, want %d", got, want)
	}
	if got, want := len(alloc.frees), 1; got != want {
		t.Fatalf("free count: got %d, want %d", got, want)
	}
	if got, want := mem.StringAt(ptr), "hello"; got != want {
		t.Fatalf("preserved contents: got %q, want %q", got, want)
	}
}

func TestArenaMarkResetReuse(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	first, err := arena.Alloc(context.Background(), 8, 1)
	if err != nil {
		t.Fatalf("Alloc #0: %v", err)
	}
	mark := arena.Mark()
	second, err := arena.Alloc(context.Background(), 8, 1)
	if err != nil {
		t.Fatalf("Alloc #1: %v", err)
	}
	arena.Reset(mark)
	third, err := arena.Alloc(context.Background(), 8, 1)
	if err != nil {
		t.Fatalf("Alloc #2: %v", err)
	}

	if first != 0x1000 {
		t.Fatalf("first ptr = 0x%x", first)
	}
	if second != 0x1008 {
		t.Fatalf("second ptr = 0x%x", second)
	}
	if third != second {
		t.Fatalf("reset did not reuse allocation: got 0x%x, want 0x%x", third, second)
	}
}

func TestArenaCloseIdempotent(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	if _, err := arena.Alloc(context.Background(), 8, 1); err != nil {
		t.Fatalf("Alloc: %v", err)
	}

	if err := arena.Close(context.Background()); err != nil {
		t.Fatalf("Close #0: %v", err)
	}
	if err := arena.Close(context.Background()); err != nil {
		t.Fatalf("Close #1: %v", err)
	}
	if got, want := len(alloc.frees), 1; got != want {
		t.Fatalf("free count: got %d, want %d", got, want)
	}
}

func TestArenaWriteHelpers(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	cstr, err := arena.WriteCString(context.Background(), "abc")
	if err != nil {
		t.Fatalf("WriteCString: %v", err)
	}
	if got, want := mem.StringAt(cstr), "abc"; got != want {
		t.Fatalf("cstring contents: got %q, want %q", got, want)
	}
	if got := mem.buf[int(cstr+3)]; got != 0 {
		t.Fatalf("cstring terminator: got %d, want 0", got)
	}

	raw, err := arena.WriteNULTerminatedBytes(context.Background(), []byte{1, 2, 3})
	if err != nil {
		t.Fatalf("WriteBytes: %v", err)
	}
	if got, want := mem.buf[int(raw):int(raw+3)], []byte{1, 2, 3}; !bytes.Equal(got, want) {
		t.Fatalf("raw bytes: got %v, want %v", got, want)
	}
	if got := mem.buf[int(raw+3)]; got != 0 {
		t.Fatalf("raw terminator: got %d, want 0", got)
	}

	tablePtr, err := arena.Alloc(context.Background(), 8, 4)
	if err != nil {
		t.Fatalf("Alloc table: %v", err)
	}
	if err := arena.WriteUint32Table(context.Background(), tablePtr, []uint32{cstr, raw}); err != nil {
		t.Fatalf("WriteUint32Table: %v", err)
	}
	if got, ok := mem.ReadUint32Le(tablePtr); !ok || got != cstr {
		t.Fatalf("table[0]: got %d, ok=%v want %d", got, ok, cstr)
	}
	if got, ok := mem.ReadUint32Le(tablePtr + 4); !ok || got != raw {
		t.Fatalf("table[1]: got %d, ok=%v want %d", got, ok, raw)
	}
}

func TestArenaWriteFailureRecovery(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	mark := arena.Mark()
	mem.FailAt(0x1000)

	if _, err := PackEvalData(context.Background(), arena, []byte("boom"), []string{"arg"}); err == nil {
		t.Fatal("PackEvalData unexpectedly succeeded")
	}

	arena.Reset(mark)
	delete(mem.failAt, 0x1000)
	layout, err := PackEvalData(context.Background(), arena, []byte("ok"), []string{"arg"})
	if err != nil {
		t.Fatalf("PackEvalData after reset: %v", err)
	}
	if got, want := layout.ScriptPtr, uint32(0x1000); got != want {
		t.Fatalf("reused ptr: got 0x%x, want 0x%x", got, want)
	}
}

func TestArenaPackScriptAndArgv(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	script := []byte("use IO::Handle;")
	args := []string{"-stay_open", "true", "-@"}

	layout, err := PackEvalData(context.Background(), arena, script, args)
	if err != nil {
		t.Fatalf("PackEvalData: %v", err)
	}
	if got, want := layout.ScriptPtr, uint32(0x1000); got != want {
		t.Fatalf("script ptr: got 0x%x, want 0x%x", got, want)
	}
	if got, want := mem.StringAt(layout.ScriptPtr), string(script); got != want {
		t.Fatalf("script contents: got %q, want %q", got, want)
	}
	if got := mem.buf[int(layout.ScriptPtr)+len(script)]; got != 0 {
		t.Fatalf("script terminator: got %d, want 0", got)
	}
	if layout.ArgvPtr == 0 {
		t.Fatal("argvPtr unexpectedly zero")
	}
	if layout.ArgvPtr%4 != 0 {
		t.Fatalf("argvPtr not 4-byte aligned: 0x%x", layout.ArgvPtr)
	}
	for i, want := range args {
		ptr, ok := mem.ReadUint32Le(layout.ArgvPtr + uint32(i*4))
		if !ok {
			t.Fatalf("argv[%d] pointer unreadable", i)
		}
		if got := mem.StringAt(ptr); got != want {
			t.Fatalf("argv[%d]: got %q, want %q", i, got, want)
		}
	}
}

func TestArenaPackZeroArgs(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	layout, err := PackEvalData(context.Background(), arena, []byte("x"), nil)
	if err != nil {
		t.Fatalf("PackEvalData: %v", err)
	}
	if layout.ScriptPtr == 0 {
		t.Fatal("scriptPtr unexpectedly zero")
	}
	if layout.ArgvPtr != 0 {
		t.Fatalf("argvPtr = 0x%x, want 0", layout.ArgvPtr)
	}
}

func TestArenaPackExecutePayload(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	ptr, size, err := PackExecutePayload(context.Background(), arena, []string{"-Artist", "testdata/sample.jpg"}, "-execute1854673209")
	if err != nil {
		t.Fatalf("PackExecutePayload: %v", err)
	}
	if got, want := ptr, uint32(0x1000); got != want {
		t.Fatalf("payload ptr: got 0x%x, want 0x%x", got, want)
	}
	payload, err := arena.Bytes(ptr, size)
	if err != nil {
		t.Fatalf("Bytes: %v", err)
	}
	want := []byte("-Artist\ntestdata/sample.jpg\n-execute1854673209\n")
	if !bytes.Equal(payload, want) {
		t.Fatalf("payload: got %q, want %q", payload, want)
	}
}

func TestArenaPackExecutePayloadZeroArgs(t *testing.T) {
	alloc := newFakeGuestAllocator(0x1000)
	mem := newFakeGuestMemory(1 << 20)
	arena := New(mem, alloc.Malloc, alloc.Free)

	ptr, size, err := PackExecutePayload(context.Background(), arena, nil, "-execute1854673209")
	if err != nil {
		t.Fatalf("PackExecutePayload: %v", err)
	}
	payload, err := arena.Bytes(ptr, size)
	if err != nil {
		t.Fatalf("Bytes: %v", err)
	}
	want := []byte("-execute1854673209\n")
	if !bytes.Equal(payload, want) {
		t.Fatalf("payload: got %q, want %q", payload, want)
	}
}

func TestArenaBuildExecutePayloadReusesScratch(t *testing.T) {
	arena := New(newFakeGuestMemory(64), nil, nil)

	first := arena.BuildExecutePayload([]string{"-json", "test.jpg"}, "-execute1854673209")
	if got, want := string(first), "-json\ntest.jpg\n-execute1854673209\n"; got != want {
		t.Fatalf("first payload: got %q, want %q", got, want)
	}

	firstBase := &first[0]
	second := arena.BuildExecutePayload([]string{"-ver"}, "-execute1854673209")
	if got, want := string(second), "-ver\n-execute1854673209\n"; got != want {
		t.Fatalf("second payload: got %q, want %q", got, want)
	}
	if &second[0] != firstBase {
		t.Fatal("expected scratch buffer reuse")
	}
}
