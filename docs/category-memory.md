# Category memory estimates

The GUI's category values estimate the extra idle `phys_footprint` retained
when a category is kept enabled. They are guidance for choosing a profile, not
memory budgets or guarantees.

## Method

- Runtime: iOS 26.5
- Device: one otherwise idle simulator with no test app workload
- Baseline: a fully slim clean boot, median of five samples after a 20-second settle
- Category run: a clean boot with only that category kept enabled, median of
  three samples after a 15-second settle
- Measurement: `simslim measure`, which sums process `phys_footprint`

The final fully slim baseline was 1,113.4 MiB. Category estimates are each
category run's median minus that baseline, rounded to a useful GUI value.

| Category | Measured delta | GUI estimate |
|---|---:|---:|
| Widgets & Wallpaper | 674.7 MiB | 675 MB |
| Siri & Intelligence | 266.7 MiB | 265 MB |
| Spotlight & Search | 50.2 MiB | 50 MB |
| iCloud & Apple Account | 98.6 MiB | 100 MB |
| App Store, Push & Media | 80.1 MiB | 80 MB |
| Mail, Calendar & Contacts | 78.1 MiB | 80 MB |
| Safari Sync & Web Services | 49.9 MiB | 50 MB |
| Family & Screen Time | 63.0 MiB | 65 MB |
| Health, Home & Fitness | 132.7 MiB | 135 MB |
| Photos & Media Analysis | 57.9 MiB | 60 MB |
| News, Weather, Maps & Games | 88.1 MiB | 90 MB |
| Messaging & FaceTime | 60.2 MiB | 60 MB |
| Sharing & Device Connectivity | 83.6 MiB | 85 MB |
| Ads, Diagnostics & Telemetry | 106.0 MiB | 105 MB |
| Other Background Services | 194.0 MiB | 195 MB |

These deltas are not additive. Services share caches and dependencies, and
their footprint changes with simulator runtime, boot age, installed apps, and
active workload.
