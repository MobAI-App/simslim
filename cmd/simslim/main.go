package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/mobai-app/simslim"
	cli "github.com/urfave/cli/v3"
)

// version is overwritten at build time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "-v", "--version", "version":
		fmt.Printf("simslim %s\n", version)
		return
	case "-h", "--help", "help":
		usage()
		return
	}

	if runtime.GOOS != "darwin" {
		fatal("simslim only works on macOS (it drives Apple's iOS simulators).")
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	if err := newApp().Run(ctx, os.Args); err != nil {
		fatal(err.Error())
	}
}

func cmdList(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	if cmd.Args().Len() != 0 {
		return fmt.Errorf("list takes no arguments")
	}
	devices, err := simslim.ListDevices(ctx)
	if err != nil {
		return err
	}
	sort.Slice(devices, func(i, j int) bool {
		if devices[i].OSVersion != devices[j].OSVersion {
			return devices[i].OSVersion > devices[j].OSVersion
		}
		return devices[i].Name < devices[j].Name
	})
	managed := len(simslim.SlimmableSet())
	memoryByUDID := map[string]simslim.Measurement{}
	memoryErrors := map[string]string{}
	if jsonOutput {
		bootedUDIDs := make([]string, 0)
		for _, device := range devices {
			if device.State == "Booted" {
				bootedUDIDs = append(bootedUDIDs, device.UDID)
			}
		}
		memoryByUDID, memoryErrors = simslim.MeasureMany(ctx, bootedUDIDs)
	}
	summaries := make([]simslim.DeviceSummary, 0, len(devices))
	for _, d := range devices {
		tag := "shutdown"
		summary := simslim.DeviceSummary{Device: d, ManagedTotal: managed}
		if d.State == "Booted" {
			tag = "booted"
			if measurement, ok := memoryByUDID[d.UDID]; ok {
				measured := measurement
				summary.Memory = &measured
			}
			summary.MemoryError = memoryErrors[d.UDID]
			if st, _, err := simslim.ReadStatusForDevice(ctx, d); err == nil {
				tag = fmt.Sprintf("booted · %d/%d slim", st.ManagedDisabled, managed)
				disabled := st.ManagedDisabled
				summary.ManagedDisabled = &disabled
			} else {
				summary.StatusError = err.Error()
			}
		}
		summaries = append(summaries, summary)
		if !jsonOutput {
			line := fmt.Sprintf("%s  %-22s iOS %-6s %s", d.UDID, truncate(d.Name, 22), d.OSVersion, tag)
			if d.Set != "" && d.Set != "default" {
				line += "  (" + d.Set + ")"
			}
			fmt.Println(line)
		}
	}
	if jsonOutput {
		return writeJSON(summaries)
	}
	return nil
}

func cmdProfiles(_ context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	args := cmd.Args().Slice()
	if len(args) > 1 {
		return fmt.Errorf("profiles takes at most one category ID (see `simslim profiles`)")
	}
	if len(args) == 1 {
		c, ok := simslim.CategoryByID(args[0])
		if !ok {
			return fmt.Errorf("unknown category %q (see `simslim profiles`)", args[0])
		}
		if jsonOutput {
			return writeJSON(c)
		}
		fmt.Printf("%-14s %s\n", c.ID, c.Name)
		fmt.Printf("               %s\n", c.Description)
		fmt.Printf("               %d daemons · ~%d MB idle footprint when enabled\n", len(c.Labels), c.ApproxMemoryMB)
		fmt.Printf("               When disabled: %s\n", c.Downside)
		fmt.Println("\nDaemons:")
		for _, l := range c.Labels {
			if desc := c.ServiceDescriptions[l]; desc != "" {
				fmt.Printf("  %-44s %s\n", l, desc)
			} else {
				fmt.Printf("  %s\n", l)
			}
		}
		for _, service := range c.AlwaysEnabled {
			fmt.Printf("  %-44s Always on — %s\n", service.Label, service.Reason)
		}
		return nil
	}
	if jsonOutput {
		return writeJSON(simslim.Categories)
	}
	for _, c := range simslim.Categories {
		fmt.Printf("%-14s %s\n", c.ID, c.Name)
		fmt.Printf("               %d daemons · ~%d MB idle footprint when enabled\n", len(c.Labels), c.ApproxMemoryMB)
		fmt.Printf("               When disabled: %s\n", c.Downside)
		for _, service := range c.AlwaysEnabled {
			fmt.Printf("               Always on: %s — %s\n", service.Label, service.Reason)
		}
	}
	fmt.Printf("\n%d daemons across %d categories. Core workflow and deadlock-prone daemons are never disabled.\n",
		len(simslim.SlimmableSet()), len(simslim.Categories))
	fmt.Println("Memory estimates are iOS 26.5 clean-boot measurements; they vary by runtime and workload and are not additive.")
	return nil
}

