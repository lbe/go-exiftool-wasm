//go:build integration

package exiftool

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const repairXMP = `<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">Repair title</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta>`

func repairSubprocess(t *testing.T, mode string) bool {
	t.Helper()
	if os.Getenv("EXIFTOOL_REPAIR_CHILD") == mode {
		return false
	}
	root := t.TempDir()
	for _, dir := range []string{"cwd", "runtime", "storage/a", "other/b"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	src, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		t.Fatal(err)
	}
	src = repairWithoutXMP(t, src)
	packet := append([]byte("http://ns.adobe.com/xap/1.0/\x00"), []byte(repairXMP)...)
	segment := []byte{0xff, 0xe1, 0, 0}
	binary.BigEndian.PutUint16(segment[2:], uint16(len(packet)+2))
	image := append(append(append([]byte{}, src[:2]...), segment...), packet...)
	image = append(image, src[2:]...)
	for _, dir := range []string{"storage/a", "other/b"} {
		if err := os.WriteFile(filepath.Join(root, dir, "sample.jpg"), image, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, link := range [][2]string{{"alias", "storage"}, {"alias2", "alias"}, {"storage/nested", "../other/b"}} {
		if err := os.Symlink(link[1], filepath.Join(root, link[0])); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^"+t.Name()+"$", "-test.count=1", "-test.timeout=25s")
	cmd.Dir = filepath.Join(root, "cwd")
	cmd.Env = append(os.Environ(), "EXIFTOOL_REPAIR_CHILD="+mode, "EXIFTOOL_REPAIR_ROOT="+root, "TMPDIR="+filepath.Join(root, "runtime"))
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("isolated %s: %v\n%s", mode, err, out)
	}
	t.Logf("isolated %s:\n%s", mode, out)
	return true
}

func repairServer(t *testing.T) *Server {
	t.Helper()
	s, err := NewServer()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if _, err := s.Command("-ver"); err != nil {
		t.Fatal(err)
	}
	return s
}

func repairTags(t *testing.T, s *Server, path string) {
	t.Helper()
	out, err := s.Command("-json", "-G1", "-n", "-struct", path)
	if err != nil {
		t.Errorf("tags %s: %v", path, err)
		return
	}
	var records []map[string]any
	if err := json.Unmarshal(out, &records); err != nil || len(records) != 1 {
		t.Errorf("tags JSON: %v, records=%v, out=%q", err, records, out)
		return
	}
	for key, want := range map[string]string{"IFD0:Make": "TestMaker", "File:FileType": "JPEG", "XMP-dc:Title": "Repair title"} {
		if got := records[0][key]; got != want {
			t.Errorf("%s: got %#v, want %q", key, got, want)
		}
	}
}

func TestV2METARepair_OriginalAliasesAndStruct(t *testing.T) {
	if repairSubprocess(t, "aliases") {
		return
	}
	root := os.Getenv("EXIFTOOL_REPAIR_ROOT")
	s := repairServer(t)
	for _, rel := range []string{"alias/a/sample.jpg", "alias2/a/sample.jpg", "alias/nested/sample.jpg", "storage/a/sample.jpg"} {
		path := filepath.Join(root, rel)
		// The tags command must discover its operand without a preceding raw command.
		repairTags(t, s, path)
		out, err := s.Command("-q", "-q", "-b", "-XMP", path)
		if err != nil || !bytes.Equal(out, []byte(repairXMP)) {
			t.Errorf("raw %s: got %q, err=%v", path, out, err)
		}
	}
	if err := s.Shutdown(); err != nil {
		t.Fatal(err)
	}
}

func TestV2METARepair_RemountStderrIdentity(t *testing.T) {
	if repairSubprocess(t, "stderr-identity") {
		return
	}
	root := os.Getenv("EXIFTOOL_REPAIR_ROOT")
	for _, offset := range []int{18, 70_000} {
		s := repairServer(t)
		s.generation.sio.stderrMu.Lock()
		s.generation.sio.stderrB.Reset()
		s.generation.sio.stderrMu.Unlock()
		_, _ = s.generation.sio.WriteStderr(bytes.Repeat([]byte{'s'}, offset))
		path := filepath.Join(root, "alias", "a", fmt.Sprintf("missing-%d.jpg", offset))
		_, err := s.Command("-q", "-q", "-b", "-XMP", path)
		if err == nil || !strings.Contains(err.Error(), "Error: File not found - "+path) {
			t.Errorf("old offset %d: intact error identity/operand missing: %v", offset, err)
		}
		if err := s.Shutdown(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestV2METARepair_StderrOverflowAndRecovery(t *testing.T) {
	if repairSubprocess(t, "stderr-overflow") {
		return
	}
	s := repairServer(t)
	_, err := s.Command("-echo4", strings.Repeat("diagnostic", 8000))
	if err == nil || (!strings.Contains(err.Error(), "overflow") && !strings.Contains(err.Error(), "truncat")) {
		t.Errorf("stderr overflow must be explicit: %v", err)
	}
	for i := 0; i < 20; i++ {
		path := filepath.Join(os.Getenv("EXIFTOOL_REPAIR_ROOT"), "alias", "a", "missing.jpg")
		_, err := s.Command("-q", "-q", "-b", "-XMP", path)
		if err == nil || !strings.Contains(err.Error(), "File not found - "+path) {
			t.Errorf("failure %d: %v", i, err)
		}
		s.generation.sio.stderrMu.Lock()
		retained := s.generation.sio.stderrB.Len()
		s.generation.sio.stderrMu.Unlock()
		if retained != 0 {
			t.Errorf("completed command %d retained %d stderr bytes", i, retained)
			break
		}
	}
	out, err := s.Command("-ver")
	if err != nil || len(bytes.TrimSpace(out)) == 0 {
		t.Fatalf("valid command after diagnostics: out=%q err=%v", out, err)
	}
	if err := s.Shutdown(); err != nil {
		t.Fatal(err)
	}
}

func TestV2METARepair_OneShotOriginalAlias(t *testing.T) {
	if repairSubprocess(t, "oneshot") {
		return
	}
	path := filepath.Join(os.Getenv("EXIFTOOL_REPAIR_ROOT"), "alias2", "a", "sample.jpg")
	out, err := Command(nil, "-q", "-q", "-b", "-XMP", path)
	if err != nil || !bytes.Equal(out, []byte(repairXMP)) {
		t.Errorf("one-shot raw original alias: out=%q err=%v", out, err)
	}
	out, err = Command(nil, "-json", "-G1", "-n", "-struct", path)
	if err != nil {
		t.Fatalf("one-shot tags original alias: %v", err)
	}
	var records []map[string]any
	if err := json.Unmarshal(out, &records); err != nil || len(records) != 1 || records[0]["IFD0:Make"] != "TestMaker" {
		t.Errorf("one-shot tags: records=%v err=%v", records, err)
	}
}

func repairWithoutXMP(t *testing.T, image []byte) []byte {
	t.Helper()
	out := append([]byte{}, image[:2]...)
	for pos := 2; pos < len(image); {
		if pos+2 > len(image) || image[pos] != 0xff {
			t.Fatal("invalid JPEG marker")
		}
		marker := image[pos+1]
		if marker == 0xda || marker == 0xd9 {
			return append(out, image[pos:]...)
		}
		if pos+4 > len(image) {
			t.Fatal("short JPEG segment")
		}
		n := int(binary.BigEndian.Uint16(image[pos+2 : pos+4]))
		if n < 2 || pos+2+n > len(image) {
			t.Fatal("invalid JPEG segment length")
		}
		segment := image[pos : pos+2+n]
		if marker != 0xe1 || !bytes.HasPrefix(segment[4:], []byte("http://ns.adobe.com/xap/1.0/\x00")) {
			out = append(out, segment...)
		}
		pos += 2 + n
	}
	t.Fatal("missing JPEG scan")
	return nil
}
