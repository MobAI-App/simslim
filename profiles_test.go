package main

import (
	"reflect"
	"testing"
)

// forbiddenLabels deadlock or wedge a simulator when disabled and must never be
// managed. nanoregistryd wedges CoreSimulator so every simctl operation hangs;
// sleepd makes SpringBoard retry-storm itself to death; the rest were observed
// to break boot. They are deliberately absent from Categories.
var forbiddenLabels = []string{
	"com.apple.nanoregistryd",
	"com.apple.nanoregistrylaunchd",
	"com.apple.nanoprefsyncd.2",
	"com.apple.nanotimekitcompaniond",
	"com.apple.nanobackupd",
	"com.apple.sleepd",
	"com.apple.appprotectiond",
	"com.apple.ManagedSettingsAgent",
	"com.apple.managedconfiguration.profiled",
	"com.apple.mobiletimerd",
	"com.apple.routined",
	"com.apple.biomed",
	"com.apple.biomesyncd",
	"com.apple.dmd",
	"com.apple.donotdisturbd",
}

func TestManagedExcludesForbidden(t *testing.T) {
	managed := managedSet()
	for _, l := range forbiddenLabels {
		if managed[l] {
			t.Errorf("forbidden daemon %q is in a category; it must never be managed", l)
		}
	}
}

func TestNoDuplicateLabels(t *testing.T) {
	seen := map[string]string{}
	for _, c := range Categories {
		for _, l := range c.Labels {
			if prev, ok := seen[l]; ok {
				t.Errorf("label %q appears in both %q and %q", l, prev, c.ID)
			}
			seen[l] = c.ID
		}
	}
}

func TestCategoriesHaveUserImpactMetadata(t *testing.T) {
	for _, c := range Categories {
		if c.Downside == "" {
			t.Errorf("category %q has no downside description", c.ID)
		}
		if c.ApproxMemoryMB <= 0 {
			t.Errorf("category %q has invalid approximate memory %d MB", c.ID, c.ApproxMemoryMB)
		}
	}
}

func TestCategoryByID(t *testing.T) {
	for _, c := range Categories {
		got, ok := categoryByID(c.ID)
		if !ok {
			t.Errorf("categoryByID(%q) not found", c.ID)
			continue
		}
		if got.ID != c.ID {
			t.Errorf("categoryByID(%q) returned category %q", c.ID, got.ID)
		}
	}
	if _, ok := categoryByID("nope"); ok {
		t.Error("categoryByID(\"nope\") should not resolve an unknown ID")
	}
}

func TestDelta(t *testing.T) {
	managed := map[string]bool{"a": true, "b": true, "c": true}
	cases := []struct {
		name             string
		current, desired map[string]bool
		wantDisable      []string
		wantEnable       []string
	}{
		{
			name:        "enable all from stock",
			current:     map[string]bool{},
			desired:     map[string]bool{"a": true, "b": true, "c": true},
			wantDisable: []string{"a", "b", "c"},
		},
		{
			name:       "restore all to stock",
			current:    map[string]bool{"a": true, "b": true, "c": true},
			desired:    map[string]bool{},
			wantEnable: []string{"a", "b", "c"},
		},
		{
			name:    "already in desired state",
			current: map[string]bool{"a": true, "b": true},
			desired: map[string]bool{"a": true, "b": true},
		},
		{
			name:        "profile edit adds and removes",
			current:     map[string]bool{"a": true, "b": true},
			desired:     map[string]bool{"b": true, "c": true},
			wantDisable: []string{"c"},
			wantEnable:  []string{"a"},
		},
		{
			name:    "unmanaged desired label is ignored",
			current: map[string]bool{},
			desired: map[string]bool{"x": true},
		},
		{
			name:    "unmanaged disabled label is left alone",
			current: map[string]bool{"x": true},
			desired: map[string]bool{},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotDisable, gotEnable := delta(tc.current, tc.desired, managed)
			if !equalSlices(gotDisable, tc.wantDisable) {
				t.Errorf("toDisable = %v, want %v", gotDisable, tc.wantDisable)
			}
			if !equalSlices(gotEnable, tc.wantEnable) {
				t.Errorf("toEnable = %v, want %v", gotEnable, tc.wantEnable)
			}
		})
	}
}

func equalSlices(a, b []string) bool {
	if len(a) == 0 && len(b) == 0 {
		return true
	}
	return reflect.DeepEqual(a, b)
}
