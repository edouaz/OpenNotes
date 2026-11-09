# Architecture and data

OpenNotes is a SwiftUI app with a UIKit native ink canvas. It targets iOS/iPadOS 16 and uses system frameworks without external packages.

## Follow a change

`OpenNotes/App/LibraryStore.swift` owns library state and mutations. The workspace opens notebooks in tabs. `EditorSession` coordinates editing, while `WritingCanvas` and its coordinator bridge SwiftUI and native UIKit ink. `PageRenderer` renders page content for previews and export. Codable domain models live in `Core`; services implement disk storage, PDF text indexing, diagnostics and experimental cloud sync.

Before editing a shared model or canvas function, search its callers and tests. Keep the existing separation: views describe controls, editor code handles drawing and coordinates, services handle persistence and external I/O.

## Writing interaction

`InkCanvasView` captures Pencil input through a logical-page `UIView` inside the existing scroll viewport. Coalesced measurements are deduplicated; predictions stay in the transient preview. Estimated properties correct their measured samples. Pencil-only mode ignores direct input; optional finger writing is separate from two-finger navigation.

`InkDocument.swift` stores source samples, frozen style, processed geometry and identity in schema-versioned JSON. One Core Graphics outline renderer serves retained vector layers, tool previews, capture and export. Ballpoint width ignores pressure; Fountain/Brush vary progressively. Patterns use arc length; sharpness modifies caps. Constants are starting calibration values.

A 550 ms stationary hold recognizes lines, ellipses, polygons or curves. The preview adjusts before a single final commit; cancellation discards it. Scribble recognition requires dense repetitive geometry and visible ink overlap; partial erase creates new editable fragments. Circles remain ordinary ink until a later long press on their contour activates the existing lasso.

`EditorSession.replaceDrawing` owns undoable document replacement; autosave only receives committed measurements. Late estimated corrections update the same document value. Hover is temporary, Pencil-only and guarded for OS availability and the system preference.

Selection uses the existing pickup snapshot and shared page-edge constraints. UIKit transforms the cached preview; release commits one edit. Clipboard copies receive new stroke identifiers on paste. No additional undo stack, document library or third-party dependency is introduced.

Old PencilKit ink is explicitly unsupported in build 10, as authorized for this single-user development app. Decode failure does not overwrite it with a blank page. Physical Pencil latency, pressure calibration, navigation conflicts and large-page performance require device testing. See [validation](INK_VALIDATION.md).

## Local persistence

For update compatibility, the on-disk directory keeps its previous name: Application Support/CatNotes contains `library.json`, `library.backup.json` and `resources/`. Metadata is separate from drawing and imported resources. Writes are atomic; autosave waits approximately 700 ms. Leaving a page requires a successful flush. Pending drawing data must survive a failed write. Corruption produces an error and a recovery option rather than an empty replacement library.

Trash is recoverable; resources are not automatically purged. A `.catnote` file is versioned JSON with base64 resources and regenerated identifiers on import. Imports are limited to 150 MB; large notebooks need memory testing on older iPads. Native backups preserve editable data. PDF export keeps the PDF background vector-based but rasterizes ink at 2×.

## Optional cloud

Local notebooks do not require a backend. [Supabase notes](SUPABASE.md) describe the experimental REST integration, local configuration and SQL policies. It is not production-ready or validated across real devices. Do not advertise reliable synchronization or enable it by default.

## Generated project

`scripts/generate-project.py` collects sources from the app, shared, extension and test directories and writes the Xcode project and shared scheme. Edit the generator when changing build settings; regenerate after adding/removing source files. Bundle identifiers and App Group entitlements must match your signing setup for device builds.

## Validation boundaries

Unit and UI tests cover persistence, import/export, drawing state, geometry and controls. Real hardware is still needed for Pencil latency, palm rejection, pressure, energy, memory, VoiceOver and iOS 16 execution. The deployment target alone does not establish runtime validation on iOS 16.

## Rebrand compatibility identifiers

The product, Xcode project, module and source directories are OpenNotes. A small set of stable identifiers intentionally retains its legacy spelling:

- App and extension bundle identifiers: `fr.catnotes.app` and `fr.catnotes.app.share`.
- Shared import App Group: `group.fr.catnotes.app`.
- Existing Application Support directory: `CatNotes`.
- Keychain service: `fr.catnotes.auth`.
- Native document type/extension and clipboard interoperability identifiers.

These are compatibility keys, not displayed branding. Keep them stable when shipping an update to an existing installation. New signing configurations must be consistent across the app, extension, entitlements and developer account.

## Portable-core direction

See the [hybrid architecture audit](HYBRID_ARCHITECTURE_AUDIT.md) for component classifications and migration gates. Shape recognition math is independent of UIKit/editor state; run its existing contract tests with `sh scripts/test-shape-recognition.sh` on macOS. Rust adoption is deferred until profiling or a second client justifies it.
