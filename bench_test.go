package exiftool

import (
	"bytes"
	"context"
	"fmt"
	"hash/fnv"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
)

const helperProcessModeEnv = "GO_EXIFTOOL_HELPER_PROCESS_MODE"
const helperProcessCacheDirEnv = "GO_EXIFTOOL_HELPER_CACHE_DIR"
const helperProcessWorkersEnv = runtimeWorkersEnv

// benchmarkParallelServerSink keeps the writer-side work observable so the
// compiler cannot eliminate it from BenchmarkServer_ParallelMixedRead.
var benchmarkParallelServerSink struct {
	sum   uint64
	count uint64
}

func TestHelperProcess(t *testing.T) {
	mode := os.Getenv(helperProcessModeEnv)
	if mode == "" {
		return
	}

	CacheDir = os.Getenv(helperProcessCacheDirEnv)

	switch mode {
	case "command-version":
		if _, err := Command(nil, "-ver"); err != nil {
			t.Fatal(err)
		}
	case "run-version":
		if _, err := Run(context.Background(), os.DirFS("testdata"), "-ver"); err != nil {
			t.Fatal(err)
		}
	case "newserver":
		e, err := NewServer()
		if err != nil {
			t.Fatal(err)
		}
		if err := e.Shutdown(); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("unknown helper mode %q", mode)
	}
}

func runHelperProcess(b testing.TB, mode, cacheDir, runtimeMode string, debugInfoEnabled bool, workers int) {
	b.Helper()

	cmd := exec.Command(os.Args[0], "-test.run=TestHelperProcess")
	cmd.Dir = "."
	debugInfo := "1"
	if !debugInfoEnabled {
		debugInfo = "0"
	}
	cmd.Env = append(os.Environ(),
		helperProcessModeEnv+"="+mode,
		helperProcessCacheDirEnv+"="+cacheDir,
		runtimeModeEnv+"="+runtimeMode,
		runtimeDebugInfoEnv+"="+debugInfo,
		helperProcessWorkersEnv+"="+fmt.Sprintf("%d", workers),
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		b.Fatalf("helper process failed: %v\n%s", err, out)
	}
}

func benchmarkProcessCacheCold(b *testing.B, mode, runtimeMode string, debugInfoEnabled bool, workers int) {
	parentCacheDir := b.TempDir()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		cacheDir := filepath.Join(parentCacheDir, fmt.Sprintf("cold-%d", i))
		if err := os.MkdirAll(cacheDir, 0o755); err != nil {
			b.Fatal(err)
		}
		runHelperProcess(b, mode, cacheDir, runtimeMode, debugInfoEnabled, workers)
	}
}

func benchmarkProcessCacheWarm(b *testing.B, mode, runtimeMode string, debugInfoEnabled bool, workers int) {
	cacheDir := b.TempDir()
	runHelperProcess(b, mode, cacheDir, runtimeMode, debugInfoEnabled, workers)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		runHelperProcess(b, mode, cacheDir, runtimeMode, debugInfoEnabled, workers)
	}
}

// ---------------------------------------------------------------------------
// Category 0: Process-level Persistent Cache Reuse
// ---------------------------------------------------------------------------

func BenchmarkProcessCommand_Version_Cold(b *testing.B) {
	benchmarkProcessCacheCold(b, "command-version", "compiler", true, 0)
}

func BenchmarkProcessCommand_Version_Warm(b *testing.B) {
	benchmarkProcessCacheWarm(b, "command-version", "compiler", true, 0)
}

func BenchmarkProcessRun_Version_Cold(b *testing.B) {
	benchmarkProcessCacheCold(b, "run-version", "compiler", true, 0)
}

func BenchmarkProcessRun_Version_Warm(b *testing.B) {
	benchmarkProcessCacheWarm(b, "run-version", "compiler", true, 0)
}

func BenchmarkProcessNewServer_Cold(b *testing.B) {
	benchmarkProcessCacheCold(b, "newserver", "compiler", true, 0)
}

func BenchmarkProcessNewServer_Warm(b *testing.B) {
	benchmarkProcessCacheWarm(b, "newserver", "compiler", true, 0)
}

func BenchmarkProcessNewServer_Cold_NoDebugInfo(b *testing.B) {
	benchmarkProcessCacheCold(b, "newserver", "compiler", false, 0)
}

func BenchmarkProcessNewServer_Warm_NoDebugInfo(b *testing.B) {
	benchmarkProcessCacheWarm(b, "newserver", "compiler", false, 0)
}

func BenchmarkProcessNewServer_Cold_Interpreter(b *testing.B) {
	benchmarkProcessCacheCold(b, "newserver", "interpreter", false, 0)
}

func BenchmarkProcessNewServer_Warm_Interpreter(b *testing.B) {
	benchmarkProcessCacheWarm(b, "newserver", "interpreter", false, 0)
}

