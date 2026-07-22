package main

import (
	"testing"
)

func TestTruncatePreservesUnicode(t *testing.T) {
	if got, want := truncate("模拟器名称", 4), "模拟器…"; got != want {
		t.Fatalf("truncate() = %q, want %q", got, want)
	}
	if got, want := truncate("short", 10), "short"; got != want {
		t.Fatalf("truncate() = %q, want %q", got, want)
	}
}

func TestHumanBytesIncludesKilobytes(t *testing.T) {
	if got, want := humanBytes(8<<10), "8 KB"; got != want {
		t.Fatalf("humanBytes() = %q, want %q", got, want)
	}
}
