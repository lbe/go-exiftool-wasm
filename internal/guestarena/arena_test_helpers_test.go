package guestarena

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
)

const testArenaMaxAlign = 8

type fakeGuestAllocator struct {
	nextPtr    uint32
	mallocs    []uint32
	frees      []uint32
	failMalloc bool
	failFree   bool
}

func newFakeGuestAllocator(base uint32) *fakeGuestAllocator {
	return &fakeGuestAllocator{nextPtr: base}
}

func (a *fakeGuestAllocator) Malloc(_ context.Context, size int) (uint32, error) {
	if a.failMalloc {
		return 0, errors.New("malloc failed")
	}
	if size <= 0 {
		size = 1
	}
	ptr := a.nextPtr
	aligned := alignUp(uint32(size), testArenaMaxAlign)
	a.nextPtr += aligned
	a.mallocs = append(a.mallocs, uint32(size))
	return ptr, nil
}

func (a *fakeGuestAllocator) Free(_ context.Context, ptr uint32) error {
	a.frees = append(a.frees, ptr)
	if a.failFree {
		return errors.New("free failed")
	}
	return nil
}

type fakeGuestMemory struct {
	buf      []byte
	failAt   map[uint32]struct{}
	writeLog []string
}

func newFakeGuestMemory(size int) *fakeGuestMemory {
	return &fakeGuestMemory{buf: make([]byte, size)}
}

func (m *fakeGuestMemory) FailAt(offset uint32) {
	if m.failAt == nil {
		m.failAt = map[uint32]struct{}{}
	}
	m.failAt[offset] = struct{}{}
}

func (m *fakeGuestMemory) Read(offset, byteCount uint32) ([]byte, bool) {
	end := offset + byteCount
	if int(end) > len(m.buf) {
		return nil, false
	}
	return m.buf[int(offset):int(end)], true
}

func (m *fakeGuestMemory) ReadUint32Le(offset uint32) (uint32, bool) {
	end := offset + 4
	if int(end) > len(m.buf) {
		return 0, false
	}
	return binary.LittleEndian.Uint32(m.buf[int(offset):int(end)]), true
}

func (m *fakeGuestMemory) PutByte(offset uint32, v byte) bool {
	if m.writeBlocked(offset) {
		return false
	}
	if int(offset) >= len(m.buf) {
		return false
	}
	m.buf[int(offset)] = v
	m.writeLog = append(m.writeLog, fmt.Sprintf("byte@%d=%d", offset, v))
	return true
}

func (m *fakeGuestMemory) WriteUint32Le(offset, v uint32) bool {
	if m.writeBlocked(offset) {
		return false
	}
	end := offset + 4
	if int(end) > len(m.buf) {
		return false
	}
	binary.LittleEndian.PutUint32(m.buf[int(offset):int(end)], v)
	m.writeLog = append(m.writeLog, fmt.Sprintf("u32@%d=%d", offset, v))
	return true
}

func (m *fakeGuestMemory) Write(offset uint32, v []byte) bool {
	if m.writeBlocked(offset) {
		return false
	}
	end := offset + uint32(len(v))
	if int(end) > len(m.buf) {
		return false
	}
	copy(m.buf[int(offset):int(end)], v)
	m.writeLog = append(m.writeLog, fmt.Sprintf("bytes@%d=%d", offset, len(v)))
	return true
}

func (m *fakeGuestMemory) WriteString(offset uint32, v string) bool {
	return m.Write(offset, []byte(v))
}

func (m *fakeGuestMemory) writeBlocked(offset uint32) bool {
	if m.failAt == nil {
		return false
	}
	_, ok := m.failAt[offset]
	return ok
}

func (m *fakeGuestMemory) StringAt(offset uint32) string {
	end := offset
	for end < uint32(len(m.buf)) && m.buf[int(end)] != 0 {
		end++
	}
	return string(m.buf[int(offset):int(end)])
}

func alignUp(v, align uint32) uint32 {
	if align == 0 {
		return v
	}
	mask := align - 1
	return (v + mask) &^ mask
}
