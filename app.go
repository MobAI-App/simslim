package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	cli "github.com/urfave/cli/v3"
)

// newApp builds the command tree. It handles subcommand dispatch, the global
// --set flag, and per-command flag parsing.
func newApp() *cli.Command {
	jsonFlag := func() cli.Flag {
		return &cli.BoolFlag{Name: "json", Usage: "print machine-readable JSON", OnlyOnce: true}
	}
	preserveBootStateFlag := func(usage string) cli.Flag {
		return &cli.BoolFlag{Name: "preserve-boot-state", Usage: usage}
	}

	commands := []*cli.Command{
		{Name: "list", Flags: []cli.Flag{jsonFlag()}, Action: cmdList},
		{Name: "profiles", Flags: []cli.Flag{jsonFlag()}, Action: cmdProfiles},
		{Name: "profile", Action: cmdNewProfile},
		{Name: "status", Flags: []cli.Flag{jsonFlag(), &cli.BoolFlag{Name: "dropped", Usage: "list the disabled daemons grouped by category"}}, Action: cmdStatus},
		{Name: "doctor", Flags: []cli.Flag{
			jsonFlag(),
			&cli.StringFlag{Name: "requires", Usage: "comma-separated feature IDs the simulator must support (see `simslim doctor --list`)"},
			&cli.BoolFlag{Name: "list", Usage: "list every checkable feature and its backing daemons"},
		}, Action: cmdDoctor},
		{Name: "measure", Flags: []cli.Flag{jsonFlag()}, Action: cmdMeasure},
		{Name: "size", Flags: []cli.Flag{jsonFlag()}, Action: cmdSize},
		{Name: "disk-categories", Flags: []cli.Flag{jsonFlag()}, Action: cmdDiskCategories},
		{Name: "disk-plan", Flags: []cli.Flag{jsonFlag()}, Action: cmdDiskPlan},
		{Name: "disk-clean", Flags: []cli.Flag{
			jsonFlag(),
			&cli.StringFlag{Name: "categories", Usage: "comma-separated cleanable disk category IDs"},
			&cli.BoolFlag{Name: "confirm", Usage: "confirm permanent deletion"},
			preserveBootStateFlag("reboot a simulator that was booted before cleanup"),
		}, Action: cmdDiskClean},
		{Name: "clone", Flags: []cli.Flag{jsonFlag()}, Action: cmdClone},
		{Name: "rename", Flags: []cli.Flag{jsonFlag()}, Action: cmdRename},
		{Name: "boot", Flags: []cli.Flag{jsonFlag()}, Action: cmdBoot},
		{Name: "shutdown", Flags: []cli.Flag{jsonFlag()}, Action: cmdShutdown},
		{Name: "erase", Flags: []cli.Flag{jsonFlag()}, Action: cmdErase},
		{Name: "delete", Flags: []cli.Flag{jsonFlag()}, Action: cmdDelete},
		{Name: "on", Flags: []cli.Flag{
			&cli.StringFlag{Name: "profile", Usage: "apply a JSON profile file (mutually exclusive with --except/--keep)"},
			&cli.StringFlag{Name: "except", Usage: "comma-separated category IDs to leave fully enabled (see `simslim profiles`)"},
			&cli.StringFlag{Name: "keep", Usage: "comma-separated launchd labels to keep running"},
			preserveBootStateFlag("return an initially shutdown simulator to shutdown after reconfiguration"),
		}, Action: cmdOn},
		{Name: "off", Flags: []cli.Flag{
			preserveBootStateFlag("return an initially shutdown simulator to shutdown after reconfiguration"),
		}, Action: cmdOff},
	}

	onUsageError := func(_ context.Context, _ *cli.Command, err error, _ bool) error {
		if err != nil && strings.Contains(err.Error(), "flag needs an argument: --set") {
			return fmt.Errorf("--set requires a device set name (such as `testing`) or a path")
		}
		return err
	}
	for _, c := range commands {
		c.OnUsageError = onUsageError
	}

	return &cli.Command{
		Name:         "simslim",
		HideHelp:     true, // root help/usage is handled by main's usage()
		HideVersion:  true, // version output is handled by main
		OnUsageError: onUsageError,
		Flags: []cli.Flag{
			&cli.StringFlag{
				Name:  "set",
				Usage: "also scan these device sets (comma-separated name|path)",
				Action: func(_ context.Context, _ *cli.Command, value string) error {
					sets := splitList(value)
					if len(sets) == 0 {
						return fmt.Errorf("--set requires a device set name (such as `testing`) or a path")
					}
					for _, set := range sets {
						registerDeviceSet(set)
					}
					return nil
				},
			},
		},
		Action: func(_ context.Context, cmd *cli.Command) error {
			if args := cmd.Args().Slice(); len(args) > 0 {
				fmt.Fprintf(os.Stderr, "unknown command %q\n\n", args[0])
			}
			usage()
			os.Exit(2)
			return nil
		},
		ExitErrHandler: func(_ context.Context, _ *cli.Command, _ error) {},
		Commands:       commands,
	}
}
