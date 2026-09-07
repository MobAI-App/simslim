package simslim

import (
	"reflect"
	"testing"
)

func TestComputeStats(t *testing.T) {
	tests := []struct {
		name    string
		samples []int64
		want    MemoryStats
	}{
		{name: "empty", samples: nil, want: MemoryStats{}},
		{
			name:    "single sample",
			samples: []int64{1000},
			want:    MemoryStats{Samples: []int64{1000}, MinBytes: 1000, MeanBytes: 1000, MaxBytes: 1000},
		},
		{
			name:    "spread across several samples",
			samples: []int64{1000, 3000, 2000},
			want:    MemoryStats{Samples: []int64{1000, 3000, 2000}, MinBytes: 1000, MeanBytes: 2000, MaxBytes: 3000},
		},
		{
			name:    "mean rounds down via integer division",
			samples: []int64{1000, 1000, 1001},
			want:    MemoryStats{Samples: []int64{1000, 1000, 1001}, MinBytes: 1000, MeanBytes: 1000, MaxBytes: 1001},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := computeStats(tt.samples); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("computeStats(%v) = %+v, want %+v", tt.samples, got, tt.want)
			}
		})
	}
}

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
				{Stock: MemoryStats{MeanBytes: 4000}, Slim: MemoryStats{MeanBytes: 1000}},
			},
			wantStock: 4000,
			wantSlim:  1000,
		},
		{
			name: "sums across devices",
			results: []BenchmarkResult{
				{Stock: MemoryStats{MeanBytes: 4000}, Slim: MemoryStats{MeanBytes: 1000}},
				{Stock: MemoryStats{MeanBytes: 2000}, Slim: MemoryStats{MeanBytes: 500}},
			},
			wantStock: 6000,
			wantSlim:  1500,
		},
		{
			name: "errored device excluded from totals",
			results: []BenchmarkResult{
				{Stock: MemoryStats{MeanBytes: 4000}, Slim: MemoryStats{MeanBytes: 1000}},
				{Stock: MemoryStats{MeanBytes: 9999}, Slim: MemoryStats{MeanBytes: 9999}, Error: "boot timed out"},
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
