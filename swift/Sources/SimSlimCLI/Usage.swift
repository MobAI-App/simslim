/// `simslim --help`. Commands marked † exist in the Go CLI but are not in the
/// Swift port yet.
let usageText = """
  simslim runs more iOS, tvOS, watchOS, and visionOS simulators on the same Mac by disabling the
  background daemons a simulator does not need.

  This is the Swift port. Commands marked † are not available yet.

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
    profile [path]   †   Interactively build a --profile JSON file
    on <udid>            Slim a simulator (persist disables + reboot slim)
    off <udid>           Restore a simulator to stock (re-enable + reboot)
    enable <udid> <ids>     Re-enable categories or daemons on a booted simulator now
    disable <udid> <ids>    Stop categories or daemons on a booted simulator now
    watch            †   Slim every simulator until Ctrl-C
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
    top [udid]       †   Live fleet monitor
    size <udid>      †   Report a simulator's allocated disk footprint
    disk-categories  †   Show cleanup and protected system-asset categories
    disk-plan <udid> †   Measure reclaimable and stored data without deleting
    disk-clean <udid> †  Permanently delete selected per-device data
    clone <udid> <name> †  Clone apps, data, settings, and the service profile
    repair-clone <source-udid> <clone-udid> †
    rename <udid> <name> †  Rename a simulator
    boot <udid>          Boot a simulator and wait for its services
    shutdown <udid>      Shut down a booted simulator
    erase <udid>     †   Erase a simulator's apps, data, and settings
    delete <udid>    †   Permanently delete a simulator
        --json           Print machine-readable JSON (also supported by list,
                         profiles, status, verify, doctor)
    version              Print the version

  A `--profile` file is JSON you commit alongside your project and apply per run
  (for example a ci.json and a dev.json). Its "except" and "keep" arrays match the
  flags of the same name:

    { "name": "ci", "except": ["search", "store"], "keep": ["com.apple.apsd"] }

  """
