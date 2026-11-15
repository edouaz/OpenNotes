# OpenNotes 0.1.0 — prototype build 11

**Early public prototype, with remaining implementation gaps.** Native iPhone/iPad app, iOS/iPadOS 16+, arm64. This is not an App Store or TestFlight release.

[Download the unsigned IPA](https://github.com/edouaz/OpenNotes/releases/download/v0.1.0-prototype.11/OpenNotes-ipados16-goodnotes-build11-unsigned.ipa) · [Installation](https://edouaz.github.io/OpenNotes/develop.html#install) · [Implementation report](IMPLEMENTATION_REPORT.md)

## Changes since public build 9

- Native ink engine with ballpoint/fountain/brush styles, pressure geometry, stabilization, patterns and existing pen gestures.
- Redesigned library and editor: grid/list, notebook creation, document tabs, page sidebar, tool customization, dockable palettes and read-only protection.
- Precision vector erasing, Standard segment erasing and whole-Stroke erasing, filters, preview, Clear Page and automatic return.
- Lasso selection and transformation handles, alignment guides, locking/recoloring, mixed clipboard and rectangular PDF captures.
- Rich-text sticky notes, inline editing, background colors, rotation, collapse, locking, attached ink/objects and persistence.

## Upgrade compatibility — read before installing

**Older PencilKit pages, including public build 9 notes, are unsupported by the native engine.** They fail explicitly; this release does not convert them. Export PDFs and native backups with your current app before updating. Do not rely on this build to open those older pages.

Native ink schema 1 remains readable. New writes use schema 2; original schema-1 resources are backed up before their first overwrite. Older app builds cannot read schema-2 ink. Original PDFs and existing library files are not reset or deleted.

The existing bundle identifiers, App Group, Keychain service and storage path remain. Sign the app and embedded share extension with matching entitlements and your own provisioning setup. Keep the same team and identifiers when updating an installation whose data you need. The IPA is **unsigned** and requires signing before installation.

## Validation and remaining limits

- **178 XCTest + 7 Swift Testing tests pass**, plus **2 UI tests** covering creation, read-only, sticky placement, list layout, finger ink, Undo/Redo and process reopen.
- Release arm64 archive and IPA integrity, app/extension build 11, minimum OS 16.0 and unsigned state verified.
- Physical iPadOS 16 execution, Pencil calibration/latency, older-iPad performance, comprehensive accessibility and cloud synchronization are not validated.
- This is not complete Goodnotes parity: global ink-versus-object stacking remains incomplete; rotated notes lack free side-resize; image recropping after insertion is not a non-destructive editor; rich lists lack automatic continuation/indentation. Full details and exact evidence are in [IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md).

## Artifact integrity

[Build manifest](../goodnotes-build11-package.json) records the SHA-256, size, source-tree digest, architecture and test counts. It is also attached to the GitHub release.

SHA-256 of the unsigned IPA:

```text
c98745e8ca1ba8e840750adff36c8fa1abc5127616422f7999e8ec423d26f328
```

Earlier builds remain available in release history. Build 11 is the current public download; do not reinterpret historical build-9 screenshots or PencilKit compatibility as applying to this release.
