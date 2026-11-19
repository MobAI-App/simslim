// swift-format-ignore-file
// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

/// Daemons that wedge a simulator when disabled; none may ever be managed.
let forbiddenLabels: [String] = [
  "com.apple.nanoregistryd",
  "com.apple.nanoregistrylaunchd",
  "com.apple.nanoprefsyncd.2",
  "com.apple.nanotimekitcompaniond",
  "com.apple.nanobackupd",
  "com.apple.sleepd",
  "com.apple.appprotectiond",
  "com.apple.ManagedSettingsAgent",
  "com.apple.managedconfiguration.profiled",
  "com.apple.mobiletimerd",
  "com.apple.routined",
  "com.apple.biomed",
  "com.apple.biomesyncd",
  "com.apple.dmd",
  "com.apple.donotdisturbd",
]
