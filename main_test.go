package main

import (
	"reflect"
	"testing"
)

func TestSimctlArgsForSet(t *testing.T) {
	t.Run("default set omits --set", func(t *testing.T) {
		got := simctlArgsForSet("", "boot", "UDID")
		want := []string{"simctl", "boot", "UDID"}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("simctlArgsForSet() = %v, want %v", got, want)
		}
	})
	t.Run("named set injects --set before the subcommand", func(t *testing.T) {
		got := simctlArgsForSet("testing", "boot", "UDID")
		want := []string{"simctl", "--set", "testing", "boot", "UDID"}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("simctlArgsForSet() = %v, want %v", got, want)
		}
	})
	t.Run("simctlArgs maps a set name to its --set token", func(t *testing.T) {
		got := simctlArgs("testing", "list", "devices", "-j")
		want := []string{"simctl", "--set", "testing", "list", "devices", "-j"}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("simctlArgs() = %v, want %v", got, want)
		}
		if got := simctlArgs("default", "list"); !reflect.DeepEqual(got, []string{"simctl", "list"}) {
			t.Errorf("simctlArgs(default) = %v, want no --set", got)
		}
	})
}

func TestDeviceSetToken(t *testing.T) {
	if got := deviceSetToken("default"); got != "" {
		t.Errorf("deviceSetToken(default) = %q, want empty", got)
	}
	if got := deviceSetToken("testing"); got != "testing" {
		t.Errorf("deviceSetToken(testing) = %q, want testing", got)
	}
	if deviceSetToken("unknown-set") != "" {
		t.Error("an unknown set name should fall back to the default token")
	}
}

func TestExtractDeviceSets(t *testing.T) {
	tests := []struct {
		name      string
		args      []string
		wantArgs  []string
		wantExtra []string // tokens registered beyond the well-known sets
		wantError bool
	}{
		{name: "absent", args: []string{"list"}, wantArgs: []string{"list"}},
		{name: "before command", args: []string{"--set", "/a", "list"}, wantArgs: []string{"list"}, wantExtra: []string{"/a"}},
		{name: "after positional", args: []string{"on", "UDID", "--set", "/a"}, wantArgs: []string{"on", "UDID"}, wantExtra: []string{"/a"}},
		{name: "equals form", args: []string{"list", "--set=/a"}, wantArgs: []string{"list"}, wantExtra: []string{"/a"}},
		{name: "repeat is last-wins", args: []string{"--set", "/a", "--set", "/b", "list"}, wantArgs: []string{"list"}, wantExtra: []string{"/b"}},
		{name: "comma-separated", args: []string{"--set", "/a,/b", "list"}, wantArgs: []string{"list"}, wantExtra: []string{"/a", "/b"}},
		{name: "comma trims blanks", args: []string{"--set=/a, ,/b", "list"}, wantArgs: []string{"list"}, wantExtra: []string{"/a", "/b"}},
		{name: "well-known not duplicated", args: []string{"--set", "testing", "list"}, wantArgs: []string{"list"}, wantExtra: nil},
		{name: "terminator protects literal", args: []string{"rename", "UDID", "--", "--set"}, wantArgs: []string{"rename", "UDID", "--", "--set"}, wantExtra: nil},
		{name: "missing value", args: []string{"list", "--set"}, wantError: true},
		{name: "empty value", args: []string{"--set", "  ", "list"}, wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			extraDeviceSets = nil
			defer func() { extraDeviceSets = nil }()
			gotArgs, err := extractDeviceSets(tt.args)
			if (err != nil) != tt.wantError {
				t.Fatalf("extractDeviceSets() error = %v, wantError %v", err, tt.wantError)
			}
			if tt.wantError {
				return
			}
			if !reflect.DeepEqual(gotArgs, tt.wantArgs) {
				t.Errorf("extractDeviceSets() args = %v, want %v", gotArgs, tt.wantArgs)
			}
			var gotExtra []string
			for _, set := range extraDeviceSets {
				gotExtra = append(gotExtra, set.token)
			}
			if !reflect.DeepEqual(gotExtra, tt.wantExtra) {
				t.Errorf("registered extra sets = %v, want %v", gotExtra, tt.wantExtra)
			}
		})
	}
}

func TestRegisterDeviceSetRoutes(t *testing.T) {
	extraDeviceSets = nil
	defer func() { extraDeviceSets = nil }()
	registerDeviceSet("/custom/set")
	// A registered set becomes discoverable like any other.
	if deviceSetToken("/custom/set") != "/custom/set" {
		t.Errorf("registered set not resolvable by name")
	}
	// A custom set's simctl args carry it as --set.
	if got := simctlArgsForSet("/custom/set", "boot", "U"); !reflect.DeepEqual(got, []string{"simctl", "--set", "/custom/set", "boot", "U"}) {
		t.Errorf("simctlArgsForSet(custom) = %v", got)
	}
}
