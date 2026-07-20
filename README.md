# simslim

Run a lot more iOS simulators on one Mac by turning off the background daemons a simulator doesn't need.

A freshly booted iOS simulator starts around 180 background services: Siri, Spotlight indexing, photo analysis, News, wallpaper posters, iCloud sync, and so on. None of it matters when you're using the simulator for development, testing, or CI. simslim switches those services off, which cuts each simulator's memory roughly 4x. On the same laptop you go from a handful of simulators to a screenful.

![19 iOS simulators running at once on a 16 GB Mac](docs/simslim-19-sims.png)

*19 iOS simulators, all under automation, on a 16 GB MacBook Pro. Stock simulators start thrashing at around 5.*

## Numbers

One simulator, booted stock and then slimmed, same device and settle time (M1 Pro, 16 GB):

| | Stock | Slim |
|---|---|---|
| Processes | 258 | 70 |
| Memory | 4.0 GB | 0.9 GB |

Memory here is phys_footprint, the figure Activity Monitor shows, which counts compressed and swapped pages. That's what decides how many simulators fit before the machine starts swapping. Run `simslim measure <udid>` to see it for any booted simulator.

## Install

```sh
brew install mobai-app/tap/simslim
```

or

```sh
go install github.com/mobai-app/simslim@latest
```

macOS only, and you need Xcode's command-line tools, since it drives simulators through `simctl`.

## Usage

```sh
simslim list             # simulators and their slim status
simslim profiles         # what a slim boot turns off
simslim on <udid>        # slim a simulator and reboot it slim
simslim off <udid>       # put it back to stock
simslim status <udid>    # how slim a booted simulator is
simslim measure <udid>   # a booted simulator's memory footprint
```

Keep a category you actually need, like Spotlight search:

```sh
simslim on <udid> --except search
```

Or keep one specific daemon, like push notifications:

```sh
simslim on <udid> --keep com.apple.apsd
```

## How it works

`simslim on` writes persistent `launchctl disable` entries for the chosen daemons into the simulator's own launchd database, then reboots it. The entries stick across reboots, so the simulator comes up slim in a single boot from then on. `simslim off` clears them and reboots back to stock. Your Mac is never touched, only the simulator you point it at, and only daemons that are safe to disable (the handful that wedge a simulator when turned off are left alone).

## What you lose

Turning services off is fine for most development, UI automation, and CI, but some features genuinely stop working. The ones worth knowing:

- Spotlight and in-Settings search return nothing (`search`).
- Push notifications need `apsd`, StoreKit testing needs `storekitd` (`store`).
- Universal links need `swcd` (`web`).
- The Contacts, Photos, and Calendar pickers can act up without their categories.

`simslim profiles` lists every category, so you can keep the ones your work depends on with `--except`.

## Why

Testing is shifting. Once agents are writing apps, you want agents running them too, and the place an iOS app runs is a simulator. One agent, one simulator. So how much work you get through at once comes down to how many simulators a machine can hold, and stock simulators are heavy enough that a laptop fills up fast. Slimming them is the cheapest way to raise that ceiling: more simulators on the box means more agents working in parallel on it.

Built for [MobAI](https://mobai.run) to run more simulators on one machine.

## License

MIT, copyright Interlap.
