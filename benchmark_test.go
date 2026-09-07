package simslim

import "testing"

func TestSumBenchmark(t *testing.T) {
	tests := []struct {
		name      string
		results   []BenchmarkResult
		wantStock int64
		wantSlim  int64
	}{
		{name: "empty"},
		{
			name: "single device",
			results: []BenchmarkResult{
				{StockMemory: Measurement{Bytes: 4000}, SlimMemory: Measurement{Bytes: 1000}},
			},
			wantStock: 4000,
			wantSlim:  1000,
		},
		{
			name: "sums across devices",
			results: []BenchmarkResult{
				{StockMemory: Measurement{Bytes: 4000}, SlimMemory: Measurement{Bytes: 1000}},
				{StockMemory: Measurement{Bytes: 2000}, SlimMemory: Measurement{Bytes: 500}},
			},
			wantStock: 6000,
			wantSlim:  1500,
		},
		{
			name: "errored device excluded from totals",
			results: []BenchmarkResult{
				{StockMemory: Measurement{Bytes: 4000}, SlimMemory: Measurement{Bytes: 1000}},
				{StockMemory: Measurement{Bytes: 9999}, SlimMemory: Measurement{Bytes: 9999}, Error: "boot timed out"},
			},
			wantStock: 4000,
			wantSlim:  1000,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotStock, gotSlim := sumBenchmark(tt.results)
			if gotStock != tt.wantStock || gotSlim != tt.wantSlim {
				t.Errorf("sumBenchmark() = (%d, %d), want (%d, %d)", gotStock, gotSlim, tt.wantStock, tt.wantSlim)
			}
		})
	}
}

func TestFullSlimProfileDisablesEverything(t *testing.T) {
	desired := fullSlimProfile().Desired()
	managed := SlimmableSet()
	if len(desired) != len(managed) {
		t.Fatalf("fullSlimProfile().Desired() has %d labels, want %d (the full managed set)", len(desired), len(managed))
	}
	for l := range managed {
		if !desired[l] {
			t.Errorf("fullSlimProfile().Desired() missing label %q", l)
		}
	}
}
