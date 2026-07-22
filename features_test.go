package main

import (
	"reflect"
	"testing"
)

func TestFeatureLabelsAreSlimmable(t *testing.T) {
	slimmable := slimmableSet()
	for _, f := range Features {
		if len(f.Labels) == 0 {
			t.Errorf("feature %q has no labels", f.ID)
		}
		for _, l := range f.Labels {
			if !slimmable[l] {
				t.Errorf("feature %q names %q, which no category disables", f.ID, l)
			}
		}
	}
}

func TestFeatureIDsAreUniqueAndNamed(t *testing.T) {
	seen := map[string]bool{}
	for _, f := range Features {
		if f.ID == "" {
			t.Error("a feature has an empty ID")
		}
		if f.Name == "" {
			t.Errorf("feature %q has no name", f.ID)
		}
		if seen[f.ID] {
			t.Errorf("duplicate feature ID %q", f.ID)
		}
		seen[f.ID] = true
	}
}

func TestResolveFeatures(t *testing.T) {
	got, err := resolveFeatures([]string{"push", "storekit"})
	if err != nil {
		t.Fatalf("resolveFeatures() error = %v", err)
	}
	if len(got) != 2 || got[0].ID != "push" || got[1].ID != "storekit" {
		t.Errorf("resolveFeatures = %v, want [push storekit]", got)
	}
	if _, err := resolveFeatures([]string{"push", "nope"}); err == nil {
		t.Error("resolveFeatures(unknown) error = nil, want error")
	}
}

func TestDiagnoseFeatures(t *testing.T) {
	features, err := resolveFeatures([]string{"push", "storekit", "universal-links"})
	if err != nil {
		t.Fatalf("resolveFeatures() error = %v", err)
	}

	t.Run("all healthy on a stock device", func(t *testing.T) {
		report := diagnoseFeatures(features, map[string]bool{})
		if !report.OK {
			t.Errorf("OK = false, want true for %v", report.Features)
		}
	})

	t.Run("a disabled daemon breaks its feature", func(t *testing.T) {
		disabled := map[string]bool{"com.apple.storekitd": true}
		report := diagnoseFeatures(features, disabled)
		if report.OK {
			t.Error("OK = true, want false when storekitd is disabled")
		}
		byID := map[string]FeatureStatus{}
		for _, f := range report.Features {
			byID[f.ID] = f
		}
		if byID["storekit"].OK {
			t.Error("storekit reported OK despite storekitd disabled")
		}
		if !reflect.DeepEqual(byID["storekit"].Disabled, []string{"com.apple.storekitd"}) {
			t.Errorf("storekit.Disabled = %v, want [com.apple.storekitd]", byID["storekit"].Disabled)
		}
		if !byID["push"].OK || !byID["universal-links"].OK {
			t.Error("unrelated features should stay OK")
		}
	})

	t.Run("any disabled backing daemon breaks a multi-daemon feature", func(t *testing.T) {
		spotlight, _ := resolveFeatures([]string{"spotlight"})
		report := diagnoseFeatures(spotlight, map[string]bool{"com.apple.searchtoold": true})
		if report.OK {
			t.Error("spotlight reported OK with searchtoold disabled")
		}
	})
}
