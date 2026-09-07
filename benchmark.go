package simslim

import "context"

// BenchmarkResult is one device's stock-vs-slim memory comparison.
type BenchmarkResult struct {
	Device
	StockMemory Measurement `json:"stockMemory"`
	SlimMemory  Measurement `json:"slimMemory"`
	Error       string      `json:"error,omitempty"`
}

// BenchmarkOutput is the fleet-wide result of FleetBenchmark: every device's
// comparison plus the summed totals across devices that completed both
// measurements.
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

// FleetBenchmark measures each device stock, slims it, measures again, then
// restores it to stock (and, if preserveBootState, to its original boot
// state) before moving to the next device. A device that fails at any step
// records that failure in its own Error and does not abort the rest of the
// fleet.
func FleetBenchmark(ctx context.Context, udids []string, preserveBootState bool, report Reporter) BenchmarkOutput {
	results := make([]BenchmarkResult, len(udids))
	for i, udid := range udids {
		results[i] = benchmarkDevice(ctx, udid, preserveBootState, report)
	}
	stock, slim := sumBenchmark(results)
	return BenchmarkOutput{Devices: results, TotalStockBytes: stock, TotalSlimBytes: slim}
}

// sumBenchmark totals stock and slim bytes across devices that completed
// both measurements, skipping any device that recorded an error.
func sumBenchmark(results []BenchmarkResult) (stockBytes, slimBytes int64) {
	for _, r := range results {
		if r.Error != "" {
			continue
		}
		stockBytes += r.StockMemory.Bytes
		slimBytes += r.SlimMemory.Bytes
	}
	return stockBytes, slimBytes
}

func benchmarkDevice(ctx context.Context, udid string, preserveBootState bool, report Reporter) BenchmarkResult {
	d, err := FindDevice(ctx, udid, "")
	if err != nil {
		return BenchmarkResult{Device: Device{UDID: udid}, Error: err.Error()}
	}
	res := BenchmarkResult{Device: d}
	originallyShutdown := preserveBootState && d.State == "Shutdown"

	report.report(udid + ": establishing stock baseline...")
	if _, err := timedDisableSlim(ctx, d, report); err != nil {
		res.Error = err.Error()
		return res
	}
	stock, err := Measure(ctx, udid)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	res.StockMemory = stock

	report.report(udid + ": slimming...")
	if _, err := timedEnableSlim(ctx, d, report); err != nil {
		res.Error = err.Error()
		restoreBenchmarkDevice(ctx, d, originallyShutdown, report)
		return res
	}
	slim, err := Measure(ctx, udid)
	if err != nil {
		res.Error = err.Error()
		restoreBenchmarkDevice(ctx, d, originallyShutdown, report)
		return res
	}
	res.SlimMemory = slim

	report.report(udid + ": restoring...")
	if err := restoreBenchmarkDevice(ctx, d, originallyShutdown, report); err != nil {
		res.Error = err.Error()
	}
	return res
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
