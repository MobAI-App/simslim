package simslim

import (
	"context"
	"fmt"
)

// MemoryStats summarizes repeated byte-footprint samples from one
// device/state (stock or slim) across a benchmark's runs.
type MemoryStats struct {
	Samples   []int64 `json:"samples"` // bytes, one per run, in order
	MinBytes  int64   `json:"minBytes"`
	MeanBytes int64   `json:"meanBytes"`
	MaxBytes  int64   `json:"maxBytes"`
}

// computeStats summarizes a set of byte samples. An empty input returns the
// zero value.
func computeStats(samples []int64) MemoryStats {
	if len(samples) == 0 {
		return MemoryStats{}
	}
	stats := MemoryStats{Samples: samples, MinBytes: samples[0], MaxBytes: samples[0]}
	var sum int64
	for _, b := range samples {
		sum += b
		if b < stats.MinBytes {
			stats.MinBytes = b
		}
		if b > stats.MaxBytes {
			stats.MaxBytes = b
		}
	}
	stats.MeanBytes = sum / int64(len(samples))
	return stats
}

// BenchmarkResult is one device's stock-vs-slim memory comparison, over one
// or more runs.
type BenchmarkResult struct {
	Device
	// FirstBootBytes is the stock footprint measured during the uncounted
	// warm-up boot, before any migration/indexing settling: diagnostic only,
	// not included in Stock's samples or stats. Omitted if the warm-up boot
	// failed before it could be measured.
	FirstBootBytes int64       `json:"firstBootBytes,omitempty"`
	Stock          MemoryStats `json:"stock"`
	Slim           MemoryStats `json:"slim"`
	Error          string      `json:"error,omitempty"`
}

// BenchmarkOutput is the fleet-wide result of FleetBenchmark: every device's
// comparison plus the summed mean totals across devices that completed at
// least one run.
type BenchmarkOutput struct {
	Devices         []BenchmarkResult `json:"devices"`
	TotalStockBytes int64             `json:"totalStockBytes"`
	TotalSlimBytes  int64             `json:"totalSlimBytes"`
}

// fullSlimProfile is the default `simslim on` applies with no --except/--keep:
// every managed daemon disabled.
func fullSlimProfile() Profile {
	return Profile{ExceptCategories: map[string]bool{}, Keep: map[string]bool{}}
}

// FleetBenchmark measures each device stock, slims it, measures again,
// repeating runs times, then restores it to stock (and, if
// preserveBootState, to its original boot state) before moving to the next
// device. A device that fails partway through records that failure in its
// own Error alongside whatever samples it completed, and does not abort the
// rest of the fleet. runs must be >= 1.
func FleetBenchmark(ctx context.Context, udids []string, runs int, preserveBootState bool, report Reporter) BenchmarkOutput {
	if runs < 1 {
		runs = 1
	}
	results := make([]BenchmarkResult, len(udids))
	for i, udid := range udids {
		results[i] = benchmarkDevice(ctx, udid, runs, preserveBootState, report)
	}
	stock, slim := sumBenchmark(results)
	return BenchmarkOutput{Devices: results, TotalStockBytes: stock, TotalSlimBytes: slim}
}

// sumBenchmark totals mean stock and slim bytes across devices that
// completed at least one run, skipping any device that recorded an error.
func sumBenchmark(results []BenchmarkResult) (stockBytes, slimBytes int64) {
	for _, r := range results {
		if r.Error != "" {
			continue
		}
		stockBytes += r.Stock.MeanBytes
		slimBytes += r.Slim.MeanBytes
	}
	return stockBytes, slimBytes
}