func BenchmarkProcessNewServer_Cold_Workers1(b *testing.B) {
	benchmarkProcessCacheCold(b, "newserver", "compiler", false, 1)
}

func BenchmarkProcessNewServer_Cold_Workers2(b *testing.B) {
	benchmarkProcessCacheCold(b, "newserver", "compiler", false, 2)
}

func BenchmarkProcessNewServer_Cold_Workers4(b *testing.B) {
	benchmarkProcessCacheCold(b, "newserver", "compiler", false, 4)
}

func BenchmarkProcessNewServer_Cold_Workers8(b *testing.B) {
	benchmarkProcessCacheCold(b, "newserver", "compiler", false, 8)
}

// ---------------------------------------------------------------------------
// Category 1: Cold Start (full lifecycle inside b.N loop)
// ---------------------------------------------------------------------------

// BenchmarkCommand_Version measures the full cold-start cost of a single-shot
// Command invocation: runtime creation, WASM compilation, Perl init, execution,
// and teardown.
func BenchmarkCommand_Version(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkRun_Version measures cold-start via Run with an explicit fs.FS.
func BenchmarkRun_Version(b *testing.B) {
	ctx := context.Background()
	workFS := os.DirFS("testdata")
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Run(ctx, workFS, "-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkNewServer measures full server lifecycle: creation + shutdown.
func BenchmarkNewServer(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		e, err := NewServer()
		if err != nil {
			b.Fatal(err)
		}
		if err := e.Shutdown(); err != nil {
			b.Fatal(err)
		}
	}
}

// ---------------------------------------------------------------------------
// Category 2: Warm Server Operations (server created once)
// ---------------------------------------------------------------------------

// BenchmarkServerCommand_Version measures a warm-server version query.
func BenchmarkServerCommand_Version(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_ReadTags reads specific tags from a small JPEG.
func BenchmarkServerCommand_ReadTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-Artist", "-Copyright", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_AllTags dumps all tags from a small JPEG.
func BenchmarkServerCommand_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_JSON dumps all tags as JSON from a small JPEG.
func BenchmarkServerCommand_JSON(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_MultipleFiles reads tags from two files in one call.
func BenchmarkServerCommand_MultipleFiles(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-FileName", "-Artist", "testdata/sample.jpg", "testdata/sample_gps.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// ---------------------------------------------------------------------------
// Category 3: Single-shot File Reading (full lifecycle inside b.N loop)
// ---------------------------------------------------------------------------

// BenchmarkCommand_ReadTags reads specific tags via single-shot Command.
func BenchmarkCommand_ReadTags(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-Artist", "-Copyright", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkCommand_AllTags dumps all tags via single-shot Command.
func BenchmarkCommand_AllTags(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkCommand_JSON dumps all tags as JSON via single-shot Command.
func BenchmarkCommand_JSON(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-json", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkRun_ReadTags reads specific tags via Run with workFS.
func BenchmarkRun_ReadTags(b *testing.B) {
	ctx := context.Background()
	workFS := os.DirFS("testdata")
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Run(ctx, workFS, "-Artist", "-Copyright", "/work/test.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkRun_AllTags dumps all tags via Run with workFS.
func BenchmarkRun_AllTags(b *testing.B) {
	ctx := context.Background()
	workFS := os.DirFS("testdata")
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Run(ctx, workFS, "/work/test.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkRun_JSON dumps all tags as JSON via Run with workFS.
func BenchmarkRun_JSON(b *testing.B) {
	ctx := context.Background()
	workFS := os.DirFS("testdata")
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Run(ctx, workFS, "-json", "/work/test.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// ---------------------------------------------------------------------------
// Category 4: stdin Image Streaming
// ---------------------------------------------------------------------------

// BenchmarkCommand_StdinImage pipes image bytes via stdin for JSON extraction.
func BenchmarkCommand_StdinImage(b *testing.B) {
	imgBytes, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(bytes.NewReader(imgBytes), "-json", "-"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkCommand_StdinImage_Tags pipes image bytes via stdin for specific tags.
func BenchmarkCommand_StdinImage_Tags(b *testing.B) {
	imgBytes, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(bytes.NewReader(imgBytes), "-Artist", "-Copyright", "-"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServer_TempFileImage measures the temp-file workaround for
// in-memory images with a persistent server.
func BenchmarkServer_TempFileImage(b *testing.B) {
	imgBytes, err := os.ReadFile("testdata/sample.jpg")
	if err != nil {
		b.Fatal(err)
	}

	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tmp, err := os.CreateTemp("", "bench-*.jpg")
		if err != nil {
			b.Fatal(err)
		}
		if _, err := tmp.Write(imgBytes); err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
			b.Fatal(err)
		}
		tmp.Close()

		if _, err := e.Command("-json", tmp.Name()); err != nil {
			os.Remove(tmp.Name())
			b.Fatal(err)
		}
		os.Remove(tmp.Name())
	}
}

// ---------------------------------------------------------------------------
// Category 5: Throughput Comparison
// ---------------------------------------------------------------------------

// BenchmarkCommand_SequentialVersion runs N cold-start version queries.
func BenchmarkCommand_SequentialVersion(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServer_SequentialVersion runs N warm-server version queries.
func BenchmarkServer_SequentialVersion(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-ver"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkCommand_SequentialRead runs N cold-start tag reads.
func BenchmarkCommand_SequentialRead(b *testing.B) {
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Command(nil, "-Artist", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServer_SequentialRead runs N warm-server tag reads.
func BenchmarkServer_SequentialRead(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-Artist", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// ---------------------------------------------------------------------------
// Category 6: File Size / Type Variation (warm server, -json)
// ---------------------------------------------------------------------------

// BenchmarkServerCommand_SmallJPG reads a 203B JPEG via warm server.
func BenchmarkServerCommand_SmallJPG(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/base.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_MediumJPG reads a 3.5KB JPEG via warm server.
func BenchmarkServerCommand_MediumJPG(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_LargeJPG reads a 133KB JPEG via warm server.
func BenchmarkServerCommand_LargeJPG(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/test.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_PNG reads a 284B PNG via warm server.
func BenchmarkServerCommand_PNG(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/sample.png"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_TIFF reads a 60KB TIFF via warm server.
func BenchmarkServerCommand_TIFF(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("-json", "testdata/sample.tiff"); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkServerCommand_MediumJPG_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/sample.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_LargeJPG_AllTags reads all tags from a 133KB JPEG via warm server.
func BenchmarkServerCommand_LargeJPG_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/test.jpg"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_PNG_AllTags reads all tags from a 284B PNG via warm server.
func BenchmarkServerCommand_PNG_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/sample.png"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServerCommand_TIFF_AllTags reads all tags from a 60KB TIFF via warm server.
func BenchmarkServerCommand_TIFF_AllTags(b *testing.B) {
	e, err := NewServer()
	if err != nil {
		b.Fatal(err)
	}
	defer e.Shutdown()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := e.Command("testdata/sample.tiff"); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkServer_ParallelMixedRead simulates the bulk-ingest pattern: one
// persistent server per worker goroutine, mixed image types, and a single
// channel-driven writer that consumes results.
func BenchmarkServer_ParallelMixedRead(b *testing.B) {
	type job struct {
		args []string
	}
	type result struct {
		idx int
		out []byte
	}

	jobs := []job{
		{args: []string{"-json", "testdata/base.jpg"}},
		{args: []string{"-json", "testdata/sample.jpg"}},
		{args: []string{"-json", "testdata/sample_gps.jpg"}},
		{args: []string{"-json", "testdata/sample.png"}},
		{args: []string{"-json", "testdata/sample.tiff"}},
		{args: []string{"-json", "testdata/test.jpg"}},
		{args: []string{"testdata/sample.jpg"}},
		{args: []string{"testdata/sample_gps.jpg"}},
	}

	workers := max(runtime.GOMAXPROCS(0)-2, 1)
	servers := make([]*Server, 0, workers)
	for i := 0; i < workers; i++ {
		e, err := NewServer()
		if err != nil {
			for _, srv := range servers {
				_ = srv.Shutdown()
			}
			b.Fatal(err)
		}
		servers = append(servers, e)
	}
	defer func() {
		for _, srv := range servers {
			_ = srv.Shutdown()
		}
	}()

	results := make(chan result, workers*2)
	errCh := make(chan error, workers)
	done := make(chan struct{})

	var sinkWG sync.WaitGroup
	sinkWG.Add(1)
	go func() {
		defer sinkWG.Done()
		h := fnv.New64a()
		var count uint64
		for res := range results {
			_, _ = h.Write([]byte{byte(res.idx)})
			_, _ = h.Write(res.out)
			count++
		}
		benchmarkParallelServerSink.sum = h.Sum64()
		benchmarkParallelServerSink.count = count
		close(done)
	}()

	var next uint64
	var workerWG sync.WaitGroup
	workerWG.Add(workers)

	b.ResetTimer()
	for workerID := 0; workerID < workers; workerID++ {
		srv := servers[workerID]
		go func() {
			defer workerWG.Done()
			for {
				i := int(atomic.AddUint64(&next, 1) - 1)
				if i >= b.N {
					return
				}
				job := jobs[i%len(jobs)]
				out, err := srv.Command(job.args...)
				if err != nil {
					select {
					case errCh <- err:
					default:
					}
					return
				}
				results <- result{idx: i % len(jobs), out: out}
			}
		}()
	}

	workerWG.Wait()
	close(results)
	sinkWG.Wait()
	b.StopTimer()

	select {
	case err := <-errCh:
		b.Fatal(err)
	default:
	}
	<-done
}
