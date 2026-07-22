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
