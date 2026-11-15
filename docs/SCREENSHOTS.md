# Screenshot provenance

Current public screenshots show real OpenNotes build 36 views. All notebook content is synthetic test data.

## Current build 36

- `assets/build36/editor.png`: a blue mountain sketch entered through the real finger-ink input path, with the current notebook tabs and toolbar visible.
- `assets/build36/library.png`: the three synthetic notebooks created by the capture test, including the persisted sketch thumbnail.
- `assets/build36/pen-options.png`: the actual native pen options opened from the selected pen.
- `assets/build36/tour.gif`: a 720 × 960 screenshot slideshow of library, editor and pen options, each held for about 2.5 seconds. It is not a live recording or a latency benchmark. The website keeps it behind a disclosure and hides it for reduced motion.
- Captured on 16 November 2026 using `ReleaseShowcaseTests/testPublicPreviewTour`, iPad Pro 13-inch (M5), iOS 27.0, on the dedicated `OpenNotes-Release` simulator. Original images: 2064 × 2752 pixels; published PNGs: 1080 × 1440, downsampled without changing the interface or content.
- [Attachment metadata and hashes](assets/build36/manifest.json).

Reproduce on a fresh, dedicated simulator. The test creates three notebooks; it does not remove existing ones. Do not point it at a simulator containing personal notes.

```sh
# Replace the destination with your dedicated simulator.
xcodebuild -project OpenNotes.xcodeproj -scheme OpenNotes \
  -destination 'platform=iOS Simulator,name=OpenNotes-Release' \
  -derivedDataPath build -resultBundlePath build/showcase.xcresult \
  -only-testing:OpenNotesUITests/ReleaseShowcaseTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test

xcrun xcresulttool export attachments \
  --path build/showcase.xcresult --output-path build/showcase-captures \
  --filter '*.png'
```

The final capture run passed. An earlier attempt timed out waiting for a notebook to open during concurrent compilation; none of its attachments are used here.

## Historical build 11

These are retained for historical provenance and are not the current public UI.

- `assets/goodnotes-build11/library-list.png`: `GoodnotesUIIntegrationTests/testCreationReadOnlyPaletteAndLibraryList`, creation, read-only, sticky placement, actual list layout with row-width assertion.
- `assets/goodnotes-build11/editor-reopened.png`: `NativeInkInteractionUITests/testFingerInkUndoRedoAndReopen`, actual finger ink retained after process relaunch.
- `assets/goodnotes-build11/pen-options.png`: reachable native pen options from the same successful UI test.
- Device: iPad Pro 13-inch (M5), iOS 27.0 simulator, 2064 × 2752 pixels. Exported attachment metadata: `assets/goodnotes-build11/manifest.json`.

## Historical build 9 screenshots

The earlier captures below are retained for provenance and are not the current UI.

- `assets/editor.png`: successful `CustomEditorExperienceTests/testCustomToolbarPreviewAndWidthSettingWithoutNativePalette`, iPad Pro 13-inch (M5), iOS 27.0, 2064 × 2752 pixels.
- `assets/pen-preview.png`: instrument settings and stroke preview from the same successful UI test.
- `assets/library.png`: successful `LibraryLayoutTests/testMixedLibraryVisualMatrix`, the app's actual SwiftUI library hosted at a 744 × 1133-point portrait window, rendered at 2× on the iPad simulator. It includes synthetic folders, notebook titles and dates.

App icon and mascot artwork are generated brand illustrations, not screenshots or evidence of app behavior. [Identity and icon exports](BRAND.md).

Earlier test evidence and planning drafts remain in `.local-archive/`, excluded from the public repository. The public repository keeps a curated set of images instead of repeated test attachments.
