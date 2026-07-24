package simslim

import (
	"context"
	"sort"
	"sync"
)

// FleetSnapshot gathers the live resource view of every booted simulator: its
// slim status and memory come from one shared process snapshot; disk usage is
// optional because it shells out to `du` per device and is comparatively slow.
func FleetSnapshot(ctx context.Context, withDisk bool) (TopOutput, error) {
	devices, err := ListDevices(ctx)
	if err != nil {
		return TopOutput{}, err
	}

	var booted []Device
	for _, d := range devices {
		if d.State == "Booted" {
			booted = append(booted, d)
		}
	}

	udids := make([]string, len(booted))
	for i, d := range booted {
		udids[i] = d.UDID
	}
	memory, memErr := MeasureMany(ctx, udids)

	sims := make([]TopSim, len(booted))
	var wg sync.WaitGroup
	for i, d := range booted {
		wg.Add(1)
		go func(i int, d Device) {
			defer wg.Done()
			sim := TopSim{Device: d}
			if st, _, err := ReadStatusForDevice(ctx, d); err == nil {
				disabled := st.ManagedDisabled
				sim.ManagedDisabled = &disabled
				sim.ManagedTotal = st.ManagedTotal
			} else {
				sim.StatusError = err.Error()
			}
			if withDisk {
				if du, err := DeviceDiskUsage(ctx, d.UDID); err == nil {
					bytes := du.Bytes
					sim.DiskBytes = &bytes
				}
			}
			sims[i] = sim
		}(i, d)
	}
	wg.Wait()

	var out TopOutput
	for _, sim := range sims {
		if m, ok := memory[sim.UDID]; ok {
			measurement := m
			sim.Memory = &measurement
			out.TotalBytes += m.Bytes
		} else if e, ok := memErr[sim.UDID]; ok {
			sim.MemoryError = e
		}
		out.Sims = append(out.Sims, sim)
	}

	sort.Slice(out.Sims, func(i, j int) bool {
		return topBytes(out.Sims[i]) > topBytes(out.Sims[j])
	})
	return out, nil
}

func topBytes(s TopSim) int64 {
	if s.Memory == nil {
		return -1
	}
	return s.Memory.Bytes
}
