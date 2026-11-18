// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

/// `simslim --help`.
let usageText = """
  simslim runs more iOS, tvOS, watchOS, and visionOS simulators on the same Mac by disabling the
  background daemons a simulator does not need.

  USAGE
    simslim <command> [args]

  GLOBAL OPTIONS
    --set <name|path>    Also scan these device sets (comma-separated). The default
                         and Xcode `testing` (parallel-testing) sets are always
                         scanned; use this to add a set at a custom path.
    --boot-timeout dur   Max time to boot and reconfigure a simulator (default 10m;
                         e.g. `15m`). Raise it for slow CI runners. Also settable
                         via the SIMSLIM_BOOT_TIMEOUT environment variable.
    --spawn-timeout dur  Max time for a single launchctl transition inside the
                         simulator (default 2m). Raise it for hosts where a busy
                         first boot makes individual spawns very slow. Also
                         settable via the SIMSLIM_SPAWN_TIMEOUT environment
                         variable.

  COMMANDS
    list                 List available simulators and their slim status
        --booted         Only list booted simulators
    profiles [id]        Show the daemon categories a slim boot disables;
                         pass a category ID to list that category's daemons
    profile [path]       Interactively build a --profile JSON file (writes to
                         path or into a directory, or stdout when omitted)
    on <udid>            Slim a simulator (persist disables + reboot slim)
        --profile path   Apply a committed JSON profile (see below); mutually
                         exclusive with --except/--keep
        --except ids     Leave these categories enabled (comma-separated)
        --keep labels    Keep these individual daemons running (comma-separated)
        --no-reboot      Stop the daemons in the current boot session without a
                         reboot. Works on every runtime, including iOS 17.x and
                         18.3, where it is the only way to slim; there the state
                         is gone at the next reboot
        --preserve-boot-state
                         Return an initially shutdown simulator to shutdown
    off <udid>           Restore a simulator to stock (re-enable + reboot)
        --preserve-boot-state
                         Return an initially shutdown simulator to shutdown
    enable <udid> <ids>  Re-enable categories or individual daemons on a booted
                         simulator now, without a reboot. IDs are category IDs
                         or launchd labels, comma- or space-separated. Like
                         `on --no-reboot`, it lasts until the next `on` or `watch`
                         pass applies its profile again
        --save path      Also add them to this profile file ("except" for a
                         category, "keep" for a daemon), creating it from the
                         default profile if needed; on a simulator that is not
                         booted, only the file changes
    disable <udid> <ids> Stop categories or daemons on a booted simulator now,
                         without a reboot. A daemon shared with another category
                         that is fully enabled keeps running. To go back to a
                         profile, run `on <udid> --no-reboot --profile path`
        --save path      Also remove them from this profile file
    watch                Slim every simulator until Ctrl-C: a shut-down one before
                         it boots (iOS/tvOS 18.5+, watchOS 11.5+, visionOS 2.5+),
                         so even its first boot starts none of the profile's
                         daemons, and every one no-reboot as it boots. The hook
                         for xcodebuild parallel-testing clones, which are
                         created stock and deleted per run; point --set at the
                         parallel-testing device set
        --profile path   Apply a committed JSON profile (see below); mutually
                         exclusive with --except/--keep
        --except ids     Leave these categories enabled (comma-separated)
        --keep labels    Keep these individual daemons running (comma-separated)
        --interval dur   How often to rescan for booting simulators (default 3s)
        --json           One JSON object per event on stdout, a stable interface
                         for wrappers: wait for "slimmed" after a boot before
                         enabling services on it
    status <udid>        Report how slim a booted simulator is
        --dropped        Also list the disabled daemons grouped by category
    verify <udid>        Check that a booted simulator's disable overrides still
                         match a profile exactly; exits non-zero and lists the
                         drift otherwise. Catches a silently stock recreated or
                         erased device; re-run `on` to repair
        --profile path   Verify against a committed JSON profile; mutually
                         exclusive with --except/--keep
        --except ids     The profile's enabled categories (comma-separated)
        --keep labels    The profile's kept daemons (comma-separated)
    doctor <udid>        Check required features against a booted simulator;
                         exits non-zero if slimming has broken any of them
        --requires ids   Comma-separated feature IDs to verify
        --list           List every checkable feature and its daemons
    measure <udid>       Report a booted simulator's memory footprint
    top [udid]           Live fleet monitor: booted simulators and their RAM,
                         CPU, and process counts. Enter a row to drill into a
                         simulator's per-daemon footprint. Pass a UDID to open
                         that drill-down directly. --json prints a one-shot snapshot
    size <udid>          Report a simulator's allocated disk footprint
    disk-categories      Show cleanup and protected system-asset categories
    disk-plan <udid>     Measure reclaimable and stored data without deleting
    disk-clean <udid>    Permanently delete selected per-device data
        --categories ids Comma-separated cleanable category IDs
        --confirm        Required acknowledgement of permanent deletion
        --preserve-boot-state
                         Reboot a simulator that was booted before cleanup
    clone <udid> <name>  Clone apps, data, settings, and the service profile
    repair-clone <source-udid> <clone-udid>
                         Repair source-bound state in an existing clone
    rename <udid> <name> Rename a simulator
    boot <udid>          Boot a simulator and wait for its services
    shutdown <udid>      Shut down a booted simulator
    erase <udid>         Erase a simulator's apps, data, and settings
    delete <udid>        Permanently delete a simulator
        --json           Print machine-readable JSON (also supported by list,
                         profiles, status, verify, doctor, enable, disable, and
                         simulator-management commands)
    version              Print the version

  Disabling is persistent (stored in the simulator's launchd overrides) and fully
  reversible with `simslim off`. Deadlock-prone daemons are never touched.
  `simslim enable` and `simslim disable` change a booted simulator live and keep
  no state; with --save they also edit a profile, the only record of a slim
  simulator, which `on`, `watch`, and `verify` read back.

  A `--profile` file is JSON you commit alongside your project and apply per run
  (for example a ci.json and a dev.json). Its "except" and "keep" arrays match the
  flags of the same name:

    { "name": "ci", "except": ["search", "store"], "keep": ["com.apple.apsd"] }

  Cleanup permanently removes existing cache, log, diagnostic, and temporary-file
  contents; Erase does not bring that history back, although new generated data
  appears as iOS and apps run. Downloaded language data is opt-in and may return
  when a feature needs it. Required Siri assets are informational only because iOS
  restores them after deletion. simslim never modifies the shared iOS runtime.

    https://github.com/mobai-app/simslim · by MobAI (https://mobai.run)

  """