func cmdNewProfile(_ context.Context, cmd *cli.Command) error {
	args := cmd.Args().Slice()
	if len(args) > 1 {
		return fmt.Errorf("profile takes an optional output path")
	}
	var dest string
	if len(args) == 1 {
		dest = args[0]
	}

	intoDir := false
	if dest != "" {
		if info, err := os.Stat(dest); err == nil {
			if info.IsDir() {
				intoDir = true
			} else {
				return fmt.Errorf("refusing to overwrite %s", dest)
			}
		}
	}
	if !stdinIsTerminal() {
		return fmt.Errorf("profile is interactive; run it in a terminal")
	}

	sp, err := runProfileWizard(os.Stdin, os.Stderr, enterRawMode)
	if err != nil {
		if errors.Is(err, errWizardCancelled) {
			fmt.Fprintln(os.Stderr, "Cancelled; no profile written.")
			return nil
		}
		return err
	}
	data, err := simslim.MarshalProfile(sp)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Keeping %d feature(s) fully enabled and %d individual daemon(s); slimming the rest.\n", len(sp.Except), len(sp.Keep))

	path := dest
	if intoDir {
		path = filepath.Join(dest, simslim.ProfileFileName(sp.Name))
	}
	if path == "" {
		_, err = os.Stdout.Write(data)
		return err
	}

	if intoDir {
		if _, err := os.Stat(path); err == nil {
			os.Stdout.Write(data)
			return fmt.Errorf("%s already exists; printed the profile above instead of overwriting it", path)
		}
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	fmt.Fprintf(os.Stderr, "Wrote %s. Apply it with `simslim on <udid> --profile %s`.\n", path, path)
	return nil
}

func cmdStatus(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	showDropped := cmd.Bool("dropped")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}
	st, disabled, err := simslim.ReadStatus(ctx, udid)
	if err != nil {
		return err
	}
	verdict := "stock"
	switch {
	case st.ManagedDisabled == st.ManagedTotal:
		verdict = "slim"
	case st.ManagedDisabled > 0:
		verdict = "partially slim"
	}
	var dropped []simslim.DroppedCategory
	if showDropped {
		dropped = simslim.DroppedCategories(disabled)
	}
	if jsonOutput {
		return writeJSON(simslim.StatusOutput{Status: st, Verdict: verdict, Dropped: dropped})
	}
	fmt.Printf("%s: %d/%d managed daemons disabled (%s)\n", udid, st.ManagedDisabled, st.ManagedTotal, verdict)
	if showDropped {
		if len(dropped) == 0 {
			fmt.Println("  Nothing dropped; every managed daemon is enabled.")
		}
		for _, c := range dropped {
			fmt.Printf("  %-14s %s — %s\n", c.ID, c.Name, c.Downside)
			for _, l := range c.Labels {
				fmt.Printf("    %s\n", l)
			}
		}
	}
	return nil
}

