package main

import (
	"context"
	"fmt"
	"os"

	cli "github.com/urfave/cli/v3"

	"github.com/mobai-app/simslim"
)

func cmdBenchmark(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udids := cmd.Args().Slice()
	if len(udids) == 0 {
		return fmt.Errorf("benchmark expects one or more simulator UDIDs (see `simslim list`)")
	}
	runs := int(cmd.Int("runs"))
	if runs < 1 {
		return fmt.Errorf("benchmark --runs must be at least 1")
	}
	preserveBootState := cmd.Bool("preserve-boot-state")

	var report simslim.Reporter
	if !jsonOutput {
		report = func(msg string) { fmt.Fprintln(os.Stderr, msg) }
	}

	out := simslim.FleetBenchmark(ctx, udids, runs, preserveBootState, report)
	if jsonOutput {
		return writeJSON(out)
	}
	printBenchmark(out, runs)
	return nil
}

func printBenchmark(out simslim.BenchmarkOutput, runs int) {
	fmt.Printf("%-30s %-24s %-24s %8s\n", "SIMULATOR", "STOCK", "SLIM", "RATIO")
	for _, d := range out.Devices {
		name := truncate(fmt.Sprintf("%s · %s", d.Name, shortUDID(d.UDID)), 30)
		if d.Error != "" {
			fmt.Printf("%-30s error: %s\n", name, d.Error)
			continue
		}
		fmt.Printf("%-30s %-24s %-24s %8s\n", name,
			formatStats(d.Stock, runs), formatStats(d.Slim, runs),
			benchmarkRatio(d.Stock.MeanBytes, d.Slim.MeanBytes))
	}
	fmt.Printf("\nFleet total (mean): %s stock -> %s slim (%s)\n",
		humanBytes(out.TotalStockBytes), humanBytes(out.TotalSlimBytes),
		benchmarkRatio(out.TotalStockBytes, out.TotalSlimBytes))
}

// formatStats renders a device's mean footprint, appending the min-max range
// once there is more than one sample to show a spread for.
func formatStats(stats simslim.MemoryStats, runs int) string {
	mean := humanBytes(stats.MeanBytes)
	if runs <= 1 || len(stats.Samples) <= 1 {
		return mean
	}
	return fmt.Sprintf("%s (%s-%s)", mean, humanBytes(stats.MinBytes), humanBytes(stats.MaxBytes))
}

// benchmarkRatio formats how many times smaller the slim footprint is, or
// "—" when there's nothing to divide by (a device that errored before it
// could be measured, for instance).
func benchmarkRatio(stockBytes, slimBytes int64) string {
	if slimBytes <= 0 {
		return "—"
	}
	return fmt.Sprintf("%.2fx", float64(stockBytes)/float64(slimBytes))
}
