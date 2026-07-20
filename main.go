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

	var err error
	switch os.Args[1] {
	case "list":
		err = cmdList(ctx)
	case "profiles":
		cmdProfiles()
	case "status":
		err = cmdStatus(ctx, os.Args[2:])
	case "measure":
		err = cmdMeasure(ctx, os.Args[2:])
	case "on":
		err = cmdOn(ctx, os.Args[2:])
	case "off":
		err = cmdOff(ctx, os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
	if err != nil {
		fatal(err.Error())
	}
}

func cmdList(ctx context.Context) error {
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
	managed := len(managedSet())
	for _, d := range devices {
		tag := "shutdown"
		if d.State == "Booted" {
			tag = "booted"
			if st, err := status(ctx, d.UDID); err == nil {
				tag = fmt.Sprintf("booted · %d/%d slim", st.ManagedDisabled, managed)
			}
		}
		fmt.Printf("%s  %-22s iOS %-6s %s\n", d.UDID, truncate(d.Name, 22), d.OSVersion, tag)
	}
	return nil
}

func cmdProfiles() {
	for _, c := range Categories {
		fmt.Printf("%-14s %s\n", c.ID, c.Name)
		fmt.Printf("               %d daemons: %s\n", len(c.Labels), c.Description)
	}
	fmt.Printf("\n%d daemons across %d categories. Deadlock-prone daemons are excluded and never touched.\n",
		len(managedSet()), len(Categories))
}

func cmdStatus(ctx context.Context, args []string) error {
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}
	st, err := status(ctx, udid)
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
	fmt.Printf("%s: %d/%d managed daemons disabled (%s)\n", udid, st.ManagedDisabled, st.ManagedTotal, verdict)
	return nil
}

func cmdMeasure(ctx context.Context, args []string) error {
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}
	m, err := measure(ctx, udid)
	if err != nil {
		return err
	}
	fmt.Printf("%s: %d processes, %s memory footprint\n", udid, m.Processes, humanBytes(m.Bytes))
	return nil
}

func cmdOn(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("on", flag.ExitOnError)
	except := fs.String("except", "", "comma-separated category IDs to leave fully enabled (see `simslim profiles`)")
	keep := fs.String("keep", "", "comma-separated launchd labels to keep running")
	fs.Parse(args)
	udid, err := oneUDID(fs.Args())
	if err != nil {
		return err
	}

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

	fmt.Printf("Slimming %s (disabling %d daemons)…\n", udid, len(p.desired()))
	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	changed, err := enableSlim(tctx, udid, p)
	if err != nil {
		return err
	}
	if changed {
		fmt.Println("Done. Simulator reconfigured and rebooted slim.")
	} else {
		fmt.Println("Already slim. Nothing to change.")
	}
	return nil
}

func cmdOff(ctx context.Context, args []string) error {
	udid, err := oneUDID(args)
	if err != nil {
		return err
	}
	fmt.Printf("Restoring %s to stock…\n", udid)
	tctx, cancel := context.WithTimeout(ctx, bootTimeout)
	defer cancel()
	changed, err := disableSlim(tctx, udid)
	if err != nil {
		return err
	}
	if changed {
		fmt.Println("Done. All daemons re-enabled and simulator rebooted.")
	} else {
		fmt.Println("Already stock. Nothing to change.")
	}
	return nil
}

func oneUDID(args []string) (string, error) {
	if len(args) != 1 {
		return "", fmt.Errorf("expected exactly one simulator UDID (see `simslim list`)")
	}
	return args[0], nil
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
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func humanBytes(b int64) string {
	switch {
	case b >= 1<<30:
		return fmt.Sprintf("%.2f GB", float64(b)/(1<<30))
	case b >= 1<<20:
		return fmt.Sprintf("%.0f MB", float64(b)/(1<<20))
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

COMMANDS
  list                 List available simulators and their slim status
  profiles             Show the daemon categories a slim boot disables
  on <udid>            Slim a simulator (persist disables + reboot slim)
      --except ids     Leave these categories enabled (comma-separated)
      --keep labels    Keep these individual daemons running (comma-separated)
  off <udid>           Restore a simulator to stock (re-enable + reboot)
  status <udid>        Report how slim a booted simulator is
  measure <udid>       Report a booted simulator's memory footprint
  version              Print the version

Disabling is persistent (stored in the simulator's launchd overrides) and fully
reversible with ` + "`simslim off`" + `. Deadlock-prone daemons are never touched.

  https://github.com/mobai-app/simslim · by MobAI (https://mobai.run)
`)
}
