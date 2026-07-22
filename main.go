package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"sort"
	"strings"
	"time"
)

// version is overwritten at build time via -ldflags "-X main.version=...".
var version = "dev"

const (
	shutdownTimeout = 30 * time.Second
	bootTimeout     = 6 * time.Minute // a first slim reconfigure boots twice
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	args, err := extractDeviceSets(os.Args[1:])
	if err != nil {
		fatal(err.Error())
	}
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}

	switch args[0] {
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

	switch args[0] {
	case "list":
		err = cmdList(ctx, args[1:])
	case "profiles":
		err = cmdProfiles(args[1:])
	case "status":
		err = cmdStatus(ctx, args[1:])
	case "measure":
		err = cmdMeasure(ctx, args[1:])
	case "size":
		err = cmdSize(ctx, args[1:])
	case "disk-categories":
		err = cmdDiskCategories(args[1:])
	case "disk-plan":
		err = cmdDiskPlan(ctx, args[1:])
	case "disk-clean":
		err = cmdDiskClean(ctx, args[1:])
	case "clone":
		err = cmdClone(ctx, args[1:])
	case "rename":
		err = cmdRename(ctx, args[1:])
	case "boot":
		err = cmdBoot(ctx, args[1:])
	case "shutdown":
		err = cmdShutdown(ctx, args[1:])
	case "erase":
		err = cmdErase(ctx, args[1:])
	case "delete":
		err = cmdDelete(ctx, args[1:])
	case "on":
		err = cmdOn(ctx, args[1:])
	case "off":
		err = cmdOff(ctx, args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", args[0])
		usage()
		os.Exit(2)
	}
	if err != nil {
		fatal(err.Error())
	}
}

// extractDeviceSets pulls the global --set flag (`--set value` or `--set=value`)
// out of args and returns the remaining arguments, so the subcommand never sees
// it. Each --set value is a comma-separated list of sets to scan; like the other
// list flags, a repeated --set is last-wins rather than accumulated. Arguments
// after a `--` terminator are passed through untouched, so a literal argument is
// never mistaken for the flag.
func extractDeviceSets(args []string) ([]string, error) {
	remaining := make([]string, 0, len(args))
	value := ""
	seen := false
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			remaining = append(remaining, args[i:]...)
			break
		}
		v, isSet := strings.CutPrefix(arg, "--set=")
		if !isSet {
			if arg != "--set" {
				remaining = append(remaining, arg)
				continue
			}
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--set requires a device set name (such as `testing`) or a path")
			}
			i++
			v = args[i]
		}
		value, seen = v, true
	}
	if seen {
		sets := splitList(value)
		if len(sets) == 0 {
			return nil, fmt.Errorf("--set requires a device set name (such as `testing`) or a path")
		}
		for _, set := range sets {
			registerDeviceSet(set)
		}
	}
	return remaining, nil
}

