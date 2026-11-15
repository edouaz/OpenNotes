# Goodnotes tools and UI integration — OpenNotes build 11

Delivery: unsigned arm64 IPA, iOS/iPadOS 16.0+, version 0.1.0 (11). Existing bundle identifiers, App Group, storage location and native Pen pipeline retained. No new package, backend or PencilKit writing canvas.

**Status: integrated release build with explicit remaining differences. This is not certification that every mandatory acceptance item in the supplied specification is complete.** In particular, arbitrary shared stacking of ink and non-ink objects is not implemented. Physical iPad/Pencil gates and contemporary Goodnotes screenshot comparisons remain NOT RUN.

## Delivered behavior

- Redesigned library with navigation rail, real persistent grid/list, search/favorites/Trash, folders, bulk move, notebook creation with title/cover color/paper/orientation.
- Redesigned editor tabs/navigation/tool categories, fixed-first Lasso, pinned configurable Undo/Redo, tool layout settings, pages sidebar, four-edge active palette docking, read-only UI plus shared mutation guards, independent tool palettes with HEX validation and up to twelve colors.
- Precision eraser subtracts the swept region from the **visible vector silhouette** using iOS 16 Core Graphics boolean geometry. Standard removes continuous path segments; Stroke removes whole touched strokes. Legacy pixel/intelligent settings remain readable. Pen/highlighter filters, document-space diameter, live erase preview, one commit per gesture, indexed candidate queries, cancellation, confirmed Clear Page and auto-return are integrated.
- Lasso uses painted geometry, including erased holes, rotated objects, ellipse and line geometry. Freehand/rectangle/direct selection share the existing session. Handles preview and commit scale/rotation; Shift/Option and opposite-corner anchors are supported. Unrotated text/sticky notes have side resize handles. Page/neighbor snap guides use screen-size tolerances and release hysteresis.
- Structured mixed clipboard preserves editable ink, images, text, transforms and remapped parent IDs. Copy/cut/duplicate/paste, lock/unlock, recolor, contextual actions and **rectangular model-rendered PDF captures** use central content snapshots/Undo.
- Sticky notes keep RTF rich text with selected-range formatting, independent background color, inline typing/native Scribble and a full formatting sheet. Move/resize/rotation, collapse, lock and exports persist. Newly drawn ink and inserted/moved objects can attach to a note; parent transformations, clipboard and deletion preserve the relationships. Collapsed children stay stored and are hidden from rendering.
- Inline drafts are staged synchronously, autosaved, flushed on navigation and committed before read-only activates. A focused text editor survives its own autosave instead of being destroyed by view reconstruction.
- Static object stacking shares the same renderer between the page, thumbnails, image/PDF export and capture. Interaction views are transparent outside editing so they do not redraw bodies over the ink.

## Compatibility and integration

Ink writes schema 2 and reads schema 1/2. Precision keeps source samples/styles plus a final local vector silhouette; transformations apply to the same geometry used by screen, selection and export. Before a schema-1 `.drawing` resource is first overwritten, its original bytes are saved to `ink-schema-backups`. Existing atomic resource/library saves and explicit failures remain. No existing library or original PDF was deleted or reset.

Build 10 already rejected legacy PencilKit pages; this delivery does not introduce a legacy converter. Older app versions cannot read schema-2 ink. Keep a native notebook export before updating or downgrading. Optional new PageElement properties allow existing native object JSON to decode. Hierarchy cycles and malformed rich text are rejected; orphan references are retained rather than silently deleting content.

Main integration points:

