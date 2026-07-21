# Disk cleanup safety model

Service slimming and disk cleanup have different guarantees. Service slimming
is reversible with `simslim off`. Disk cleanup permanently removes files.

## Boundary

simslim only considers data below one exact simulator's device-data directory:

```text
~/Library/Developer/CoreSimulator/Devices/<UDID>/data
```

It never changes an iOS runtime. Apple describes a Simulator runtime as an OS
package used by multiple simulator devices, and modern runtime disk images are
kept in system-managed protected storage. Built-in apps and core OS language
resources therefore are not per-device savings and are outside simslim's
cleanup boundary.

- [Apple: Adding additional simulators](https://developer.apple.com/documentation/safari-developer-tools/adding-additional-simulators)
- [Xcode 14 release notes: system-managed Simulator runtime disk images](https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-14-release-notes)

## Current categories

| Category | Action | Main downside | Recovery |
|---|---|---|---|
| System & App Caches | Clears contents of directories named `Caches` | Slower first launch; cached/offline content disappears | Old contents are not restored by erase; new caches usually regenerate |
| Logs & Diagnostics | Clears logs, unified-log traces, and UUID text | Existing debugging and crash history disappears | Old history is not restored by erase; new logs are generated |
| Temporary Files | Clears contents of `tmp` directories | Misbehaving apps may lose in-progress work | Old contents are not restored by erase; directories remain and are reused |
| Downloaded Language Data | Opt-in; clears the exact per-device LinguisticData catalog | Search, Siri, and text analysis may be limited until needed assets return | iOS downloads the package again when a feature requests it |
| Required Siri Assets | Measured only | Manual deletion is unsupported and iOS downloads required assets again | Required assets return automatically after boot |

Apple Developer Forum reports document CoreSimulator's
`Library/Caches/com.apple.containermanagerd/Dead` cache growing unexpectedly;
it is covered by the cache category.

- [Apple Developer Forums: Core Simulator cache consuming disk space](https://developer.apple.com/forums/thread/758703)

## Recovery

There are two distinct recovery models:

1. Cleanup data such as caches, logs, diagnostics, and temporary files is
   disposable but its old contents are permanent history. `xcrun simctl erase
   <UDID>` does not bring those contents back. iOS and apps can generate new
   caches, logs, and temporary files on future boots.
2. Downloaded system-managed assets such as Siri models and language data are
   split by observed behavior. The exact LinguisticData catalog is opt-in and
   on-demand. Required Siri, speech, and voice catalogs remain informational
   because iOS automatically restores them after boot.

## Read-only storage breakdown

`disk-plan` and the app report durable storage separately from cleanup choices:

- **Installed Apps** measures app and test-runner bundles installed into that
  simulator. Built-in apps are not counted because they live in the shared
  runtime.
- **Documents** measures app and app-group `Documents` directories.
- **App Data** measures preferences, databases, and support files while
  excluding Documents and the cleanable cache, log, and temporary directories.
- **User Media** measures the simulator media library.

These rows can explain where disk space is going, but they are never selectable
for bulk deletion. Apple likewise distinguishes an app's bundle, documents, and
other data when discussing app disk usage.

- [Apple: Reducing your app's disk usage](https://developer.apple.com/documentation/xcode/reducing-your-app-s-disk-usage)
- [Apple: Files and directories](https://developer.apple.com/documentation/technologyoverviews/files-and-directories)

## Xcode 26.6 validation

The three cleanable rows were exercised on disposable simulator clones. A
combined pass reclaimed about 1.38 GB on one clone and 1.68 GB on another. In
an individual-category pass, caches reclaimed about 408 MB and logs about
177 MB. A seeded 8 MB temporary file was discovered and removed while its
`tmp` directory remained intact. Cleanup also restored the prior boot state
when requested.

The MobileAsset path was tested destructively on disposable iOS 26.5 clones,
never on source simulators. Clearing the original broad Siri and language
allowlist reclaimed about 1.43 GB. In a boot-only control with no apps opened,
the required footprint started growing about 20 seconds after boot and reached
about 1.17 GB within a minute.

The roughly 235 MiB difference was then identified at the asset-bundle level:
about 141 MiB was an English `LinguisticData` package and about 88 MiB was an
additional neural voice bundle. Removing only those two bundles survived
repeated boots, idle time, keyboard input, a normal developer-app launch,
opening Siri settings, opening the voice list, and a Siri request. Only the
LinguisticData catalog is exposed for cleanup: it has an exact stable directory
boundary and iOS can fetch it on demand. The extra voice bundle remains
protected because selecting individual voice assets would depend on private
MobileAsset catalog metadata and could leave a stale catalog.

An erased test clone also completed data migration, booted successfully, and
opened Settings normally. Erase is therefore a recovery path to a usable fresh
device, not a way to preserve or permanently remove system-managed assets.

Erase can return a damaged per-device data tree to a usable fresh state sourced
from the unchanged runtime, but it is not an undo operation. The simulator's
prior apps, settings, credentials, user data, logs, and cache contents are not
restored.

If a shared runtime were modified, erasing a device would not repair it; the
runtime would need to be reinstalled. simslim prevents that situation by never
allowing runtime paths into a cleanup plan.

## Implementation safeguards

- Exact UDIDs are resolved through `simctl`; aliases such as `all` are rejected.
- Every cleanup path is generated from a fixed category, checked to remain
  below the device's `data` directory, and rejected if the target or an
  intermediate path component resolves outside it.
- Name-based discovery skips Documents, media, and MobileAsset trees so a
  user-created folder named `Caches`, `Logs`, or `tmp` is never enough to make
  durable content eligible for cleanup.
- Downloaded language cleanup uses one exact MobileAsset catalog path; required
  Siri, speech, and voice catalogs are rejected by selection validation.
- Only directory contents are removed; required container directories remain.
- Child symlinks are unlinked without following them.
- Booted devices are shut down before cleanup.
- The CLI requires `--confirm`; the app requires the user to type `CLEAN`.
- Analysis and estimated sizes are always read-only.
