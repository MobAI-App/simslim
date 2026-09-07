package main

import "testing"

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

func TestCmdBenchmarkRequiresUDIDs(t *testing.T) {
	if err := runApp(t, "benchmark"); err == nil {
		t.Fatal("benchmark with no UDIDs: want error, got nil")
	}
}
