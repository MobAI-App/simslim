package simslim

import "testing"

func TestCountLost(t *testing.T) {
	managed := map[string]bool{"a": true, "b": true, "c": true}
	tests := []struct {
		name    string
		after   map[string]bool
		desired map[string]bool
		want    int
	}{
		{"all persisted", map[string]bool{"a": true, "b": true}, map[string]bool{"a": true, "b": true}, 0},
		{"nothing persisted", map[string]bool{}, map[string]bool{"a": true, "b": true}, 2},
		{"partially persisted", map[string]bool{"a": true}, map[string]bool{"a": true, "b": true}, 1},
		{"stale disable not re-enabled", map[string]bool{"a": true, "c": true}, map[string]bool{"a": true}, 1},
		{"unmanaged labels ignored", map[string]bool{"a": true, "com.example.x": true}, map[string]bool{"a": true}, 0},
		{"stock desired and reached", map[string]bool{}, map[string]bool{}, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := countLost(tt.after, tt.desired, managed); got != tt.want {
				t.Errorf("countLost() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestOSMajor(t *testing.T) {
	tests := []struct {
		v    string
		want int
	}{
		{"17.2", 17}, {"18.5", 18}, {"26.5", 26}, {"18", 18}, {"", 0}, {"garbage", 0},
	}
	for _, tt := range tests {
		if got := osMajor(tt.v); got != tt.want {
			t.Errorf("osMajor(%q) = %d, want %d", tt.v, got, tt.want)
		}
	}
}
