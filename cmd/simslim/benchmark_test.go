package main

import (
	"testing"

	"github.com/mobai-app/simslim"
)

func TestBenchmarkRatio(t *testing.T) {
	tests := []struct {
		name       string
		stockBytes int64
		slimBytes  int64
		want       string
	}{
		{name: "typical reduction", stockBytes: 4000, slimBytes: 1000, want: "4.00x"},
		{name: "no reduction", stockBytes: 1000, slimBytes: 1000, want: "1.00x"},
		{name: "zero slim bytes has nothing to divide by", stockBytes: 1000, slimBytes: 0, want: "—"},
		{name: "negative slim bytes (defensive) also blank", stockBytes: 1000, slimBytes: -1, want: "—"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := benchmarkRatio(tt.stockBytes, tt.slimBytes); got != tt.want {
				t.Errorf("benchmarkRatio(%d, %d) = %q, want %q", tt.stockBytes, tt.slimBytes, got, tt.want)
			}
		})
	}
}

func TestFormatStats(t *testing.T) {
	tests := []struct {
		name  string
		stats simslim.MemoryStats
		runs  int
		want  string
	}{
		{
			name:  "single run omits range",
			stats: simslim.MemoryStats{Samples: []int64{1 << 20}, MeanBytes: 1 << 20, MinBytes: 1 << 20, MaxBytes: 1 << 20},
			runs:  1,
			want:  "1 MB",
		},
		{
			name:  "multiple runs show min-max range",
			stats: simslim.MemoryStats{Samples: []int64{1 << 20, 2 << 20, 3 << 20}, MeanBytes: 2 << 20, MinBytes: 1 << 20, MaxBytes: 3 << 20},
			runs:  3,
			want:  "2 MB (1 MB-3 MB)",
		},
		{
			name:  "runs requested but only one sample completed",
			stats: simslim.MemoryStats{Samples: []int64{1 << 20}, MeanBytes: 1 << 20, MinBytes: 1 << 20, MaxBytes: 1 << 20},
			runs:  3,
			want:  "1 MB",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := formatStats(tt.stats, tt.runs); got != tt.want {
				t.Errorf("formatStats(%+v, %d) = %q, want %q", tt.stats, tt.runs, got, tt.want)
			}
		})
	}
}

func TestCmdBenchmarkRequiresUDIDs(t *testing.T) {
	if err := runApp(t, "benchmark"); err == nil {
		t.Fatal("benchmark with no UDIDs: want error, got nil")
	}
}

func TestCmdBenchmarkRejectsNonPositiveRuns(t *testing.T) {
	if err := runApp(t, "benchmark", "--runs", "0", "some-udid"); err == nil {
		t.Fatal("benchmark --runs 0: want error, got nil")
	}
}