func cmdList(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	if len(args) != 0 {
		return fmt.Errorf("list takes no arguments")
	}
	devices, err := listDevices(ctx)
	if err != nil {
		return err
	}
	sort.Slice(devices, func(i, j int) bool {
		if devices[i].OSVersion != devices[j].OSVersion {
			return devices[i].OSVersion > devices[j].OSVersion
		}
		return devices[i].Name < devices[j].Name
	})
	managed := len(slimmableSet())
	memoryByUDID := map[string]Measurement{}
	memoryErrors := map[string]string{}
	if jsonOutput {
		bootedUDIDs := make([]string, 0)
		for _, device := range devices {
			if device.State == "Booted" {
				bootedUDIDs = append(bootedUDIDs, device.UDID)
			}
		}
		memoryByUDID, memoryErrors = measureMany(ctx, bootedUDIDs)
	}
	summaries := make([]DeviceSummary, 0, len(devices))
	for _, d := range devices {
		tag := "shutdown"
		summary := DeviceSummary{Device: d, ManagedTotal: managed}
		if d.State == "Booted" {
			tag = "booted"
			if measurement, ok := memoryByUDID[d.UDID]; ok {
				measured := measurement
				summary.Memory = &measured
			}
			summary.MemoryError = memoryErrors[d.UDID]
			if st, _, err := statusForDevice(ctx, d); err == nil {
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

func cmdProfiles(args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	if len(args) > 1 {
		return fmt.Errorf("profiles takes at most one category ID (see `simslim profiles`)")
	}
	if len(args) == 1 {
		c, ok := categoryByID(args[0])
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
		return writeJSON(Categories)
	}
	for _, c := range Categories {
		fmt.Printf("%-14s %s\n", c.ID, c.Name)
		fmt.Printf("               %d daemons · ~%d MB idle footprint when enabled\n", len(c.Labels), c.ApproxMemoryMB)
		fmt.Printf("               When disabled: %s\n", c.Downside)
		for _, service := range c.AlwaysEnabled {
			fmt.Printf("               Always on: %s — %s\n", service.Label, service.Reason)
		}
	}
	fmt.Printf("\n%d daemons across %d categories. Core workflow and deadlock-prone daemons are never disabled.\n",
		len(slimmableSet()), len(Categories))
	fmt.Println("Memory estimates are iOS 26.5 clean-boot measurements; they vary by runtime and workload and are not additive.")
	return nil
}

func cmdStatus(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	showDropped := fs.Bool("dropped", false, "list the disabled daemons grouped by category")
	if err := parseInterspersedFlags(fs, args); err != nil {
		return err
	}
	udid, err := oneUDID(fs.Args())
	if err != nil {
		return err
	}
	st, disabled, err := status(ctx, udid)
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
	var dropped []DroppedCategory
	if *showDropped {
		dropped = droppedCategories(disabled)
	}
	if jsonOutput {
		return writeJSON(StatusOutput{Status: st, Verdict: verdict, Dropped: dropped})
	}
	fmt.Printf("%s: %d/%d managed daemons disabled (%s)\n", udid, st.ManagedDisabled, st.ManagedTotal, verdict)
	if *showDropped {
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

func cmdMeasure(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}
	m, err := measure(ctx, udid)
	if err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(m)
	}
	fmt.Printf("%s: %d processes, %s memory footprint\n", udid, m.Processes, humanBytes(m.Bytes))
	return nil
}

func cmdSize(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}
	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	measurement, err := deviceDiskUsage(tctx, udid)
	if err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(measurement)
	}
	fmt.Printf("%s: %s on disk\n", udid, humanBytes(measurement.Bytes))
	return nil
}

func cmdDiskCategories(args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	if len(args) != 0 {
		return fmt.Errorf("disk-categories takes no arguments")
	}
	if jsonOutput {
		return writeJSON(DiskCleanupCategories)
	}
	for _, category := range DiskCleanupCategories {
		availability := "cleanable"
		if !category.CanClean {
			availability = "measured only"
		}
		fmt.Printf("%-22s %-28s %s · %s\n", category.ID, category.Name, category.Risk, availability)
		fmt.Printf("                       %s\n", category.Downside)
	}
	return nil
}

func cmdDiskPlan(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}
	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	plan, err := diskCleanupPlan(tctx, udid)
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

func cmdDiskClean(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	fs := flag.NewFlagSet("disk-clean", flag.ContinueOnError)
	categories := fs.String("categories", "", "comma-separated cleanable disk category IDs")
	confirmed := fs.Bool("confirm", false, "confirm permanent deletion")
	preserveBootState := fs.Bool("preserve-boot-state", false, "reboot a simulator that was booted before cleanup")
	if err := parseInterspersedFlags(fs, args); err != nil {
		return err
	}
	udid, err := oneUDID(fs.Args())
	if err != nil {
		return err
	}
	if !*confirmed {
		return fmt.Errorf("disk-clean permanently deletes data; pass --confirm after reviewing `simslim disk-plan %s`", udid)
	}
	categoryIDs := splitList(*categories)
	if _, err := validateDiskCleanupSelection(categoryIDs); err != nil {
		return err
	}
	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	result, err := cleanDeviceDisk(tctx, udid, categoryIDs, *preserveBootState)
	if err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Cleaned %s and reclaimed %s. Generated contents stay deleted; on-demand assets may download again when needed.\n", udid, humanBytes(result.ReclaimedBytes))
	return nil
}

func cmdClone(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	if len(args) != 2 {
		return fmt.Errorf("clone expects a simulator UDID and a new name")
	}
	name, err := normalizeSimulatorName(args[1])
	if err != nil {
		return err
	}

	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	newUDID, err := cloneDevice(tctx, args[0], name)
	if err != nil {
		return err
	}
	result := SimulatorMutationOutput{Action: "clone", UDID: newUDID, Name: name, SourceUDID: args[0]}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Cloned %s as %q (%s).\n", args[0], name, newUDID)
	return nil
}

func cmdRename(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	if len(args) != 2 {
		return fmt.Errorf("rename expects a simulator UDID and a new name")
	}
	name, err := normalizeSimulatorName(args[1])
	if err != nil {
		return err
	}

	tctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()
	if err := renameDevice(tctx, args[0], name); err != nil {
		return err
	}
	result := SimulatorMutationOutput{Action: "rename", UDID: args[0], Name: name}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Renamed %s to %q.\n", args[0], name)
	return nil
}

func cmdErase(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}

	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	if err := eraseDevice(tctx, udid); err != nil {
		return err
	}
	result := SimulatorMutationOutput{Action: "erase", UDID: udid}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Erased simulator %s.\n", udid)
	return nil
}

func cmdDelete(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}

	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	if err := deleteDevice(tctx, udid); err != nil {
		return err
	}
	result := SimulatorMutationOutput{Action: "delete", UDID: udid}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Deleted simulator %s.\n", udid)
	return nil
}

