# OpenNotes 0.1.0 — public preview, build 36

A native notebook for iPad and iPhone, with the editing and organization improvements since public build 11 gathered into one download.

[Download the unsigned IPA](https://github.com/edouaz/OpenNotes/releases/download/v0.1.0-prototype.36/OpenNotes-build36-unsigned.ipa) · [Installation](https://edouaz.github.io/OpenNotes/develop.html#install) · [Getting started](GETTING_STARTED.md)

**iOS / iPadOS 16+ · arm64 · unsigned · not an App Store or TestFlight release.**

## Since public build 11

- Image import, paste, resizing and movement improvements; fixes to sticky-note dragging, lasso ownership and rendering during interaction.
- Native ink refinements: smoother input at zero stabilization, shape axis locking, more tolerant polygon recognition and whole-stroke scribble erasing.
- A PDF search side panel, an adaptive notebook tab bar and a cleaner editor header.
- Toolbar placement, sticky-note placement anywhere on the page and a persistent default paper style for new pages.
- Settings with battery saver and feature controls; deferred autosave during gestures and cloud sync backoff for unchanged notebooks.
- Native exports now use `.opennote`; legacy `.catnote` filenames remain accepted. Folders open from their whole row.
- Optional sync progress, revision handling, and MCP / CLI work. These connected services require separate setup and remain experimental.
- A clean checkout builds without a private Supabase plist; optional cloud configuration is added only when explicitly supplied and the project regenerated.
- Refreshed website, README, documentation index, user guide and real build 36 simulator captures under one visual identity.

## Install and upgrade

The IPA needs your own signing and provisioning, including the embedded share extension and matching App Group entitlements. Building with Xcode is also supported. Keep the same team, bundle identifiers and App Group when updating an existing installation. **Export a native backup and PDF first; do not uninstall before backing up.**

Older PencilKit pages, including build 9, are unsupported by the native ink engine. Export those notes using their original app before upgrading. A recognized `.catnote` filename does not imply conversion of its old drawing data. Existing native ink schema 1 is readable; schema-2 writes preserve an original schema-1 backup before the first overwrite. Do not downgrade schema-2 notes to an older build.

Local notebooks work without an account or backend. The source build ships no private cloud credentials. Optional synchronization and MCP deployment are described separately in [Supabase](SUPABASE.md) and [MCP](MCP.md).

## Validation

The full iOS run passed **320 XCTest tests and 6 Swift Testing tests**, with one optional cloud-configuration test skipped. The **59 MCP tests** and **5 isolated shape-recognition tests** also passed.

The [release manifest](release-build36.json) records the exact artifact hash, size, app/extension versions and completed checks. Screenshots come from the dedicated `ReleaseShowcaseTests/testPublicPreviewTour` UI test; [capture provenance](SCREENSHOTS.md) includes the reproduction command.

Physical Apple Pencil latency and pressure calibration, older-device memory/performance, full accessibility, signed installation and execution on iOS 16 have not been verified for this release. Simulator execution on a newer OS does not establish those properties. Cloud integration is experimental; keep independent backups.

## Artifact integrity

Download `release-build36.json` alongside the IPA, then compare its SHA-256 with:

```sh
shasum -a 256 OpenNotes-build36-unsigned.ipa
```

Previous public downloads remain in [GitHub release history](https://github.com/edouaz/OpenNotes/releases). The [build 11 notes](archive/RELEASE-build11.md) and [implementation report](archive/IMPLEMENTATION_REPORT.md) are retained as historical records.
