package main

import (
	"strings"
	"testing"
)

func TestNormalizeSimulatorName(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		want      string
		wantError bool
	}{
		{name: "ordinary", input: "QA iPhone", want: "QA iPhone"},
		{name: "trims whitespace", input: "  QA iPhone  ", want: "QA iPhone"},
		{name: "unicode", input: "Démo 📱", want: "Démo 📱"},
		{name: "empty", input: "   ", wantError: true},
		{name: "embedded control", input: "QA\nPhone", wantError: true},
		{name: "too long", input: strings.Repeat("a", 129), wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := normalizeSimulatorName(tt.input)
			if (err != nil) != tt.wantError {
				t.Fatalf("normalizeSimulatorName() error = %v, wantError %v", err, tt.wantError)
			}
			if got != tt.want {
				t.Errorf("normalizeSimulatorName() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestParseClonedUDID(t *testing.T) {
	const udid = "00000000-0000-0000-0000-000000000001"
	got, err := parseClonedUDID([]byte("\n" + udid + "\n"))
	if err != nil {
		t.Fatalf("parseClonedUDID() error = %v", err)
	}
	if got != udid {
		t.Errorf("parseClonedUDID() = %q, want %q", got, udid)
	}

	for _, invalid := range []string{"", "not-a-udid", "00000000-0000-0000-0000-00000000000Z"} {
		if _, err := parseClonedUDID([]byte(invalid)); err == nil {
			t.Errorf("parseClonedUDID(%q) unexpectedly succeeded", invalid)
		}
	}
}