| Area | Files |
| --- | --- |
| App shell | `App/LibraryScreen.swift`, `NotebookWorkspace.swift`, `OpenNotesStyle.swift`, new `NewNotebookSheet.swift` |
| Editor chrome | `EditorScreen.swift`, `WritingInstrumentBar.swift`, `EditorInstrumentOptions.swift` |
| Shared document mutations | `EditorSession.swift`, `EditorSelection.swift`, new `StickyInkIntegration.swift`, `Core/DocumentAction.swift` |
| Ink | `InkDocument.swift`, `InkCanvasView.swift`, `EraserEditing.swift`, new `InkVectorPath.swift`, `InkSpatialIndex.swift` |
| Selection | `WritingCanvas.swift`, `PageSelectionView.swift`, `DocumentClipboard.swift`, `CanvasPasteMenu.swift`, `ImageHandlesView.swift`, new `SelectionActions.swift`, `SelectionGeometry.swift` |
| Sticky/rendering | `PageElement.swift`, `StickyNoteControl.swift`, `StickyNoteSheet.swift`, `PageRenderer.swift`, new `RichTextDocument.swift` |
| Persistence/build | `Services/NotebookArchive.swift`, `scripts/generate-project.py`, generated Xcode project, existing IPA packager |

The audit and compatibility decisions are in [MIGRATION_AUDIT.md](MIGRATION_AUDIT.md); screen/menu/state contracts are in [UI_REDESIGN_MAP.md](UI_REDESIGN_MAP.md). Parallel ownership was used for independent UI, selection and sticky components; final validation was integrated. The initial baseline build overlapped changes and is not independent clean-baseline evidence.

## Executed validation

Environment: Xcode 27.1; iPad Pro 13-inch (M5) simulator, iOS 27.0. The deployment target and SDK availability are 16.0; **execution on iPadOS 16 hardware/runtime was not available**.

| Check | Result / evidence |
| --- | --- |
| Full final unit run | **PASS: 178 XCTest, zero failures; 7 Swift Testing tests, zero failures**. `build/goodnotes-validation/Logs/Test/Test-OpenNotes-2026.10.29_15-10-21-+0100.xcresult` |
| UI creation/read-only/sticky placement/return to Lasso/library list | **PASS**; the list test checks row width, avoiding a previous launch-argument override that had forced grid mode |
| Native Pen UI | **PASS**: actual finger stroke, Undo/Redo, reachable pen options, library return, process relaunch, stored stroke still visible |
| UI evidence | Both final UI tests pass in `Test-OpenNotes-2026.10.29_15-06-11-+0100.xcresult`; that combined run had a pagination timing failure, resolved by the subsequent full unit run above |
| Release archive | **PASS**, generic iOS arm64, code signing disabled |
| IPA integrity | ZIP CRCs, payload app/extension plists, build numbers, minimum OS, bundle ID, unsigned state and arm64 binary checked; SHA-256 recorded with package metadata |
| Physical hardware / calibrated performance | **NOT RUN** |

New suites: `EraserGeometryTests` (5), `SelectionTransactionTests` (10), `StickyRichTextTests` (5), `StickyIntegrationTests` (8), and `GoodnotesUIIntegrationTests` (1). Existing native Pen, gestures, storage/PDF, canvas, pagination, clipboard, security and domain tests remain in the full run. Existing UI creation callsites were updated for the new form; the entire historical UI suite was not run.

Tests caught and corrected: parent rotation around the wrong origin; an inherited selection-filter preference in a new test; a pagination assertion that ran before zoom animation completed. The focused-editor/draft tests verify that autosave retains the native text view and the last keystroke survives read-only + reopen. The final release additionally hides element-only arrange commands for mixed ink/object selections; this final menu visibility restriction was compiled in Release after the complete UI run.

Existing synthetic diagnostics, from the integrated simulator run (not physical latency measurements): 10,000 strokes, 7,739,634 encoded bytes, 452 ms encode, 325 ms decode, 27 ms for a 256-point viewport render. These are simulator observations, not a before/after iPad benchmark or a live erase-frame budget.

## Remaining differences and manual gates

