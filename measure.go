package simslim

import (
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Measurement is a device's real memory cost.
type Measurement struct {
	Processes int     `json:"processes"`
	Bytes     int64   `json:"bytes"` // summed phys_footprint (compressed + dirty), the number that caps how many sims fit
	CPU       float64 `json:"cpu"`   // summed %cpu across the tree (ps's decaying average; can exceed 100 on multicore)
}

// Process is one process in a simulator's launchd tree, for the top drill-down.
type Process struct {
	PID     int     `json:"pid"`
	Command string  `json:"command"`
	Bytes   int64   `json:"bytes"`
	CPU     float64 `json:"cpu"`
}

// measure sums the phys_footprint of every process in the device's launchd tree.
// phys_footprint (the same value Activity Monitor's "Memory" column reports)
// counts compressed and swapped pages, so it stays accurate under memory
// pressure where resident size would read misleadingly low.
func Measure(ctx context.Context, udid string) (Measurement, error) {
	root, err := simLaunchdPID(ctx, udid)
	if err != nil {
		return Measurement{}, err
	}
	snap, err := processSnapshot(ctx)
	if err != nil {
		return Measurement{}, err
	}
	footprint, err := footprintByPID(ctx)
	if err != nil {
		return Measurement{}, err
	}

	return measureTree(root, snap, footprint), nil
}

// MeasureProcesses returns every process in the device's launchd tree with its
// own footprint and cpu, sorted by memory descending — the top drill-down view.
func MeasureProcesses(ctx context.Context, udid string) ([]Process, error) {
	root, err := simLaunchdPID(ctx, udid)
	if err != nil {
		return nil, err
	}
	snap, err := processSnapshot(ctx)
	if err != nil {
		return nil, err
	}
	footprint, err := footprintByPID(ctx)
	if err != nil {
		return nil, err
	}

	procs := make([]Process, 0)
	for pid := range treePIDs(root, snap.children) {
		procs = append(procs, Process{PID: pid, Command: snap.comm[pid], Bytes: footprint[pid], CPU: snap.cpu[pid]})
	}
	sort.Slice(procs, func(i, j int) bool {
		if procs[i].Bytes != procs[j].Bytes {
			return procs[i].Bytes > procs[j].Bytes
		}
		return procs[i].PID < procs[j].PID
	})
	return procs, nil
}

// measureMany takes one process and footprint snapshot for every requested
// simulator. This keeps the GUI's RAM column current without running the
// relatively expensive `top` command once per booted device.
func MeasureMany(ctx context.Context, udids []string) (map[string]Measurement, map[string]string) {
	measurements := make(map[string]Measurement, len(udids))
	errorsByUDID := make(map[string]string)
	roots := make(map[string]int, len(udids))
	for _, udid := range udids {
		root, err := simLaunchdPID(ctx, udid)
		if err != nil {
			errorsByUDID[udid] = err.Error()
			continue
		}
		roots[udid] = root
	}
	if len(roots) == 0 {
		return measurements, errorsByUDID
	}

	snap, err := processSnapshot(ctx)
	if err != nil {
		for udid := range roots {
			errorsByUDID[udid] = err.Error()
		}
		return measurements, errorsByUDID
	}
	footprint, err := footprintByPID(ctx)
	if err != nil {
		for udid := range roots {
			errorsByUDID[udid] = err.Error()
		}
		return measurements, errorsByUDID
	}

	for udid, root := range roots {
		measurements[udid] = measureTree(root, snap, footprint)
	}
	return measurements, errorsByUDID
}

// treePIDs collects every pid reachable from root through the child map.
func treePIDs(root int, children map[int][]int) map[int]bool {
	seen := map[int]bool{}
	stack := []int{root}
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		stack = append(stack, children[pid]...)
	}
	return seen
}

func measureTree(root int, snap psSnapshot, footprint map[int]int64) Measurement {
	var m Measurement
	for pid := range treePIDs(root, snap.children) {
		m.Processes++
		m.Bytes += footprint[pid]
		m.CPU += snap.cpu[pid]
	}
	return m
}

func simLaunchdPID(ctx context.Context, udid string) (int, error) {
	out, err := exec.CommandContext(ctx, "pgrep", "-f", udid+"/data/var/run/launchd_bootstrap").Output()
	if err != nil {
		return 0, fmt.Errorf("simulator %s does not appear to be booted", udid)
	}
	fields := strings.Fields(string(out))
	if len(fields) == 0 {
		return 0, fmt.Errorf("simulator %s does not appear to be booted", udid)
	}
	return strconv.Atoi(fields[0])
}

// psSnapshot is one `ps` sweep of every process: parent links, cpu, and name.
type psSnapshot struct {
	children map[int][]int
	cpu      map[int]float64
	comm     map[int]string
}

func processSnapshot(ctx context.Context) (psSnapshot, error) {
	// comm is the full executable path (untruncated, unlike ucomm); we basename
	// it so the drill-down shows real daemon names like backboardd or SpringBoard.
	out, err := exec.CommandContext(ctx, "ps", "-axo", "pid,ppid,%cpu,comm").Output()
	if err != nil {
		return psSnapshot{}, err
	}
	return parsePS(string(out)), nil
}

func parsePS(out string) psSnapshot {
	snap := psSnapshot{children: map[int][]int{}, cpu: map[int]float64{}, comm: map[int]string{}}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		snap.children[ppid] = append(snap.children[ppid], pid)
		if cpu, err := strconv.ParseFloat(f[2], 64); err == nil {
			snap.cpu[pid] = cpu
		}
		snap.comm[pid] = commName(strings.Join(f[3:], " ")) // join defends against spaces in the path
	}
	return snap
}

// commName reduces a full executable path to its basename.
func commName(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}

var topMemLine = regexp.MustCompile(`^\s*(\d+)\s+([0-9.]+[KMGB+]?)`)

func footprintByPID(ctx context.Context) (map[int]int64, error) {
	out, err := exec.CommandContext(ctx, "top", "-l", "1", "-stats", "pid,mem").Output()
	if err != nil {
		return nil, err
	}
	mem := map[int]int64{}
	for _, line := range strings.Split(string(out), "\n") {
		g := topMemLine.FindStringSubmatch(line)
		if g == nil {
			continue
		}
		pid, _ := strconv.Atoi(g[1])
		mem[pid] = parseBytes(g[2])
	}
	return mem, nil
}

func parseBytes(s string) int64 {
	s = strings.TrimSuffix(strings.TrimSpace(s), "+")
	if s == "" {
		return 0
	}
	mult := int64(1)
	switch s[len(s)-1] {
	case 'K':
		mult, s = 1<<10, s[:len(s)-1]
	case 'M':
		mult, s = 1<<20, s[:len(s)-1]
	case 'G':
		mult, s = 1<<30, s[:len(s)-1]
	case 'B':
		s = s[:len(s)-1]
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return int64(v * float64(mult))
}