func cmdDoctor(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	if cmd.Bool("list") {
		if cmd.Args().Len() != 0 {
			return fmt.Errorf("doctor --list takes no arguments")
		}
		if jsonOutput {
			return writeJSON(simslim.Features)
		}
		for _, f := range simslim.Features {
			fmt.Printf("%-16s %-38s %s\n", f.ID, f.Name, strings.Join(f.Labels, ", "))
		}
		return nil
	}

	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}
	features, err := simslim.ResolveFeatures(simslim.SplitList(cmd.String("requires")))
	if err != nil {
		return err
	}
	if len(features) == 0 {
		return fmt.Errorf("doctor needs at least one feature via --requires (see `simslim doctor --list`)")
	}

	_, disabled, err := simslim.ReadStatus(ctx, udid)
	if err != nil {
		return err
	}
	report := simslim.DiagnoseFeatures(features, disabled)
	report.UDID = udid

	if jsonOutput {
		if err := writeJSON(report); err != nil {
			return err
		}
	} else {
		broken := 0
		for _, f := range report.Features {
			if !f.OK {
				broken++
			}
		}
		fmt.Printf("%s: %d/%d required features OK\n", udid, len(report.Features)-broken, len(report.Features))
		for _, f := range report.Features {
			if f.OK {
				fmt.Printf("  ok    %s\n", f.ID)
			} else {
				fmt.Printf("  BROKEN %s — %s disabled\n", f.ID, strings.Join(f.Disabled, ", "))
			}
		}
	}
	if !report.OK {
		os.Exit(1)
	}
	return nil
}

func cmdMeasure(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}
	m, err := simslim.Measure(ctx, udid)
	if err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(m)
	}
	fmt.Printf("%s: %d processes, %s memory footprint\n", udid, m.Processes, humanBytes(m.Bytes))
	return nil
}

func cmdSize(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}
	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	measurement, err := simslim.DeviceDiskUsage(tctx, udid)
	if err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(measurement)
	}
	fmt.Printf("%s: %s on disk\n", udid, humanBytes(measurement.Bytes))
	return nil
}

func cmdDiskCategories(_ context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	if cmd.Args().Len() != 0 {
		return fmt.Errorf("disk-categories takes no arguments")
	}
	if jsonOutput {
		return writeJSON(simslim.DiskCleanupCategories)
	}
	for _, category := range simslim.DiskCleanupCategories {
		availability := "cleanable"
		if !category.CanClean {
			availability = "measured only"
		}
		fmt.Printf("%-22s %-28s %s · %s\n", category.ID, category.Name, category.Risk, availability)
		fmt.Printf("                       %s\n", category.Downside)
	}
	return nil
}

func cmdDiskPlan(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}
	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	plan, err := simslim.PlanDiskCleanup(tctx, udid)
	if err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(plan)
	}
	fmt.Printf("%s: %s currently cleanable\n", udid, humanBytes(plan.CleanableBytes))
	for _, category := range plan.Categories {
		availability := ""
		if !category.CanClean {
			availability = " (iOS-managed; measured only)"
		}
		fmt.Printf("  %-22s %8s%s\n", category.ID, humanBytes(category.Bytes), availability)
	}
	if len(plan.Storage) > 0 {
		fmt.Println("  Stored data (read only)")
		for _, storage := range plan.Storage {
			fmt.Printf("    %-20s %8s\n", storage.ID, humanBytes(storage.Bytes))
		}
	}
	return nil
}

func cmdDiskClean(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}
	if !cmd.Bool("confirm") {
		return fmt.Errorf("disk-clean permanently deletes data; pass --confirm after reviewing `simslim disk-plan %s`", udid)
	}
	categoryIDs := simslim.SplitList(cmd.String("categories"))
	if _, err := simslim.ValidateDiskCleanupSelection(categoryIDs); err != nil {
		return err
	}
	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	result, err := simslim.CleanDeviceDisk(tctx, udid, categoryIDs, cmd.Bool("preserve-boot-state"))
	if err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Cleaned %s and reclaimed %s. Generated contents stay deleted; on-demand assets may download again when needed.\n", udid, humanBytes(result.ReclaimedBytes))
	return nil
}

