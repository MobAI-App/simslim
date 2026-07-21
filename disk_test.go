package main

import "testing"

func TestParseDUDiskUsage(t *testing.T) {
	got, err := parseDUDiskUsage([]byte("4747728\t/simulator/path\n"))
	if err != nil {
		t.Fatalf("parseDUDiskUsage() error = %v", err)
	}
	if got != 4_861_673_472 {
		t.Errorf("parseDUDiskUsage() = %d, want 4861673472", got)
	}

	for _, invalid := range []string{"", "nope /simulator/path", "-1 /simulator/path"} {
		if _, err := parseDUDiskUsage([]byte(invalid)); err == nil {
			t.Errorf("parseDUDiskUsage(%q) unexpectedly succeeded", invalid)
		}
	}
}
