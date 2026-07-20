package main

import (
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// Measurement is a device's real memory cost.
type Measurement struct {
	Processes int
	Bytes     int64 // summed phys_footprint (compressed + dirty), the number that caps how many sims fit
}

// measure sums the phys_footprint of every process in the device's launchd tree.
// phys_footprint (the same value Activity Monitor's "Memory" column reports)
// counts compressed and swapped pages, so it stays accurate under memory
// pressure where resident size would read misleadingly low.
func measure(ctx context.Context, udid string) (Measurement, error) {
	root, err := simLaunchdPID(ctx, udid)
	if err != nil {
		return Measurement{}, err
	}
	children, err := childMap(ctx)
	if err != nil {
		return Measurement{}, err
	}
	footprint, err := footprintByPID(ctx)
	if err != nil {
		return Measurement{}, err
	}

	var m Measurement
	stack := []int{root}
	seen := map[int]bool{}
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		m.Processes++
		m.Bytes += footprint[pid]
		stack = append(stack, children[pid]...)
	}
	return m, nil
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

func childMap(ctx context.Context) (map[int][]int, error) {
	out, err := exec.CommandContext(ctx, "ps", "-axo", "pid,ppid").Output()
	if err != nil {
		return nil, err
	}
	children := map[int][]int{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 == nil && err2 == nil {
			children[ppid] = append(children[ppid], pid)
		}
	}
	return children, nil
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
