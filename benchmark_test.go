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
				{Stock: MemoryStats{Samples: []int64{4000}, MeanBytes: 4000}, Slim: MemoryStats{Samples: []int64{1000}, MeanBytes: 1000}},
			},
			wantStock: 4000,
			wantSlim:  1000,
		},
		{
			name: "sums across devices",
			results: []BenchmarkResult{
				{Stock: MemoryStats{Samples: []int64{4000}, MeanBytes: 4000}, Slim: MemoryStats{Samples: []int64{1000}, MeanBytes: 1000}},
				{Stock: MemoryStats{Samples: []int64{2000}, MeanBytes: 2000}, Slim: MemoryStats{Samples: []int64{500}, MeanBytes: 500}},
			},
			wantStock: 6000,
			wantSlim:  1500,
		},
		{
			name: "device with no completed runs excluded from totals",
			results: []BenchmarkResult{
				{Stock: MemoryStats{Samples: []int64{4000}, MeanBytes: 4000}, Slim: MemoryStats{Samples: []int64{1000}, MeanBytes: 1000}},
				{Error: "boot timed out"},
			},
			wantStock: 4000,
			wantSlim:  1000,
		},
		{
			name: "device that errored after completing some runs still counted",
			results: []BenchmarkResult{
				{Stock: MemoryStats{Samples: []int64{4000}, MeanBytes: 4000}, Slim: MemoryStats{Samples: []int64{1000}, MeanBytes: 1000}},
				{Stock: MemoryStats{Samples: []int64{2000, 2200}, MeanBytes: 2100}, Slim: MemoryStats{Samples: []int64{500, 520}, MeanBytes: 510}, Error: "boot timed out on run 3"},
			},
			wantStock: 6100,
			wantSlim:  1510,
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
