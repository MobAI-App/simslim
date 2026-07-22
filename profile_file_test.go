package simslim

import (
	"os"
	"path/filepath"
	"reflect"
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
	p, err := LoadSlimProfile(path)
	if err != nil {
		t.Fatalf("LoadSlimProfile() error = %v", err)
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
	p, err := LoadSlimProfile(writeProfile(t, `{}`))
	if err != nil {
		t.Fatalf("LoadSlimProfile() error = %v", err)
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
			if _, err := LoadSlimProfile(writeProfile(t, tt.contents)); err == nil {
				t.Errorf("LoadSlimProfile(%q) error = nil, want error", tt.contents)
			}
		})
	}
}

func TestLoadSlimProfileMissingFile(t *testing.T) {
	if _, err := LoadSlimProfile(filepath.Join(t.TempDir(), "absent.json")); err == nil {
		t.Error("LoadSlimProfile(absent) error = nil, want error")
	}
}

func TestBuildProfile(t *testing.T) {
	t.Run("flags build the profile", func(t *testing.T) {
		p, err := BuildProfile("", "search", "com.apple.apsd")
		if err != nil {
			t.Fatalf("BuildProfile() error = %v", err)
		}
		if !p.ExceptCategories["search"] || !p.Keep["com.apple.apsd"] {
			t.Errorf("buildProfile flags = %v / %v", p.ExceptCategories, p.Keep)
		}
	})
	t.Run("unknown category flag errors", func(t *testing.T) {
		if _, err := BuildProfile("", "nope", ""); err == nil {
			t.Error("BuildProfile(unknown category) error = nil, want error")
		}
	})
	t.Run("profile file resolves", func(t *testing.T) {
		path := writeProfile(t, `{"except": ["search"]}`)
		p, err := BuildProfile(path, "", "")
		if err != nil {
			t.Fatalf("BuildProfile(file) error = %v", err)
		}
		if !p.ExceptCategories["search"] {
			t.Errorf("BuildProfile(file) except = %v", p.ExceptCategories)
		}
	})
	t.Run("profile with except flag errors", func(t *testing.T) {
		if _, err := BuildProfile("some.json", "search", ""); err == nil {
			t.Error("BuildProfile(profile+except) error = nil, want error")
		}
	})
	t.Run("profile with keep flag errors", func(t *testing.T) {
		if _, err := BuildProfile("some.json", "", "com.apple.apsd"); err == nil {
			t.Error("BuildProfile(profile+keep) error = nil, want error")
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
		if got := ProfileFileName(tt.name); got != tt.want {
			t.Errorf("ProfileFileName(%q) = %q, want %q", tt.name, got, tt.want)
		}
	}
}
