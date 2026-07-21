package main

import "testing"

func TestMeasureTree(t *testing.T) {
	children := map[int][]int{
		10: {11, 12},
		11: {13},
		13: {10}, // A cycle must not double-count the root.
	}
	footprint := map[int]int64{10: 100, 11: 20, 12: 30, 13: 4}

	got := measureTree(10, children, footprint)
	if got.Processes != 4 {
		t.Errorf("Processes = %d, want 4", got.Processes)
	}
	if got.Bytes != 154 {
		t.Errorf("Bytes = %d, want 154", got.Bytes)
	}
}
