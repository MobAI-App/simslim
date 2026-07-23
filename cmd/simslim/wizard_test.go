package main

import (
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/mobai-app/simslim"
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
	if len(sp.Except) != len(simslim.Categories) {
		t.Fatalf("Except has %d entries, want %d", len(sp.Except), len(simslim.Categories))
	}
	for i, c := range simslim.Categories {
		if sp.Except[i] != c.ID {
			t.Errorf("Except[%d] = %q, want %q", i, sp.Except[i], c.ID)
		}
	}
}

// TestWizardOutputRoundTrips confirms a wizard result marshals to JSON that
// loads back into an equivalent simslim.Profile.
func TestWizardOutputRoundTrips(t *testing.T) {
	sp, err := runProfileWizard(strings.NewReader("ci\n\n"+arrowDown+space+arrowDown+space+enter), io.Discard, noRawMode)
	if err != nil {
		t.Fatalf("runProfileWizard() error = %v", err)
	}
	data, err := simslim.MarshalProfile(sp)
	if err != nil {
		t.Fatalf("simslim.MarshalProfile() error = %v", err)
	}
	path := writeProfile(t, string(data))
	p, err := simslim.LoadSlimProfile(path)
	if err != nil {
		t.Fatalf("simslim.LoadSlimProfile() error = %v", err)
	}
	want := map[string]bool{"siri": true, "search": true}
	if !reflect.DeepEqual(p.ExceptCategories, want) {
		t.Errorf("round-tripped ExceptCategories = %v, want %v", p.ExceptCategories, want)
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