func cmdClone(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	args := cmd.Args().Slice()
	if len(args) != 2 {
		return fmt.Errorf("clone expects a simulator UDID and a new name")
	}
	name, err := simslim.NormalizeSimulatorName(args[1])
	if err != nil {
		return err
	}

	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	newUDID, err := simslim.CloneDevice(tctx, args[0], name)
	if err != nil {
		return err
	}
	result := simslim.SimulatorMutationOutput{Action: "clone", UDID: newUDID, Name: name, SourceUDID: args[0]}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Cloned %s as %q (%s).\n", args[0], name, newUDID)
	return nil
}

func cmdRename(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	args := cmd.Args().Slice()
	if len(args) != 2 {
		return fmt.Errorf("rename expects a simulator UDID and a new name")
	}
	name, err := simslim.NormalizeSimulatorName(args[1])
	if err != nil {
		return err
	}

	tctx, cancel := context.WithTimeout(ctx, simslim.ShutdownTimeout)
	defer cancel()
	if err := simslim.RenameDevice(tctx, args[0], name); err != nil {
		return err
	}
	result := simslim.SimulatorMutationOutput{Action: "rename", UDID: args[0], Name: name}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Renamed %s to %q.\n", args[0], name)
	return nil
}

func cmdErase(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}

	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	if err := simslim.EraseDevice(tctx, udid); err != nil {
		return err
	}
	result := simslim.SimulatorMutationOutput{Action: "erase", UDID: udid}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Erased simulator %s.\n", udid)
	return nil
}

func cmdDelete(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}

	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	if err := simslim.DeleteDevice(tctx, udid); err != nil {
		return err
	}
	result := simslim.SimulatorMutationOutput{Action: "delete", UDID: udid}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Deleted simulator %s.\n", udid)
	return nil
}

func cmdBoot(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}

	// Resolve the exact device first so a simctl alias such as "all" can never
	// enter the boot path, consistent with erase/delete.
	device, err := simslim.FindDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	result := simslim.SimulatorMutationOutput{Action: "boot", UDID: udid}
	if device.State == "Booted" {
		if jsonOutput {
			return writeJSON(result)
		}
		fmt.Printf("Simulator %s is already booted.\n", udid)
		return nil
	}

	// Booting and waiting for services can take ~a minute; keep an interactive
	// caller informed. Suppressed under --json so machine consumers that read a
	// combined stdout/stderr stream get clean JSON.
	if !jsonOutput {
		fmt.Fprintf(os.Stderr, "Booting %s...\n", udid)
	}
	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	if err := simslim.BootAndWait(tctx, device.Set, udid); err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Booted %s.\n", udid)
	return nil
}

func cmdShutdown(ctx context.Context, cmd *cli.Command) error {
	jsonOutput := cmd.Bool("json")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}

	// Resolve the exact device first so a simctl alias such as "all" can never
	// enter the shutdown path, consistent with erase/delete.
	device, err := simslim.FindDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	result := simslim.SimulatorMutationOutput{Action: "shutdown", UDID: udid}
	if device.State != "Booted" {
		if jsonOutput {
			return writeJSON(result)
		}
		fmt.Printf("Simulator %s is already shut down.\n", udid)
		return nil
	}

	tctx, cancel := context.WithTimeout(ctx, simslim.ShutdownTimeout)
	defer cancel()
	if err := simslim.Shutdown(tctx, device.Set, udid); err != nil {
		return err
	}
	if err := simslim.WaitShutdown(tctx, device.Set, udid, simslim.ShutdownTimeout); err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Shut down %s.\n", udid)
	return nil
}

