package simslim

import "testing"

func TestMeasureTree(t *testing.T) {
	snap := psSnapshot{
		children: map[int][]int{
			10: {11, 12},
			11: {13},
			13: {10}, // A cycle must not double-count the root.
		},
		cpu: map[int]float64{10: 1.5, 11: 0.5, 12: 2, 13: 0},
	}
	footprint := map[int]int64{10: 100, 11: 20, 12: 30, 13: 4}

	got := measureTree(10, snap, footprint)
	if got.Processes != 4 {
		t.Errorf("Processes = %d, want 4", got.Processes)
	}
	if got.Bytes != 154 {
		t.Errorf("Bytes = %d, want 154", got.Bytes)
	}
	if got.CPU != 4 {
		t.Errorf("CPU = %v, want 4", got.CPU)
	}
}

func TestParsePS(t *testing.T) {
	out := "  PID  PPID %CPU COMM\n" +
		"   10     1  1.5 launchd_sim\n" +
		"   11    10 12.0 /usr/libexec/assistantd\n" +
		"   12    10  0.0 /System/Library/CoreServices/SpringBoard.app/SpringBoard\n" +
		"  bad line that should be skipped\n"

	snap := parsePS(out)
	if got := snap.children[10]; len(got) != 2 {
		t.Fatalf("children[10] = %v, want 2 entries", got)
	}
	if snap.comm[11] != "assistantd" { // basenamed from the full path
		t.Errorf("comm[11] = %q, want assistantd", snap.comm[11])
	}
	if snap.comm[12] != "SpringBoard" {
		t.Errorf("comm[12] = %q, want SpringBoard", snap.comm[12])
	}
	if snap.cpu[11] != 12 {
		t.Errorf("cpu[11] = %v, want 12", snap.cpu[11])
	}
	if _, ok := snap.comm[1]; ok {
		t.Errorf("header row was parsed as a process")
	}
}