func cmdBoot(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}

	// Resolve the exact device first so a simctl alias such as "all" can never
	// enter the boot path, consistent with erase/delete.
	device, err := findDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	result := SimulatorMutationOutput{Action: "boot", UDID: udid}
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
	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	if err := bootAndWait(tctx, device.Set, udid); err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Booted %s.\n", udid)
	return nil
}

func cmdShutdown(ctx context.Context, args []string) error {
	jsonOutput, args, err := jsonOption(args)
	if err != nil {
		return err
	}
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}

	// Resolve the exact device first so a simctl alias such as "all" can never
	// enter the shutdown path, consistent with erase/delete.
	device, err := findDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	result := SimulatorMutationOutput{Action: "shutdown", UDID: udid}
	if device.State != "Booted" {
		if jsonOutput {
			return writeJSON(result)
		}
		fmt.Printf("Simulator %s is already shut down.\n", udid)
		return nil
	}

	tctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()
	if err := shutdown(tctx, device.Set, udid); err != nil {
		return err
	}
	if err := waitShutdown(tctx, device.Set, udid, shutdownTimeout); err != nil {
		return err
	}
	if jsonOutput {
		return writeJSON(result)
	}
	fmt.Printf("Shut down %s.\n", udid)
	return nil
}

func cmdOn(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("on", flag.ContinueOnError)
	except := fs.String("except", "", "comma-separated category IDs to leave fully enabled (see `simslim profiles`)")
	keep := fs.String("keep", "", "comma-separated launchd labels to keep running")
	preserveBootState := fs.Bool("preserve-boot-state", false, "return a shutdown simulator to shutdown after reconfiguration")
	if err := parseInterspersedFlags(fs, args); err != nil {
		return err
	}
	udid, err := oneUDID(fs.Args())
	if err != nil {
		return err
	}
	// Resolve once: this pins the device's set (routing every simctl call below,
	// including a parallel-testing clone), fails fast on an unknown UDID, and
	// tells us whether to restore a shutdown state afterward.
	device, err := findDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	originallyShutdown := *preserveBootState && device.State == "Shutdown"

	p := Profile{ExceptCategories: map[string]bool{}, Keep: map[string]bool{}}
	for _, id := range splitList(*except) {
		if _, ok := categoryByID(id); !ok {
			return fmt.Errorf("unknown category %q (see `simslim profiles`)", id)
		}
		p.ExceptCategories[id] = true
	}
	for _, l := range splitList(*keep) {
		p.Keep[l] = true
	}

	fmt.Fprintf(os.Stderr, "Slimming %s: disabling %d background services. The simulator will reboot to apply the changes.\n", udid, len(p.desired()))
	report := reporter(func(msg string) { fmt.Fprintln(os.Stderr, msg) })
	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	changed, operationErr := enableSlim(tctx, device.Set, udid, p, report)
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

func cmdOff(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("off", flag.ContinueOnError)
	preserveBootState := fs.Bool("preserve-boot-state", false, "return a shutdown simulator to shutdown after reconfiguration")
	if err := parseInterspersedFlags(fs, args); err != nil {
		return err
	}
	udid, err := oneUDID(fs.Args())
	if err != nil {
		return err
	}
	device, err := findDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	originallyShutdown := *preserveBootState && device.State == "Shutdown"
	fmt.Fprintf(os.Stderr, "Restoring %s to stock. The simulator will reboot to apply the changes.\n", udid)
	report := reporter(func(msg string) { fmt.Fprintln(os.Stderr, msg) })
	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	changed, operationErr := disableSlim(tctx, device.Set, udid, report)
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
	shutdownCtx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()
	if err := shutdown(shutdownCtx, set, udid); err != nil {
		return fmt.Errorf("restore original shutdown state: %w", err)
	}
	if err := waitShutdown(shutdownCtx, set, udid, shutdownTimeout); err != nil {
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

// parseInterspersedFlags accepts options before or after positional arguments.
// The standard flag package stops at the first positional argument, which is
// surprising for documented forms such as `simslim on <udid> --except search`.
func parseInterspersedFlags(fs *flag.FlagSet, args []string) error {
	var optionArgs []string
	var positionalArgs []string
	optionsEnabled := true

	for i := 0; i < len(args); i++ {
		arg := args[i]
		if optionsEnabled && arg == "--" {
			optionsEnabled = false
			continue
		}
		if !optionsEnabled || arg == "-" || !strings.HasPrefix(arg, "-") {
			positionalArgs = append(positionalArgs, arg)
			continue
		}

		optionArgs = append(optionArgs, arg)
		nameAndValue := strings.TrimLeft(arg, "-")
		name, _, hasInlineValue := strings.Cut(nameAndValue, "=")
		registered := fs.Lookup(name)
		if registered == nil || hasInlineValue {
			continue
		}
		if boolFlag, ok := registered.Value.(interface{ IsBoolFlag() bool }); ok && boolFlag.IsBoolFlag() {
			continue
		}
		if i+1 < len(args) {
			i++
			optionArgs = append(optionArgs, args[i])
		}
	}

	return fs.Parse(append(optionArgs, positionalArgs...))
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
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
  on <udid>            Slim a simulator (persist disables + reboot slim)
      --except ids     Leave these categories enabled (comma-separated)
      --keep labels    Keep these individual daemons running (comma-separated)
      --preserve-boot-state
                       Return an initially shutdown simulator to shutdown
  off <udid>           Restore a simulator to stock (re-enable + reboot)
      --preserve-boot-state
                       Return an initially shutdown simulator to shutdown
  status <udid>        Report how slim a booted simulator is
      --dropped        Also list the disabled daemons grouped by category
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

Cleanup permanently removes existing cache, log, diagnostic, and temporary-file
contents; Erase does not bring that history back, although new generated data
appears as iOS and apps run. Downloaded language data is opt-in and may return
when a feature needs it. Required Siri assets are informational only because iOS
restores them after deletion. simslim never modifies the shared iOS runtime.

  https://github.com/mobai-app/simslim · by MobAI (https://mobai.run)
`)
}