func cmdOn(ctx context.Context, cmd *cli.Command) error {
	preserveBootState := cmd.Bool("preserve-boot-state")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}

	p, err := simslim.BuildProfile(cmd.String("profile"), cmd.String("except"), cmd.String("keep"))
	if err != nil {
		return err
	}
	// Resolve once: this pins the device's set (routing every simctl call below,
	// including a parallel-testing clone), fails fast on an unknown UDID, and
	// tells us whether to restore a shutdown state afterward.
	device, err := simslim.FindDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	originallyShutdown := preserveBootState && device.State == "Shutdown"

	fmt.Fprintf(os.Stderr, "Slimming %s: disabling %d background services. The simulator will reboot to apply the changes.\n", udid, len(p.Desired()))
	report := simslim.Reporter(func(msg string) { fmt.Fprintln(os.Stderr, msg) })
	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	changed, operationErr := simslim.EnableSlim(tctx, device.Set, udid, p, report)
	if originallyShutdown {
		shutdownErr := returnToShutdown(ctx, device.Set, udid)
		if operationErr != nil && shutdownErr != nil {
			return fmt.Errorf("%v; additionally could not restore original shutdown state: %w", operationErr, shutdownErr)
		}
		if shutdownErr != nil {
			return shutdownErr
		}
	}
	if operationErr != nil {
		return operationErr
	}
	if changed {
		if originallyShutdown {
			fmt.Println("Done. Simulator reconfigured slim and returned to shutdown.")
		} else {
			fmt.Println("Done. Simulator reconfigured and rebooted slim.")
		}
	} else {
		if originallyShutdown {
			fmt.Println("Already slim. Original shutdown state restored.")
		} else {
			fmt.Println("Already slim. Nothing to change.")
		}
	}
	return nil
}

func cmdOff(ctx context.Context, cmd *cli.Command) error {
	preserveBootState := cmd.Bool("preserve-boot-state")
	udid, err := oneUDID(cmd.Args().Slice())
	if err != nil {
		return err
	}
	device, err := simslim.FindDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	originallyShutdown := preserveBootState && device.State == "Shutdown"
	fmt.Fprintf(os.Stderr, "Restoring %s to stock. The simulator will reboot to apply the changes.\n", udid)
	report := simslim.Reporter(func(msg string) { fmt.Fprintln(os.Stderr, msg) })
	tctx, cancel := context.WithTimeout(ctx, simslim.BootTimeout)
	defer cancel()
	changed, operationErr := simslim.DisableSlim(tctx, device.Set, udid, report)
	if originallyShutdown {
		shutdownErr := returnToShutdown(ctx, device.Set, udid)
		if operationErr != nil && shutdownErr != nil {
			return fmt.Errorf("%v; additionally could not restore original shutdown state: %w", operationErr, shutdownErr)
		}
		if shutdownErr != nil {
			return shutdownErr
		}
	}
	if operationErr != nil {
		return operationErr
	}
	if changed {
		if originallyShutdown {
			fmt.Println("Done. All daemons re-enabled and simulator returned to shutdown.")
		} else {
			fmt.Println("Done. All daemons re-enabled and simulator rebooted.")
		}
	} else {
		if originallyShutdown {
			fmt.Println("Already stock. Original shutdown state restored.")
		} else {
			fmt.Println("Already stock. Nothing to change.")
		}
	}
	return nil
}

func returnToShutdown(ctx context.Context, set, udid string) error {
	shutdownCtx, cancel := context.WithTimeout(ctx, simslim.ShutdownTimeout)
	defer cancel()
	if err := simslim.Shutdown(shutdownCtx, set, udid); err != nil {
		return fmt.Errorf("restore original shutdown state: %w", err)
	}
	if err := simslim.WaitShutdown(shutdownCtx, set, udid, simslim.ShutdownTimeout); err != nil {
		return fmt.Errorf("restore original shutdown state: %w", err)
	}
	return nil
}

func oneUDID(args []string) (string, error) {
	if len(args) != 1 {
		return "", fmt.Errorf("expected exactly one simulator UDID (see `simslim list`)")
	}
	return args[0], nil
}