1. **Stacking:** non-ink elements support Front/Back; ink remains a native foreground layer. Arbitrary ink-versus-object ordering is incomplete. Arrange actions are hidden for ink-only/mixed selections to avoid presenting a partial group operation.
2. **Transforms:** free side resize is available for unrotated text/sticky notes; after rotation, uniform scale and rotation remain available. Exact affine shear/nonuniform group transforms for arbitrary rotated objects are not implemented. The editor displays one page at a time, so continuous inter-page drag/autoscroll is not supplied.
3. **Image actions:** image import/crop and capture/share use existing real flows. Non-destructive recropping of an already inserted image with a preserved original asset is not supplied. There is no invented element-library backend.
4. **Rich lists:** list commands insert attributed bullet/number prefixes; automatic continuation/indentation and a complete list editor are not supplied. Advanced rich formatting is in the existing sheet; inline editing supports native typing/Scribble.
5. **UI interaction parity:** preset editing opens full tool options; active-slot taps select colors. Toolbar reordering uses a native edit list rather than dragging directly in the toolbar. Docking chooses an edge by drag direction. These are functioning alternative flows, not exact Goodnotes interactions.
6. **Hardware/visual acceptance:** test Pencil pressure/palm rejection/hover on actual supported and older iPads; rapid erase at 0.5×/1×/3×, variable-width fringes, 2,000/10,000 strokes, cancellation/backgrounding, keyboard/RTL/IME/VoiceOver, portrait/landscape, Split View, dark mode, rotated/cropped PDFs and the minimum iPadOS version. No Goodnotes pixel-match, Pencil latency or 120 FPS guarantee is claimed.
7. AI, advanced math/handwriting reflow, collaborative comments and other absent external capabilities stay unavailable; no fake service commands or new backend were added.

## Reproduce

```sh
python3 scripts/generate-project.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project OpenNotes.xcodeproj -scheme OpenNotes \
  -destination 'platform=iOS Simulator,id=DB793DDF-5123-499E-BEF4-2ED940550098' \
  -derivedDataPath build/goodnotes-validation CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -only-testing:OpenNotesTests -parallel-testing-enabled NO test
# UI: same command, replace -only-testing:OpenNotesTests with these two arguments:
# -only-testing:OpenNotesUITests/GoodnotesUIIntegrationTests
# -only-testing:OpenNotesUITests/NativeInkInteractionUITests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project OpenNotes.xcodeproj -scheme OpenNotes -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/goodnotes-release \
  -archivePath build/artifacts/OpenNotes-goodnotes-build11.xcarchive \
  CODE_SIGNING_ALLOWED=NO archive
python3 scripts/package-ipa.py \
  build/artifacts/OpenNotes-goodnotes-build11.xcarchive/Products/Applications/OpenNotes.app \
  build/artifacts/OpenNotes-ipados16-goodnotes-build11-unsigned.ipa
```

The packager refuses an existing output path; use a new output name when reproducing. The unsigned IPA requires the user's signing/provisioning setup and matching app/extension entitlements.

## Evidence and sources

Real simulator screenshots: [library list](../../docs/assets/goodnotes-build11/library-list.png), [editor after reopen](../../docs/assets/goodnotes-build11/editor-reopened.png), [pen options](../../docs/assets/goodnotes-build11/pen-options.png). Their Xcode attachment metadata is in `docs/assets/goodnotes-build11/manifest.json`.

Documented reference behaviors were checked against official [Eraser](https://support.goodnotes.com/hc/en-us/articles/7353718249231-Erase-handwriting-and-page-content-with-the-Eraser-tool), [Lasso](https://support.goodnotes.com/hc/en-us/articles/7353695644175-Select-Move-and-Edit-Content-With-the-Lasso-Tool), [Sticky Notes](https://support.goodnotes.com/hc/en-us/articles/16348150581647-Add-sticky-notes-to-your-notes), [modern UI](https://support.goodnotes.com/hc/en-us/articles/13682253498767-Improved-User-Interface), [toolbar](https://support.goodnotes.com/hc/en-us/articles/8900755183631-Customize-the-toolbar), [color presets](https://support.goodnotes.com/hc/en-us/articles/7353743265039-Add-and-manage-writing-tool-color-presets) and [PDF screenshot](https://support.goodnotes.com/hc/en-us/articles/360001460175-Fix-the-Lasso-Tool-Showing-Only-Take-Screenshot) documentation. Local geometry, thresholds, layout tokens, RTF storage and index design are OpenNotes implementation choices. They are not claims about proprietary Goodnotes internals.
