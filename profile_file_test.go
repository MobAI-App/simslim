package main

import (
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// writeProfile writes contents to a temp file and returns its path.
func writeProfile(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "profile.json")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("write profile: %v", err)
	}
	return path
}

func TestLoadSlimProfile(t *testing.T) {
	path := writeProfile(t, `{
		"name": "ci",
		"description": "UI test runs",
		"except": ["search", "store"],
		"keep": ["com.apple.apsd"]
	}`)
	p, err := loadSlimProfile(path)
	if err != nil {
		t.Fatalf("loadSlimProfile() error = %v", err)
	}
	wantExcept := map[string]bool{"search": true, "store": true}
	if !reflect.DeepEqual(p.ExceptCategories, wantExcept) {
		t.Errorf("ExceptCategories = %v, want %v", p.ExceptCategories, wantExcept)
	}
	wantKeep := map[string]bool{"com.apple.apsd": true}
	if !reflect.DeepEqual(p.Keep, wantKeep) {
		t.Errorf("Keep = %v, want %v", p.Keep, wantKeep)
	}
}

func TestLoadSlimProfileMinimal(t *testing.T) {
	// name/description are optional and empty arrays yield an empty selection.
	p, err := loadSlimProfile(writeProfile(t, `{}`))
	if err != nil {
		t.Fatalf("loadSlimProfile() error = %v", err)
	}
	if len(p.ExceptCategories) != 0 || len(p.Keep) != 0 {
		t.Errorf("empty profile selected %v / %v, want empty", p.ExceptCategories, p.Keep)
	}
}

func TestLoadSlimProfileRejects(t *testing.T) {
	tests := []struct {
		name     string
		contents string
	}{
		{name: "unknown category", contents: `{"except": ["nope"]}`},
		{name: "unknown keep label", contents: `{"keep": ["com.apple.does-not-exist"]}`},
		{name: "unknown field", contents: `{"disable": ["search"]}`},
		{name: "malformed json", contents: `{"except": [`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := loadSlimProfile(writeProfile(t, tt.contents)); err == nil {
				t.Errorf("loadSlimProfile(%q) error = nil, want error", tt.contents)
			}
		})
	}
}

func TestLoadSlimProfileMissingFile(t *testing.T) {
	if _, err := loadSlimProfile(filepath.Join(t.TempDir(), "absent.json")); err == nil {
		t.Error("loadSlimProfile(absent) error = nil, want error")
	}
}

func TestBuildProfile(t *testing.T) {
	t.Run("flags build the profile", func(t *testing.T) {
		p, err := buildProfile("", "search", "com.apple.apsd")
		if err != nil {
			t.Fatalf("buildProfile() error = %v", err)
		}
		if !p.ExceptCategories["search"] || !p.Keep["com.apple.apsd"] {
			t.Errorf("buildProfile flags = %v / %v", p.ExceptCategories, p.Keep)
		}
	})
	t.Run("unknown category flag errors", func(t *testing.T) {
		if _, err := buildProfile("", "nope", ""); err == nil {
			t.Error("buildProfile(unknown category) error = nil, want error")
		}
	})
	t.Run("profile file resolves", func(t *testing.T) {
		path := writeProfile(t, `{"except": ["search"]}`)
		p, err := buildProfile(path, "", "")
		if err != nil {
			t.Fatalf("buildProfile(file) error = %v", err)
		}
		if !p.ExceptCategories["search"] {
			t.Errorf("buildProfile(file) except = %v", p.ExceptCategories)
		}
	})
	t.Run("profile with except flag errors", func(t *testing.T) {
		if _, err := buildProfile("some.json", "search", ""); err == nil {
			t.Error("buildProfile(profile+except) error = nil, want error")
		}
	})
	t.Run("profile with keep flag errors", func(t *testing.T) {
		if _, err := buildProfile("some.json", "", "com.apple.apsd"); err == nil {
			t.Error("buildProfile(profile+keep) error = nil, want error")
		}
	})
}

func TestProfileFileName(t *testing.T) {
	tests := []struct {
		name string
		want string
	}{
		{name: "ci", want: "ci.json"},
		{name: "UI Test Runs", want: "ui-test-runs.json"},
		{name: "", want: "profile.json"},
		{name: "  ", want: "profile.json"},
		{name: "prod.json", want: "prod.json"},
		{name: "a/b:c", want: "a-b-c.json"},
		{name: "--weird--", want: "weird.json"},
	}
	for _, tt := range tests {
		if got := profileFileName(tt.name); got != tt.want {
			t.Errorf("profileFileName(%q) = %q, want %q", tt.name, got, tt.want)
		}
	}
}

// noRawMode is the enterRaw hook for tests: it skips terminal manipulation and
// hands back a no-op restore plus a fixed height, so the wizard reads scripted
// keystrokes from a plain reader.
func noRawMode() (func(), int, error) { return func() {}, 24, nil }