func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	if n <= 1 {
		return "…"
	}
	return string(runes[:n-1]) + "…"
}

func humanBytes(b int64) string {
	switch {
	case b >= 1<<30:
		return fmt.Sprintf("%.2f GB", float64(b)/(1<<30))
	case b >= 1<<20:
		return fmt.Sprintf("%.0f MB", float64(b)/(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(b)/(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, "simslim: "+msg)
	os.Exit(1)
}

func usage() {
	fmt.Print(`simslim runs more iOS simulators on the same Mac by disabling the
background daemons a simulator does not need.

USAGE
  simslim <command> [args]

GLOBAL OPTIONS
  --set <name|path>    Also scan these device sets (comma-separated). The default
                       and Xcode ` + "`testing`" + ` (parallel-testing) sets are always
                       scanned; use this to add a set at a custom path.

COMMANDS
  list                 List available simulators and their slim status
  profiles [id]        Show the daemon categories a slim boot disables;
                       pass a category ID to list that category's daemons
  profile [path]       Interactively build a --profile JSON file (writes to
                       path or into a directory, or stdout when omitted)
  on <udid>            Slim a simulator (persist disables + reboot slim)
      --profile path   Apply a committed JSON profile (see below); mutually
                       exclusive with --except/--keep
      --except ids     Leave these categories enabled (comma-separated)
      --keep labels    Keep these individual daemons running (comma-separated)
      --preserve-boot-state
                       Return an initially shutdown simulator to shutdown
  off <udid>           Restore a simulator to stock (re-enable + reboot)
      --preserve-boot-state
                       Return an initially shutdown simulator to shutdown
  status <udid>        Report how slim a booted simulator is
      --dropped        Also list the disabled daemons grouped by category
  doctor <udid>        Check required features against a booted simulator;
                       exits non-zero if slimming has broken any of them
      --requires ids   Comma-separated feature IDs to verify
      --list           List every checkable feature and its daemons
  measure <udid>       Report a booted simulator's memory footprint
  size <udid>          Report a simulator's allocated disk footprint
  disk-categories      Show cleanup and protected system-asset categories
  disk-plan <udid>     Measure reclaimable and stored data without deleting
  disk-clean <udid>    Permanently delete selected per-device data
      --categories ids Comma-separated cleanable category IDs
      --confirm        Required acknowledgement of permanent deletion
      --preserve-boot-state
                       Reboot a simulator that was booted before cleanup
  clone <udid> <name>  Clone a simulator, preserving its current boot state
  rename <udid> <name> Rename a simulator
  boot <udid>          Boot a simulator and wait for its services
  shutdown <udid>      Shut down a booted simulator
  erase <udid>         Erase a simulator's apps, data, and settings
  delete <udid>        Permanently delete a simulator
      --json           Print machine-readable JSON (also supported by list,
                       profiles, status, and simulator-management commands)
  version              Print the version

Disabling is persistent (stored in the simulator's launchd overrides) and fully
reversible with ` + "`simslim off`" + `. Deadlock-prone daemons are never touched.

A ` + "`--profile`" + ` file is JSON you commit alongside your project and apply per run
(for example a ci.json and a dev.json). Its "except" and "keep" arrays match the
flags of the same name:

  { "name": "ci", "except": ["search", "store"], "keep": ["com.apple.apsd"] }

Cleanup permanently removes existing cache, log, diagnostic, and temporary-file
contents; Erase does not bring that history back, although new generated data
appears as iOS and apps run. Downloaded language data is opt-in and may return
when a feature needs it. Required Siri assets are informational only because iOS
restores them after deletion. simslim never modifies the shared iOS runtime.

  https://github.com/mobai-app/simslim · by MobAI (https://mobai.run)
`)
}

// writeJSON renders the machine-readable output the GUI and other integrations
// decode. It goes to stdout; progress chatter goes to stderr.
func writeJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}
