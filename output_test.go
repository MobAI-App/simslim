package main

import (
	"flag"
	"io"
	"reflect"
	"testing"
)

func TestJSONOption(t *testing.T) {
	tests := []struct {
		name      string
		args      []string
		wantJSON  bool
		wantArgs  []string
		wantError bool
	}{
		{name: "absent", args: []string{"abc"}, wantArgs: []string{"abc"}},
		{name: "before udid", args: []string{"--json", "abc"}, wantJSON: true, wantArgs: []string{"abc"}},
		{name: "after udid", args: []string{"abc", "--json"}, wantJSON: true, wantArgs: []string{"abc"}},
		{name: "duplicate", args: []string{"--json", "--json"}, wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotJSON, gotArgs, err := jsonOption(tt.args)
			if (err != nil) != tt.wantError {
				t.Fatalf("jsonOption() error = %v, wantError %v", err, tt.wantError)
			}
			if gotJSON != tt.wantJSON {
				t.Errorf("jsonOption() json = %v, want %v", gotJSON, tt.wantJSON)
			}
			if len(gotArgs) != len(tt.wantArgs) {
				t.Fatalf("jsonOption() args = %v, want %v", gotArgs, tt.wantArgs)
			}
			for i := range gotArgs {
				if gotArgs[i] != tt.wantArgs[i] {
					t.Errorf("jsonOption() args = %v, want %v", gotArgs, tt.wantArgs)
				}
			}
		})
	}
}

func TestParseInterspersedFlags(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	categories := fs.String("categories", "", "")
	confirmed := fs.Bool("confirm", false, "")
	preserveBootState := fs.Bool("preserve-boot-state", false, "")

	args := []string{
		"TEST-UDID",
		"--confirm",
		"--categories", "caches,logs",
		"--preserve-boot-state=true",
	}
	if err := parseInterspersedFlags(fs, args); err != nil {
		t.Fatalf("parseInterspersedFlags() error = %v", err)
	}
	if got, want := fs.Args(), []string{"TEST-UDID"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("positionals = %v, want %v", got, want)
	}
	if *categories != "caches,logs" || !*confirmed || !*preserveBootState {
		t.Fatalf(
			"flags = categories %q, confirm %v, preserve %v",
			*categories, *confirmed, *preserveBootState,
		)
	}
}

func TestParseInterspersedFlagsHonorsSeparator(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	confirmed := fs.Bool("confirm", false, "")

	if err := parseInterspersedFlags(fs, []string{"--confirm", "device", "--", "--literal"}); err != nil {
		t.Fatalf("parseInterspersedFlags() error = %v", err)
	}
	if !*confirmed {
		t.Fatal("confirm flag was not parsed")
	}
	if got, want := fs.Args(), []string{"device", "--literal"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("positionals = %v, want %v", got, want)
	}
}

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
