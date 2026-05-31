package exiftool

import (
	"sync/atomic"
	"time"

	"github.com/lbe/cfsread"
)

// testMetrics implements cfsread.Metrics for cachefs unit and integration tests.
type testMetrics struct {
	hits     atomic.Int64
	misses   atomic.Int64
	bypasses atomic.Int64
}

func (m *testMetrics) IncCacheHit()                                          { m.hits.Add(1) }
func (m *testMetrics) IncCacheMiss()                                         { m.misses.Add(1) }
func (m *testMetrics) IncCacheBypass()                                       { m.bypasses.Add(1) }
func (m *testMetrics) IncEviction(cfsread.EvictionReason)                    {}
func (m *testMetrics) ObserveDecompress(string, int64, int64, time.Duration) {}
func (m *testMetrics) ObserveRead(time.Duration)                             {}
