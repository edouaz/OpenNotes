# Native ink migration — 2026-10-29

Branch: `codex/custom-ink-engine`. Baseline user edits saved in `f86396b`.
User scope: iOS/iPadOS 16.0+, unsigned IPA; no legacy-note conversion or legacy corpus required. Existing PencilKit resources must fail explicitly rather than appear as empty successful pages. No destructive automatic library reset.

| Existing files | Role | Decision |
|---|---|---|
| Editor/WritingCanvas.swift, CanvasTouchObserver.swift | PencilKit input, scroll, held previews | Replace capture; retain page viewport/navigation |
| Editor/EditorSession.swift, EditorSelection.swift | Autosave, undo, selection | Adapt to native immutable drawing snapshots |
| Editor/StrokeProcessing.swift, ShapeRecognition.swift, EraserEditing.swift | Geometry and gestures | Reuse and adapt |
| Editor/PageRenderer.swift, TiledPaperView.swift, InkPreview.swift | PDF, tiles, tool previews | Share native renderer |
| Editor/PreparedPage.swift, Services/NotebookArchive.swift, DocumentContext.swift | Decode/export | Native versioned JSON, explicit invalid-format errors |
| App/LibraryStore.swift | New pages and archive import | Native empty drawing and native validation |
| Core/EditorToolSettings.swift, EditorInstrumentOptions.swift | Preferences/UI | Add sharpness and patterns to existing options |
| scripts/generate-project.py, package-ipa.py | Project and IPA | Reuse, preserve app identifiers, build unsigned arm64 |

Integration: native InkDrawing snapshots remain the single document value; EditorSession replacement is the shared undoable mutation; logical page units remain independent of viewport zoom. Raw samples and frozen stroke settings are persisted; predictions and hover remain transient.

No migration flag or legacy importer: explicitly waived by user. Prior `.catnote` ink is unsupported in this build. Physical Pencil/hover/latency and Goodnotes equivalence cannot be certified by simulator tests.

## Delivery status

- `f86396b`: existing editor/UI work preserved before migration.
- `d63f466`: native model, schema validation, shared renderer and model tests.
- `528fc69`: native capture, geometry/gestures, editor, clipboard, storage and export integration; removed PencilKit observer/preview paths.
- `11590c5`: pen-only gesture arbitration and popover UI test.
- `0635437`: sparse tapered-line rendering correction and regression coverage.
- **PASS:** final 150 XCTest + 7 Swift Testing tests; actual finger-writing/Undo/Redo/options/process-reopen UI smoke test; unsigned Release archive and IPA integrity checks.
- Final IPA: `build/artifacts/OpenNotes-ios16-native-ink-build10-unsigned.ipa`; checksum/provenance: `docs/native-ink-build10-package.json`.
- Final evidence, exact commands, synthetic performance numbers and remaining physical checks: [validation report](../../docs/INK_VALIDATION.md).

The initial baseline build overlapped implementation and is not independent baseline verification. Final migration builds/tests provide delivery evidence. Old-note conversion was waived; physical iPad/Pencil calibration and the recorded simulator keyboard incident remain validation limits. Implementation and local packaging are complete.

## Goodnotes tools/UI integration — build 11, 2026-10-29

Authorized target: unsigned IPA, iPadOS 16+. This changes the existing app. The preceding native-ink audit above remains historical evidence for build 10.

| Existing path | Role | Decision and risk | Verification |
| --- | --- | --- | --- |
| `App/LibraryScreen`, `NotebookWorkspace`, `OpenNotesStyle` | Library, tabs, visual tokens | ADAPT screen structure; retain store, folders, Trash and identifiers | Library layout tests + creation/navigation UI flow |
| `Editor/EditorScreen`, `WritingInstrumentBar`, `EditorInstrumentOptions` | Editor shell, palettes, menus | ADAPT full chrome; persistent dock/settings; preserve Pen settings | UI flow and native ink UI smoke |
| `Editor/InkDocument`, `InkCanvasView` | Native samples, renderer/input | KEEP acquisition and Pen processing; ADD final vector silhouettes/parent references, indexed erase preview | Native ink suites + EraserGeometryTests |
| `Editor/EraserEditing` | Partial/whole erasing | ADAPT Precision uses Core Graphics vector subtraction; Standard retains split paths with an internal 2-page-point margin; legacy pixel/intelligent still decode | Geometry, filters, rotated clipping, repeated erase, roundtrip |
| `Editor/EditorSelection`, `PageSelectionView`, `DocumentClipboard` | Selection, preview, clipboard | ADAPT shared undo mutations, painted geometry hit-test, mixed payload, handles | Selection transaction and canvas tests |
| `Editor/PageElement`, `StickyNoteControl`, `StickyNoteSheet` | Structured objects and sticky editing | ADD optional RTF/rotation/lock/order/parent fields; old element JSON remains readable | StickyRichTextTests + StickyIntegrationTests |
| `Editor/PageRenderer`, `PageArtwork` | PDF, page capture and thumbnails | KEEP shared composition, ADD sticky state and visible ink filtering | Renderer/capture tests |
| `Editor/EditorSession` | Mutations, autosave, undo | KEEP central snapshot history; ADD backend read-only checks and sticky child reconciliation | Roundtrip + read-only tests |
| `Services/NotebookArchive` | Storage/import validation | KEEP atomic writes; validate new object fields; save original schema-1 ink to `ink-schema-backups` before first overwrite | Existing persistence/security tests + schema backup test |
| `scripts/generate-project.py`, `package-ipa.py` | Xcode sources and packaging | KEEP generator/package; build 11; same bundle IDs, no new dependency | Release archive and ZIP/architecture checks |

Ink schema 2 reads schema 1 and 2; geometry, raw samples, source IDs and styles remain native. Precision stores a final local vector silhouette rather than a zoom-dependent bitmap. Serialization writes schema 2 so older builds fail explicitly instead of displaying erased material again. Existing schema-1 resources are backed up before first overwrite. No library reset, no PDF replacement, no legacy PencilKit converter (already unsupported by build 10). Do not downgrade onto schema-2 ink without restoring a backup.

No heavy framework/package or backend added. Core Graphics path boolean operations are available from iOS 16 (verified in the installed SDK). Calibration defaults (eraser Standard margin, snap tolerance, handles, layout) are implementation choices, not measured Goodnotes parameters.

The first baseline attempt was sandbox-blocked by Swift macros; its retry overlapped source integration and is not an independent clean baseline. Only completed final runs reported in IMPLEMENTATION_REPORT.md count as validation. Hardware Pencil, iPadOS 16 execution, older-iPad performance and exact Goodnotes visual parity are NOT RUN in this environment.