func benchmarkDevice(ctx context.Context, udid string, runs int, preserveBootState bool, report Reporter) BenchmarkResult {
	d, err := FindDevice(ctx, udid, "")
	if err != nil {
		return BenchmarkResult{Device: Device{UDID: udid}, Error: err.Error()}
	}
	originallyShutdown := preserveBootState && d.State == "Shutdown"

	var stockSamples, slimSamples []int64
	firstBootBytes, runErr := warmUpDevice(ctx, d, report)
	for i := 0; i < runs && runErr == nil; i++ {
		report.report(fmt.Sprintf("%s: run %d/%d: establishing stock baseline...", udid, i+1, runs))
		if _, err := timedDisableSlim(ctx, d, report); err != nil {
			runErr = err
			break
		}
		stock, err := Measure(ctx, udid)
		if err != nil {
			runErr = err
			break
		}

		report.report(fmt.Sprintf("%s: run %d/%d: slimming...", udid, i+1, runs))
		if _, err := timedEnableSlim(ctx, d, report); err != nil {
			runErr = err
			break
		}
		slim, err := Measure(ctx, udid)
		if err != nil {
			runErr = err
			break
		}

		stockSamples = append(stockSamples, stock.Bytes)
		slimSamples = append(slimSamples, slim.Bytes)
	}

	res := BenchmarkResult{Device: d, FirstBootBytes: firstBootBytes, Stock: computeStats(stockSamples), Slim: computeStats(slimSamples)}

	report.report(udid + ": restoring...")
	if err := restoreBenchmarkDevice(ctx, d, originallyShutdown, report); err != nil && runErr == nil {
		runErr = err
	}
	if runErr != nil {
		res.Error = runErr.Error()
	}
	return res
}

// warmUpDevice boots the device once and shuts it back down, uncounted,
// before any measured run starts. A device's very first boot after creation
// (or after sitting shut down for a while) can still be running one-time
// migrators (LaunchServicesMigrator, MCProfile, Spotlight indexing, …) right
// when a naive first sample would be taken, inflating it relative to later
// runs. Booting once and shutting back down lets that settle, so every
// counted run's boot starts from the same warmed state. The footprint at
// this uncounted boot is measured and returned purely as diagnostic data
// (e.g. to see how much a cold boot actually differs from a warmed one);
// it plays no part in the benchmark's own statistics.
func warmUpDevice(ctx context.Context, d Device, report Reporter) (firstBootBytes int64, err error) {
	report.report(d.UDID + ": warming up (uncounted boot to settle first-boot migration)...")
	bootCtx, cancel := context.WithTimeout(ctx, BootTimeout)
	defer cancel()
	if err := BootAndWait(bootCtx, d.Set, d.UDID); err != nil {
		return 0, err
	}
	m, measureErr := Measure(ctx, d.UDID)
	if measureErr == nil {
		firstBootBytes = m.Bytes
	}
	shutdownCtx, cancel2 := context.WithTimeout(ctx, ShutdownTimeout)
	defer cancel2()
	if err := Shutdown(shutdownCtx, d.Set, d.UDID); err != nil {
		return firstBootBytes, err
	}
	return firstBootBytes, WaitShutdown(shutdownCtx, d.Set, d.UDID, ShutdownTimeout)
}

// restoreBenchmarkDevice returns a benchmarked device to stock and, if
// requested, back to the shutdown state it started in.
func restoreBenchmarkDevice(ctx context.Context, d Device, returnToShutdown bool, report Reporter) error {
	if _, err := timedDisableSlim(ctx, d, report); err != nil {
		return err
	}
	if !returnToShutdown {
		return nil
	}
	shutdownCtx, cancel := context.WithTimeout(ctx, ShutdownTimeout)
	defer cancel()
	if err := Shutdown(shutdownCtx, d.Set, d.UDID); err != nil {
		return err
	}
	return WaitShutdown(shutdownCtx, d.Set, d.UDID, ShutdownTimeout)
}

func timedDisableSlim(ctx context.Context, d Device, report Reporter) (bool, error) {
	tctx, cancel := context.WithTimeout(ctx, BootTimeout)
	defer cancel()
	return DisableSlim(tctx, d.Set, d.UDID, report)
}

func timedEnableSlim(ctx context.Context, d Device, report Reporter) (bool, error) {
	tctx, cancel := context.WithTimeout(ctx, BootTimeout)
	defer cancel()
	return EnableSlim(tctx, d.Set, d.UDID, fullSlimProfile(), report)
}
