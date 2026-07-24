package main

import (
	"strings"
	"testing"

	"github.com/mobai-app/simslim"
)

func TestFmtBytes(t *testing.T) {
	cases := map[int64]string{
		0:               "0B",
		512:             "512B",
		1024:            "1.0K",
		1536:            "1.5K",
		1 << 20:         "1.0M",
		900 * 1 << 20:   "900.0M",
		1 << 30:         "1.0G",
		3*1<<30 + 1<<29: "3.5G",
	}
	for in, want := range cases {
		if got := fmtBytes(in); got != want {
			t.Errorf("fmtBytes(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestStateLabel(t *testing.T) {
	disabled := func(n int) *int { return &n }
	tests := []struct {
		name string
		sim  simslim.TopSim
		want string
	}{
		{"slim", simslim.TopSim{ManagedDisabled: disabled(158), ManagedTotal: 158}, "slim"},
		{"partial", simslim.TopSim{ManagedDisabled: disabled(40), ManagedTotal: 158}, "part"},
		{"stock", simslim.TopSim{ManagedDisabled: disabled(0), ManagedTotal: 158}, "stock"},
		{"unknown", simslim.TopSim{StatusError: "not booted"}, "?"},
		{"nil", simslim.TopSim{}, "?"},
	}
	for _, tt := range tests {
		if got := stateLabel(tt.sim); got != tt.want {
			t.Errorf("%s: stateLabel = %q, want %q", tt.name, got, tt.want)
		}
	}
}

func TestApplySort(t *testing.T) {
	sim := func(name string, procs int, bytes int64, cpu float64) simslim.TopSim {
		return simslim.TopSim{Device: simslim.Device{UDID: name, Name: name}, Memory: &simslim.Measurement{Processes: procs, Bytes: bytes, CPU: cpu}}
	}
	base := []simslim.TopSim{
		sim("a", 100, 300, 5),
		sim("b", 50, 100, 30),
		sim("c", 200, 200, 1),
	}
	order := func(m *topModel) string {
		var s string
		for _, x := range m.sims {
			s += x.Name
		}
		return s
	}

	m := &topModel{disk: map[string]int64{}, sortCol: sortRAM, sortDesc: true}
	m.sims = append([]simslim.TopSim(nil), base...)
	m.applySort()
	if got := order(m); got != "acb" { // RAM desc: a=300, c=200, b=100
		t.Errorf("RAM desc order = %s, want acb", got)
	}

	m.setSort(sortCPU) // switch column -> desc by cpu: 30,5,1
	if got := order(m); got != "bac" {
		t.Errorf("CPU desc order = %s, want bac", got)
	}

	m.setSort(sortCPU) // same column -> toggle to asc: 1,5,30
	if got := order(m); got != "cab" {
		t.Errorf("CPU asc order = %s, want cab", got)
	}

	m.setSort(sortProc) // desc by procs: 200,100,50
	if got := order(m); got != "cab" {
		t.Errorf("PROC desc order = %s, want cab", got)
	}
}

func TestOSLess(t *testing.T) {
	tests := []struct {
		a, b string
		want bool
	}{
		{"9.0", "26.4", true}, // numeric, not lexical ("9" > "2" lexically)
		{"26.4", "9.0", false},
		{"17.5", "18.3", true},
		{"26.4", "26.10", true}, // minor compares numerically too
		{"18.3", "18.3", false}, // equal
		{"18", "18.3", true},    // shorter prefix sorts first
		{"", "17.5", true},      // missing version sorts first
	}
	for _, tt := range tests {
		if got := osLess(tt.a, tt.b); got != tt.want {
			t.Errorf("osLess(%q, %q) = %v, want %v", tt.a, tt.b, got, tt.want)
		}
	}
}

func TestReanchor(t *testing.T) {
	sim := func(name string, bytes int64) simslim.TopSim {
		return simslim.TopSim{Device: simslim.Device{UDID: name, Name: name}, Memory: &simslim.Measurement{Bytes: bytes}}
	}
	m := &topModel{disk: map[string]int64{}, sortCol: sortRAM, sortDesc: true}
	m.sims = []simslim.TopSim{sim("a", 300), sim("b", 200), sim("c", 100)}
	m.cursor, m.cursorUDID = 1, "b"

	// b's RAM overtakes a's; after re-sort the cursor must follow b to row 0.
	m.sims[1].Memory.Bytes = 400
	m.applySort()
	m.reanchor()
	if m.cursor != 0 || m.sims[m.cursor].UDID != "b" {
		t.Errorf("cursor = %d (%s), want 0 (b)", m.cursor, m.sims[m.cursor].UDID)
	}

	// The selected sim disappears (shut down): cursor clamps, anchor resets.
	m.sims = m.sims[1:2] // only "a" remains
	m.reanchor()
	if m.cursor != 0 || m.cursorUDID != "" {
		t.Errorf("after removal cursor = %d, anchor = %q; want 0 and empty", m.cursor, m.cursorUDID)
	}
}

func TestStaticFleet(t *testing.T) {
	mem := &simslim.Measurement{Processes: 70, Bytes: 900 * 1 << 20, CPU: 12}
	out := simslim.TopOutput{
		Sims:       []simslim.TopSim{{Device: simslim.Device{UDID: "ABCD1234-5678", Name: "iPhone 15"}, Memory: mem}},
		TotalBytes: 900 * 1 << 20,
	}
	got := staticFleet(out)
	for _, want := range []string{"iPhone 15", "ABCD1234", "70", "900.0M", "1 booted"} {
		if !strings.Contains(got, want) {
			t.Errorf("staticFleet output missing %q\n%s", want, got)
		}
	}
}
