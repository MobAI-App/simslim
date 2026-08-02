package simslim

import (
	"reflect"
	"testing"
)

func TestCompareDisabled(t *testing.T) {
	managed := map[string]bool{"a": true, "b": true, "c": true, "d": true}
	tests := []struct {
		name     string
		disabled map[string]bool
		desired  map[string]bool
		want     VerifyResult
	}{
		{
			name:     "exact match",
			disabled: map[string]bool{"a": true, "b": true},
			desired:  map[string]bool{"a": true, "b": true},
			want:     VerifyResult{OK: true},
		},
		{
			name:     "erase wiped everything",
			disabled: map[string]bool{},
			desired:  map[string]bool{"a": true, "b": true},
			want:     VerifyResult{Missing: []string{"a", "b"}},
		},
		{
			name:     "partial drift both directions",
			disabled: map[string]bool{"a": true, "c": true},
			desired:  map[string]bool{"a": true, "b": true},
			want:     VerifyResult{Missing: []string{"b"}, Extra: []string{"c"}},
		},
		{
			name:     "unmanaged disabled labels are not drift",
			disabled: map[string]bool{"a": true, "com.example.other": true},
			desired:  map[string]bool{"a": true},
			want:     VerifyResult{OK: true},
		},
		{
			name:     "stock device with empty profile",
			disabled: map[string]bool{},
			desired:  map[string]bool{},
			want:     VerifyResult{OK: true},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := compareDisabled(tt.disabled, tt.desired, managed)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("compareDisabled() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestCompareDisabledMissingSorted(t *testing.T) {
	managed := map[string]bool{"z": true, "a": true, "m": true}
	got := compareDisabled(map[string]bool{}, map[string]bool{"z": true, "a": true, "m": true}, managed)
	want := []string{"a", "m", "z"}
	if !reflect.DeepEqual(got.Missing, want) {
		t.Errorf("Missing = %v, want %v", got.Missing, want)
	}
}