// Keystroke sequences the wizard consumes after the two (name, description)
// lines. Categories are ordered widgets, siri, search, ... so one arrowDown
// lands on siri, two on search.
const (
	arrowDown  = "\x1b[B"
	arrowUp    = "\x1b[A"
	arrowRight = "\x1b[C"
	arrowLeft  = "\x1b[D"
	space      = " "
	enter      = "\r"
)

func TestRunProfileWizard(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		wantName   string
		wantDesc   string
		wantExcept []string
		wantKeep   []string
	}{
		{
			name:       "space keeps whole features siri and search",
			input:      "ci\nUI test runs\n" + arrowDown + space + arrowDown + space + enter,
			wantName:   "ci",
			wantDesc:   "UI test runs",
			wantExcept: []string{"siri", "search"}, // catalog order, not visit order
		},
		{
			name:       "vim key navigates features",
			input:      "\n\n" + "j" + space + enter,
			wantExcept: []string{"siri"},
		},
		{
			name:       "toggle feature twice clears",
			input:      "\n\n" + space + space + enter,
			wantExcept: nil,
		},
		{
			name:       "all then none clears features",
			input:      "\n\n" + "an" + enter,
			wantExcept: nil,
		},
		{
			name:       "enter with nothing checked",
			input:      "\n\n" + enter,
			wantExcept: nil,
		},
		{
			name:       "unbound keys are ignored",
			input:      "\n\n" + "zZ" + space + enter,
			wantExcept: []string{"widgets"}, // z/Z do nothing; space keeps the cursor row
		},
		{
			name:       "arrow up clamps at the top",
			input:      "\n\n" + arrowUp + space + enter,
			wantExcept: []string{"widgets"},
		},
		{
			// Drill into siri (row 2), keep its first daemon, back out, save.
			name:     "drill in keeps an individual daemon",
			input:    "\n\n" + arrowDown + arrowRight + space + arrowLeft + enter,
			wantKeep: []string{"com.apple.assistantd"},
		},
		{
			// A kept daemon is dropped when its whole feature is also kept.
			name:       "feature kept prunes its daemon keeps",
			input:      "\n\n" + arrowDown + space + arrowRight + space + arrowLeft + enter,
			wantExcept: []string{"siri"},
			wantKeep:   nil,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sp, err := runProfileWizard(strings.NewReader(tt.input), io.Discard, noRawMode)
			if err != nil {
				t.Fatalf("runProfileWizard() error = %v", err)
			}
			if sp.Name != tt.wantName {
				t.Errorf("Name = %q, want %q", sp.Name, tt.wantName)
			}
			if sp.Description != tt.wantDesc {
				t.Errorf("Description = %q, want %q", sp.Description, tt.wantDesc)
			}
			if !reflect.DeepEqual(sp.Except, tt.wantExcept) {
				t.Errorf("Except = %v, want %v", sp.Except, tt.wantExcept)
			}
			if !reflect.DeepEqual(sp.Keep, tt.wantKeep) {
				t.Errorf("Keep = %v, want %v", sp.Keep, tt.wantKeep)
			}
		})
	}
}

// TestRunProfileWizardCancel confirms q reports cancellation.
func TestRunProfileWizardCancel(t *testing.T) {
	if _, err := runProfileWizard(strings.NewReader("\n\nq"), io.Discard, noRawMode); err != errWizardCancelled {
		t.Errorf("runProfileWizard(q) error = %v, want errWizardCancelled", err)
	}
}

// TestRunProfileWizardSelectAll confirms "a" checks every category so the
// resulting Except list covers the full catalog in order.
func TestRunProfileWizardSelectAll(t *testing.T) {
	sp, err := runProfileWizard(strings.NewReader("\n\na"+enter), io.Discard, noRawMode)
	if err != nil {
		t.Fatalf("runProfileWizard() error = %v", err)
	}
	if len(sp.Except) != len(Categories) {
		t.Fatalf("Except has %d entries, want %d", len(sp.Except), len(Categories))
	}
	for i, c := range Categories {
		if sp.Except[i] != c.ID {
			t.Errorf("Except[%d] = %q, want %q", i, sp.Except[i], c.ID)
		}
	}
}

// TestWizardOutputRoundTrips confirms a wizard result marshals to JSON that
// loads back into an equivalent Profile.
func TestWizardOutputRoundTrips(t *testing.T) {
	sp, err := runProfileWizard(strings.NewReader("ci\n\n"+arrowDown+space+arrowDown+space+enter), io.Discard, noRawMode)
	if err != nil {
		t.Fatalf("runProfileWizard() error = %v", err)
	}
	data, err := marshalProfile(sp)
	if err != nil {
		t.Fatalf("marshalProfile() error = %v", err)
	}
	path := writeProfile(t, string(data))
	p, err := loadSlimProfile(path)
	if err != nil {
		t.Fatalf("loadSlimProfile() error = %v", err)
	}
	want := map[string]bool{"siri": true, "search": true}
	if !reflect.DeepEqual(p.ExceptCategories, want) {
		t.Errorf("round-tripped ExceptCategories = %v, want %v", p.ExceptCategories, want)
	}
}
