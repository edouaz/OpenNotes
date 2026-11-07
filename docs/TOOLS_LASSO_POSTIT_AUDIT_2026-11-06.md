# OpenNotes — Technical audit: tools, lasso, post-it, performance (2026-11-06)

Audit only: no production code was changed. All probes ran in a scratch copy of the working tree (branch `codex/account-persistence-sync`, including uncommitted work). Another session was editing the repo during this audit, so line numbers may drift.

## 0. Summary

**The lasso does not feel native mainly for three reasons, and none of them needs Metal or Rust:**

1. **A selection has no identity.** It is only a screen-space path, and that path is re-evaluated against the page at every step. This is wrong: strokes the user never selected get moved or deleted (L1). It is also slow: 4+ evaluations per gesture on the main thread (L3).
2. **Picking up a selection rasterizes the whole visible page.** That took about 490–570 ms in our runs, regardless of selection size, while the outline moves at once and the content only catches up later (L2). Post-its do the same thing synchronously, freezing the main thread for about 730 ms when a drag starts (P1).
3. **Selection and post-it gestures are not separated from navigation.** One-finger scrolling dies on post-its (P2), a finger tap on ink switches the tool to lasso (G1), and the lasso does not work at all in finger mode (L5).

**Fix first:** selection by ID (L1), pickup without a full-page raster (L2/P1), and ink that vanishes when dragged across a post-it edge (L6).

### Evidence labels

| Label | Meaning |
|---|---|
| **CONFIRMED** | Reproduced by a probe that ran |
| **MEASURED** | Timed by a benchmark |
| **TRACED** | Execution path read in the code, not run |
| **HYPOTHESIS** | Plausible but unproven; the verification step is stated |

### Test environment and limits

- Apple M1 Mac, Xcode 27.1, iPad Pro 11-inch (M5) simulator, iOS 27.0. App code built with `-O`, whole-module. Medians of 1–7 runs.
- **No device, no Instruments, no FPS and no latency figures.** Times are main-thread or CPU costs on a simulator. Use them to compare, not as iPad numbers. Render-server cost (CAShapeLayer compositing, masks) is not captured at all.
- Results: **293 existing unit tests passed**, plus the 14 audit probes. `PerformanceTests` ran separately (6 passed). The existing UI test suite was not run. Only my own UI probes ran.
- Apple Pencil cannot be exercised here. Everything Pencil-specific is TRACED or HYPOTHESIS.
- No Rust exists in this repo (0 `.rs` files), so there is no Swift/Rust boundary to audit.

### Hypotheses I tested and rejected

These looked like good targets when reading the code. The numbers say to leave them alone.

| Suspect | Result | Conclusion |
|---|---|---|
| Implicit CA animation on the lasso outline's `path` | `action(forKey:"path")` is `nil`, while the `opacity` control does animate | **Not a cause.** No fix needed |
| `PageArtwork` re-created on every `replaceContent` | 0.19 ms (200-page PDF), 1.34 ms (5 images) | Not a bottleneck: parsing and decoding are lazy |
| `InkContentView.install` being O(n) | 0.14 ms (300 strokes), 0.77 ms (1,500), 5 ms (move 30 of 1,500) | Not a bottleneck |
| `paintedPaths()` allocations | 0.40 ms for 300 strokes | Not worth optimizing |
| Per-stroke mask construction | 1.3 ms for 100 strokes | Not a main-thread issue (compositing not measured, see B5) |
| RTF decode per draw | 0.02 ms | Negligible |
| `JSONEncoder` in `PageThumbnail.task(id:)` | 0.02 ms per page | Negligible |
| Spatial index for lasso | ID lookup reduces cost far more (0.05 ms vs 25 ms) | **Not justified** once L1 is done |

---

## 1. Current architecture map

```
EditorScreen (SwiftUI chrome; ObservedObject store + session)
  └─ WritingCanvas : UIViewRepresentable          updateUIView rewires all closures on each publish
       └─ PageScrollView : UIView                 viewport, gesture host, custom hitTest
            ├─ TiledPaperView (CATiledLayer)      paper, PDF, *all elements including post-its*
            ├─ ImageHandlesView[]                 below the canvas
            ├─ StickyNoteControl[]                transparent overlay, below the canvas; rebuilt on any element change
            ├─ InkCanvasView : UIScrollView       full-frame, above objects; zoom/pan
            │    └─ InkContentView                1 retained CAShapeLayer per stroke + live preview layer
            ├─ SelectionDragPreview (transient)   background + foreground bitmaps
            └─ PageSelectionView                  lasso outline, handles, edit menu
```

| Area | Actual implementation | Where |
|---|---|---|
| Rendering | Ink: one `CAShapeLayer` per stroke, geometry = dot + quad per sample, nonzero fill. Elements: CPU-drawn into tiles. Metal: none | `InkCanvasView.swift:451-578`, `InkDocument.swift:270-300`, `TiledPaperView.swift` |
| Models | `NotePage.elements` in `library.json`; `InkDrawing` in a separate revisioned JSON file | `EditorSession.swift:329-350` |
| Pencil input | Raw `touches*` on `InkContentView`, not gesture recognizers. Coalesced + predicted | `InkCanvasView.swift:194-291,585-589` |
| Pencil vs finger | `allowedTouchTypes` on recognizers; `accepts(_:)` for ink; `StickyNoteControl.hitTest` inspects `event.allTouches` | `InkCanvasView.swift:190`, `StickyNoteControl.swift:242` |
| Tool state | `EditorSession.selectedTool` (published) pushed to the canvas by `updateUIView` | `EditorSession.swift:91`, `WritingCanvas.swift:113` |
| Coordinates | Lasso path in **screen space**, re-projected by `follow()`. Document in logical page points | `PageSelectionView.swift:47`, `PageScrollView+Selection.swift:213` |
| Zoom | Custom pinch on `PageScrollView` driving `setZoomScale` + `contentOffset`; native pinch disabled | `PageScrollView+Zoom.swift:99` |
| Undo | `UndoManager` on the canvas storing whole-value snapshots (`InkDrawing` + elements). Cleared on page change | `EditorSelection.swift:15`, `EditorSession.swift:415`, `WritingCanvas.swift:127` |
| Persistence | 700 ms debounced autosave; encode off the main thread; elements persist immediately | `EditorSession.swift:301-359`, `LibraryStore.swift:60,135` |
| Sync | `CloudSync` deferred while `cloudInteractionActive` | `EditorSession.swift:240`, `PageScrollView.swift:7` |

### Lasso execution path (Pencil mode)

1. **Draw.** `pan` hosted on `PageScrollView` → `updateDrag` → `outline.path` updated.
2. **Pen-up.** `presentMenu()` → `menuActions` → **snapshot #1** (main thread).
3. **Drag begins.** `moveBegan` → **snapshot #2** (main thread) + detached full-page raster.
4. **Drag.** `moveChanged` → `SelectionDragPreview.move` translates the bitmap.
5. **Drop.** `clearSelection()` → Task → `moveSelection` → **snapshot #3** → `replaceContent` → `installSelection` → `presentMenu` → **snapshot #4**.

### Post-it execution path

1. Finger tap → `tapBody` → selected. A second tap opens the text editor.
2. Finger pan on the body → `StickyDragPan` → `movePreviewBegan` → **synchronous** `SelectionDragPreview`.
3. End → `changed` → `session.apply` → **`flush` before the edit** → `replaceContent` → `flush` → all controls rebuilt, then the preview is removed.

---

## 2. Lasso technical diagnosis

### L1 — Selection has no identity — **Critical** — CONFIRMED

- **Evidence.** `PageSelectionView.path` is the only state. Every step rebuilds the set from geometry: `EditorSelection.swift:26`, `SelectionActions.swift:23,100`, `PageScrollView+Selection.swift:88,125`. Tap selection installs the *bounding rect* as the path (`PageScrollView+Selection.swift:45`).
- **Probe.** Lasso 1 stroke and move it over another: re-evaluation returns **2 strokes**. Tap 1 diagonal stroke: drag picks up **2 strokes** (a neighbour inside its bounding box).
- **Root cause.** No selection model exists; `SelectionMoveSnapshot` is recomputed instead of retained.
- **User impact.** Tap one stroke and press Delete: neighbours inside its bounding box are deleted too (`transformSelection(deleting:)`). Second drags collect whatever the selection passed over.
- **Solution.** Add `init(page:drawing:strokeIDs:elementIDs:)` to `SelectionMoveSnapshot`. Capture the IDs once (pen-up, tap or circle). Pass them to `moveSelection`, `affineSelection`, `transformSelection`, `selectionAction`, `payload` and `menuActions`. Keep the path for display and hit-testing only.
- **Complexity.** Medium (one type, about 8 call sites).
- **Expected improvement.** Only the selected objects move or get deleted. 3 of 4 snapshots drop from 35 ms to about 0.05 ms (MEASURED counterfactual, 400-edge lasso on 300 strokes).
- **Verification.** New tests: move onto a neighbour then move again; tap select then delete with a neighbour inside the box. The filters must still apply at capture time.

### L2 — Pickup rasterizes the whole visible page — **High** — MEASURED

- **Evidence.** `SelectionDragPreview.render` (`PageSelectionView.swift:309-341`) draws the page minus the selection, then the selection, for any move.
- **Measure.** **491 ms** (300 strokes), **574 ms** (1,500), each with only 30 selected. The cost barely depends on selection size. Peak memory (derived, not measured): about 16 MB per full-screen bitmap on an 11-inch iPad, with intermediate images on top.
- **Root cause.** The ink is already in retained `CAShapeLayer`s, yet the preview redraws it to bitmaps. The work is off the main thread for the lasso, so the outline follows the Pencil while the content stays still until the bitmap lands. This is the visible "lag" in the lasso.
- **Solution.**
  - **Ink-only selection:** apply a translation or affine to the selected strokes' existing layers (new `InkContentView.setTransientTransform(_:for:)`). No raster at all.
  - **Selection with elements:** keep a cropped foreground bitmap, and rasterize the background for that crop only rather than for the full screen.
- **Complexity.** Medium.
- **Expected improvement.** Content moves from the first frame. Comparable main-thread work: `install` with 30 moved strokes costs 0.64 ms (MEASURED). Whether compositing holds up is unmeasured.
- **Regression risk.** Preview/commit parity, masks while moving, marker strokes.
- **Verification.** New `lasso.pickup` signpost, Animation Hitches on iPad, screen-recording comparison.

### L3 — Snapshot cost and frequency — **High** — MEASURED

| Scenario | Median |
|---|---|
| Rectangle lasso, 300 strokes (what `PerformanceTests` covers today) | 0.5 ms |
| Freeform 100 / 400 / 1,200 edges, 300 strokes | 11 / 35 / 74 ms |
| Freeform 400 / 1,200 edges, 1,500 strokes | 42 / 107 ms |
| 5 post-its overlapping 300 strokes of page ink | **206 ms** |
| 100 ink strokes owned by a note, note filter off | **161 ms** |

- **Evidence.** `EditorSelection.swift:108-114` runs sticky occlusion booleans first and the cheap test second. `DocumentClipboard.swift:38` rebuilds lasso edges for every stroke.
- **Root cause.** Repetition (L1), plus `occlusion.visible` booleans running before any rejection test.
- **Solution, in order.** (a) L1 removes the repeats. (b) Test `contains` on the raw stroke before calling `occlusion.visible`. (c) Compute edges once per snapshot: counterfactual **25 → 17.5 ms** (about 30%). (d) Add a freeform lasso and a post-it page to `PerformanceTests`, since the current benchmark hides the problem. Move the first snapshot off the main thread only if it is still too slow after this.
- **Complexity.** Low for (b)–(d).
- **Verification.** Before/after on these same benchmarks; the `lasso.snapshot` signpost exists already.

### L4 — Lasso line input is coarser than ink — **Medium** — TRACED (feel is HYPOTHESIS)

- **Evidence.** `pan` + `gesture.location` (`PageSelectionView.swift:228-254`). Nothing is drawn until UIKit's pan threshold is crossed, and the lasso has no coalesced or predicted touches, unlike ink.
- **Solution.** Drive lasso drawing from `InkContentView` touches, reusing `InkSampleBuffer` and the existing `begin`/`move`/`end` routes. Keep `pan` for finger mode.
- **Complexity.** Medium.
- **Expected improvement.** The line starts at contact and tracks like ink.
- **Verification.** Side-by-side iPad video of ink and lasso.

### L5 — Lasso is dead in finger mode — **High** — CONFIRMED with control

- **Evidence.** `PageSelectionView.swift:64-65`: `pan.allowedTouchTypes = pencilOnly ? [pencil] : []`, and `tap` copies it. An empty list accepts no touch at all.
- **Probe.** With "Write with your finger" on, a finger drag produces no selection menu. Replacing `[]` with `[direct]` in the scratch copy makes the same UI test produce the menu.
- **Knock-on effects.** "Capture an area" is unusable in finger mode. Finger mode also disables note-body selection (`WritingCanvas.swift:197`), so a note there cannot be selected by tap *or* lasso.
- **Solution.** `[direct, pencil]` in the non-pencil-only branch.
- **Complexity.** Low (one line).
- **Verification.** Keep the UI probe as a regression test (see section 9).

### L6 — Ink vanishes when dragged across a post-it edge — **High** — CONFIRMED

- **Evidence.** `moveSelection` and `affineSelection` keep `parentID`. Only `actionName == "Draw"` re-attaches (`EditorSelection.swift:7`). `StickyInkOcclusion` clips children to their parent and hides other ink under notes.
- **Probe.** Drag child ink out of a note: `visibleStrokes=1/2`, parent kept. Drag page ink onto a note: `visibleStrokes=0/2`, no parent.
- **User impact.** The ink looks deleted, and because selection uses visible geometry it cannot be lassoed back. Only undo recovers it.
- **Solution.** After a selection transform, re-parent each moved stroke with the rule `attachingInk` already uses (extend it to accept the moved IDs). Elements already do this via `attachObjects: true`.
- **Complexity.** Low–Medium.
- **Verification.** Turn the probe into a test, covering undo and reload.

### L7 — Hidden content under a collapsed note can be selected — **Medium** — CONFIRMED

- **Evidence.** `DocumentClipboard.selectedElements` and `SelectionMoveSnapshot` do not filter `collapsedContentParents`, though rendering does.
- **Probe.** A lasso over an empty-looking area selects a hidden child element. Hidden ink inside the 44 pt box is selected too.
- **User impact.** Delete can remove content the user cannot see.
- **Solution.** Filter hidden parents at the start of selection.
- **Complexity.** Low.
- **Verification.** Probe → test.

### L8 — Transform limits and silent failures — **Medium** — CONFIRMED / TRACED

- **Evidence.** `affineSelection` (`SelectionActions.swift:96-125`) has no ink bounds check, and rejects the entire transform if any element overflows.
- **Probe.** Ink scaled ×3 near an edge ends at `maxX=944` on a 794 pt page. An element overflow returns `false`.
- **Traced.** `updateDrag` and `transformDragged` call `clearSelection()` *before* the async commit (`PageSelectionView.swift:221,248`). A failed commit (lock, zero delta, overflow) therefore loses the selection with no feedback. A locked selection also lets the outline drag, then snaps back.
- **Solution.** Clamp the scale as `transformSelection` does (`EditorSelection.swift:58`). Keep the selection until the commit resolves and restore it on failure. Refuse to start a move on locked content.
- **Complexity.** Low–Medium.
- **Verification.** Tests for each failure path.

### L9 — Undo/redo leaves a stale selection — **Medium** — TRACED

- **Evidence.** The selection view is never told about undo. `WritingCanvas.Coordinator` already observes undo notifications (line 238) but only refreshes availability.
- **Repro.** Lasso → move → Undo. The content returns, the outline stays at the moved position, and the next drag grabs whatever is there.
- **Solution.** Clear the selection on undo/redo (simplest), or recompute the outline from the IDs after L1.
- **Complexity.** Low.
- **Verification.** UI test.

### L10 — Menu pops up automatically — **Medium (UX)** — TRACED

- **Evidence.** `presentMenu()` runs at every lasso end (`PageSelectionView.swift:264`) and after every move (`installSelection`, line 133). Resize and rotate handles require long-press or a menu item (line 122).
- **Impact.** The menu covers the content after each adjustment, and each presentation costs a snapshot (L3).
- **Solution.** Show the outline only. Show the menu on tap inside the selection, which `tapped` already does (line 174). Never show it after a move. Decide separately whether handles appear directly.
- **Complexity.** Low, but `CustomEditor`-style UI tests may assume the menu appears.
- **Verification.** UI tests plus hands-on check.

### L11 — Viewport change during a drag — **Low–Medium** — TRACED

- **Evidence.** `SelectionDragPreview` captures `zoom`/`offset` at pickup, whereas commit divides by the *current* zoom (`PageScrollView+Selection.swift:140`). Finger navigation stays active while the Pencil drags.
- **Impact.** After a pinch mid-drag the drop lands away from the preview, and the frozen background hides the moving page.
- **Solution.** Cancel the move when a pinch or pan starts.
- **Complexity.** Low.

### L12 — Any touch selects the whole stroke — **Low (product decision)** — TRACED

- **Evidence.** `DocumentClipboard.contains` is true for any overlap. The existing `testVisibleStrokeSelectionIncludesCrossingAndWidth` pins that behaviour. Strokes are never split, which is good.
- **Impact.** The lasso edge grazing a neighbouring letter picks it up.
- **Solution.** If you want this tightened, require a share of samples inside (start at 50%, always select very small strokes).
- **Complexity.** Low–Medium. Requires changing the existing test.

### L13 — Smaller items

| Item | Label | Evidence | Fix |
|---|---|---|---|
| Copy/Cut render a PNG on the main thread and re-parse the PDF: **76 ms** with a 200-page PDF | MEASURED | `SelectionActions.swift:35` passes no artwork | Pass `artwork.pdfPage`/`images`; encode the PNG off main |
| Handle resize does not scale text font; the menu's "enlarge" does | TRACED | `SelectionActions.swift:114` vs `EditorSelection.swift:68` | Align them |
| Detached preview render is never cancelled on rapid re-drags | TRACED | `PageSelectionView.swift:294` | Goes away with L2 |
| Direct-selection logic is duplicated | TRACED | `WritingCanvas.swift:155-173`, `PageScrollView+Selection.swift:36-48` | Keep one |
| Rotate handle moves away from the Pencil (re-laid on the rotated AABB) | TRACED | `PageSelectionView.swift:165,215` | Freeze handles during the gesture |
| No alignment guides for post-it drags, unlike lasso moves | TRACED | `moveFreely` vs `move` | Share `snap` if wanted |

### What makes the lasso less fluid than Apple's

In order of confidence: content lags behind the outline (L2), main-thread stall at drag start (L3), the menu interrupting each adjustment (L10), and the outline's start threshold and lack of coalesced input (L4, feel unverified).

---

## 3. Post-it technical and UX diagnosis

### P1 — Main-thread freeze at drag/resize start — **High** — MEASURED

- **Evidence.** `PageScrollView+Notes.swift:153` builds `SelectionDragPreview` with the default `asynchronous: false`. Resize adds `StickyResizePreview` (`:166-173`).
- **Measure.** **730 ms** on the main thread with 300 strokes on the page.
- **Solution.** Same principle as L2: the post-it control already moves; preview just the note and its children. Rasterize only the note's crop, off main, and hide its original area. Size `StickyResizePreview` to the note instead of the full screen (3.85 ms per full-screen draw is acceptable but pays for a screen-sized backing store).
- **Complexity.** Medium.
- **Expected improvement.** Drag starts immediately.
- **Verification.** New `sticky.pickup` signpost, Hitches on iPad.

### P2 — One-finger navigation dies on post-its — **High** — TRACED

- **Evidence.** `PageScrollView.hitTest` returns the note for finger touches (`:74-77`). The note is a sibling of the canvas, so canvas pan and page-turn never see the touch. The note's own pan refuses when unselected (`StickyNoteControl.swift:182`). `StickyNavigationPan` needs 2 fingers.
- **Repro.** Zoom in, then drag one finger starting on an unselected post-it: nothing moves. Page-turn swipes starting on a note do nothing either.
- **Solution.** Unselected, non-collapsed note bodies stop capturing touches (`hitTest` → `nil`, canvas gets them). `backgroundTap` tests notes geometrically and selects, reusing the z-sorted lookup. Collapsed notes keep hold-to-drag, moved to the same host. This also makes **P4's** dependence on `allTouches` unnecessary.
- **Complexity.** Medium.
- **Regression risk.** Tap/keyboard flow, VoiceOver activation, existing `StickyManipulationTests` and `StickyNavigationPan` behaviour.
- **Verification.** UI test: pan from a note body at zoom; swipe from a note at fit.

### P3 — Delete sits on top of the top-left resize grip — **High** — CONFIRMED geometry

- **Evidence.** `StickyNoteControl.swift:266,274`. Delete cell (6,6,26×26) sits inside the grip cell (-14,-14,44×44).

```
Hit map, top-left corner (note origin is 0,0)
      x:  -12     -4      4       12      20      28      36
y=-12:  resize  resize  resize  resize  resize  resize  nil
y= -4:  resize  resize  resize  resize  resize  resize  nil
y=  4:  resize  resize  resize  resize  resize  resize  body
y= 12:  resize  resize  resize  DELETE  DELETE  DELETE  body
y= 20:  resize  resize  resize  DELETE  DELETE  DELETE  body
y= 28:  resize  resize  resize  DELETE  DELETE  DELETE  body
y= 36:  nil     nil     body    body    body    body    body
```

- **User impact.** Delete is one slip away from the corner, and fires with no confirmation (there is an undo toast). The 26 pt target is under the 44 pt guideline. A short drag starting on the cross may also end in delete because of `.touchUpInside` tracking tolerance (HYPOTHESIS, check by hand).
- **Solution.** Move the cross outside the corners, for example centred above the top edge with a 44 pt cell, keep the glyph small, and widen `point(inside:)` accordingly. Cancel if a drag begins.
- **Complexity.** Low.
- **Verification.** Hit-map test (the probe already prints it) and a UI test.

### P4 — Pencil vs container: no defined rule — **Medium** — TRACED + HYPOTHESIS

- **Evidence.** `StickyNoteControl.swift:242` returns `nil` for any event containing a Pencil touch, including on handles and the cross. So the Pencil can never operate chrome: it writes ink there instead.
- **HYPOTHESIS.** Whether `event.allTouches` reliably includes the new touch during `hitTest` needs an iPad test. `docs/POST_IT_2.md` also lists Pencil arbitration as unverified. A finger on a note while a Pencil is down also gets `nil`.
- **Recommended model.** Separating container from content does not need a mode button:

| State | Entered by | Finger | Pencil / highlighter |
|---|---|---|---|
| **Idle** | Default | Tap selects; pan navigates | Writes into the note |
| **Selected (container)** | Finger tap | Body drag moves; corners resize; cross deletes; tap again edits text | On chrome: operates it. On body: writes and deselects |
| **Text editing** | Second tap or menu | Text interaction | Text interaction (Scribble) |
| **Collapsed** | Chevron | Tap opens; hold-drag moves | Passes through to the page |

The Pencil never moves a container, and handwriting needs no extra mode. Chrome appears only after a deliberate finger tap, so strokes cannot be taken by mistake.

- **Complexity.** Medium; mostly follows from P2.
- **Verification.** Physical iPad checklist in section 9.

### P5 — Live ink not clipped, then jumps at pen-up — **Medium** — TRACED

- **Evidence.** Comment at `InkCanvasView.swift:560`: "sticky ink clips at commit". The attachment rule uses only the first sample (`StickyInkIntegration.swift:43-49`).
- **Impact.** A stroke leaving a note shows outside it, and that part disappears at pen-up. A stroke entering a note from outside disappears under it.
- **Solution.** Set `preview.mask` when the stroke begins, from the same occlusion logic.
- **Complexity.** Low.
- **Verification.** Compare preview and committed snapshots.

### P6 — Text font corrupted by zooming while editing — **Medium** — CONFIRMED

- **Evidence.** `alignBackground` updates `note.zoom` during editing (`PageScrollView+Zoom.swift:149`), and `draft` divides by the *current* zoom (`StickyNoteControl.swift:382`).
- **Probe.** Zoom 1 → 2 while editing: font **16 → 8** in the saved RTF.
- **Solution.** Capture the zoom in `beginInlineEditing` and use it in `draft`. Better, rescale the editor on zoom.
- **Complexity.** Low.
- **Verification.** Probe → test.

### P7 — Commit waits for disk first — **Medium** — TRACED + MEASURED component

- **Evidence.** `apply` flushes *before* editing (`EditorSession.swift:374`), although lasso moves already skip that (`prepareEdit`, line 35). Encoding alone is 233 ms on a dense page, off main. During the wait the control's chrome snaps back, since `move` resets its transform while the preview holds the content (`StickyNoteControl.swift:425`).
- **Impact.** Insert, move, resize, collapse and delete can visibly lag right after writing.
- **Solution.** Use `prepareEdit(durable: false)` for interactive actions; autosave covers the rest.
- **Complexity.** Low, with **durability risk**: check it against the tests around flush failure.
- **Verification.** Time from gesture end to `page` publish, with a pending stroke.

### P8 — Smaller post-it items

| Item | Severity | Label | Evidence | Fix |
|---|---|---|---|---|
| All controls rebuilt on any element change: about 3.5 ms (5 notes), 17 ms (20) per rebuild; handle fade replays | Medium | MEASURED | `PageScrollView+Notes.swift:98` | Diff by ID, update in place |
| Keyboard may cover a low note: no keyboard handling in the editor | Medium | TRACED | No keyboard code in `Editor/` | Scroll the note into view |
| Element edit repaints every tile; old `layer.contents` may ghost while the preview is removed at once | Medium | HYPOTHESIS | `TiledPaperView.swift:28,33`, `PageScrollView+Selection.swift:150` | Verify with slow-motion capture, then `setNeedsDisplay(in:)` with a dirty rect |
| Crash window: elements saved immediately, attached ink up to 700 ms later | Low–Medium | TRACED | `LibraryStore.swift:135-141`, `EditorSession.swift:307` | Save both in the same flush when a note with children moves |
| "Customize…" goes through `onDirectSelection(center)` and can open image placement | Low | TRACED | `PageScrollView+Notes.swift:179` | Call `edit` directly |
| `hitTest` uses array order in one path, z-order in another | Low | TRACED | `PageScrollView.swift:66` vs `:71-77` | Share one z-sorted list |
| Rotated notes clamp to the unrotated rect | Low | TRACED | `StickyNoteControl.swift:407` | Use `visibleBounds` |
| Collapse has no animation and lands top-left, away from the centre chevron | Low (UX) | TRACED | `StickyNoteControl.swift:264,280` | Short animation; put the chevron near the top-left, or anchor differently |
| Chevron visible on every unselected note | Low (UX) | TRACED | `StickyNoteControl.swift:205` | Show only when selected; collapse stays reachable from the menu |
| Insert anchors at top-left; paste centres on the touch | Low | TRACED | `EditorSession.swift:22`, `DocumentClipboard.swift:134` | Centre on the touch |
| Dead code: `dragHandle`, `textButton`, `selectionOutline`, `selectsBeforeEditing` kept but always hidden/unused | Low | TRACED | `StickyNoteControl.swift:36,58-62,202,207` | Delete. The blue-square outline is already hidden, so this removes it for good |

**Requirements already met:** four external corner handles when the note is not small, small red cross, per-note customization via long press, Pencil and highlighter passing through, undo through whole-value snapshots, collapse preserving size, exact-ID descendant handling.

---

## 4. Gesture interaction matrix

| Context | Input | Desired | Actual | Status |
|---|---|---|---|---|
| Any tool, on paper | 1 finger pan | Scroll / page turn | Same | OK |
| Any tool, on paper | Pinch | Zoom | Same | OK (see G5) |
| Any tool, **on a post-it** | 1 finger pan | Scroll / page turn | Nothing if unselected | **P2** |
| Any tool, on a post-it | 2 fingers | Navigate | `StickyNavigationPan` | OK |
| Pen / highlighter, **on ink** | Finger tap | Nothing | **Switches tool to lasso** | **G1** |
| Any tool, on ink | Finger double tap | Fit page | Fit, **plus G1 on the first tap** | **G1** |
| Pen / eraser | Finger long press | Menu | Paste / Add Sticky | OK, but see G3 |
| Lasso | Finger long press | Menu | Paste menu, or handles inside a selection | OK |
| On a post-it | Finger long press | Context menu | Note menu | OK |
| Pen / highlighter | Pencil | Tool action | Ink | OK |
| Pencil on note chrome | Pencil | Operate chrome | Writes ink | **P4** |
| Eraser | Pencil | Erase | Occlusion-aware erase | OK |
| Lasso | Pencil | Select | Works, with threshold | L4 |
| Lasso, **finger mode** | Finger | Select | **Nothing** | **L5** |
| **Finger mode** | 2 finger swipe at fit | Page turn | **Disabled** | **G2** |
| Pencil stroke active | Finger / palm | Ignored | Pan, pinch, menu, tap still possible | **G3** |
| Read-only | 1 finger | Navigate | Navigate | OK |

### Gesture findings

**G1 — Finger tap on ink switches tool to lasso — High — TRACED.** `tappedBackground` → `onDirectSelection` → `session.selectedTool = .lasso` (`PageScrollView+Notes.swift:17-24`, `WritingCanvas.swift:167`). `backgroundTap` does not wait for `fitGesture` and does not check `hasActiveStroke`, so a double tap and possibly a brief palm contact (HYPOTHESIS) trigger it mid-writing. No test covers it, and my UI probe could not reach the toggle in the menu, so it remains unrun. **Fix:** remove direct selection from finger taps; keep it for Pencil taps in the lasso tool. Keep tap on image, requiring `fitGesture` to fail. **Low complexity.** Verify with a UI test.

**G2 — No page turn in finger mode — High — TRACED.** `WritingCanvas.swift:119` sets `disabled = true`, contradicting the 2-finger setup at `PageScrollView.swift:100-101`. **Fix:** delete line 119. **Low complexity.** Verify with a 2-finger swipe UI test.

**G3 — Navigation not locked during a stroke — Medium — TRACED (impact HYPOTHESIS).** Only page turn checks `hasActiveStroke` (`InteractivePageTurn.swift:50`). Canvas pan, pinch, `pasteHold` and `backgroundTap` do not. **Fix:** check `!canvas.hasActiveStroke` in `gestureRecognizerShouldBegin`. **Low complexity.** Verify on iPad with a resting palm.

**G4 — `pasteHold` active when its menu is off — Low–Medium — TRACED.** In finger mode it still recognizes at 0.5 s, cancelling a stationary finger stroke before the 0.55 s shape hold. **Fix:** `pasteHold.isEnabled = longPressMenuEnabled`. **Low complexity.**

**G5 — Pinch and canvas pan both write `contentOffset` — Low — HYPOTHESIS.** `zoomGesture` is simultaneous with everything (`PageScrollView.swift:249`), and the canvas pan has no maximum touch count. Possible micro-jitter. **Check on iPad before changing anything.**

### Recommended interaction architecture

Keep the current structure, with these rules:

1. **Pencil and finger never compete.** Fingers navigate; recognizers declare touch types explicitly.
2. **`PageScrollView` hosts object gestures.** Unselected objects do not capture touches, and hit-testing is geometric and z-sorted in one function.
3. **Replace "always simultaneous" (`PageScrollView.swift:249`)** with an explicit list of allowed pairs.
4. **`hasActiveStroke` gates every finger gesture.**
5. **One selection model** (`strokeIDs`, `elementIDs`, display path) for lasso, tap and circle.

---

## 5. Performance bottlenecks

Ranked by evidence. All figures from section 0's environment.

| # | Bottleneck | Figure | Thread | Fix |
|---|---|---|---|---|
| B1 | Post-it pickup | 730 ms | **Main** | P1 |
| B2 | Precision eraser on a long stroke | **10,185 ms** at 3,000 samples vs 51 ms at 1,000 | **Main** | See below |
| B3 | Lasso pickup raster | 491–574 ms | Background, but user-visible | L2 |
| B4 | Snapshot with post-its; repeated 4×+ | 161–206 ms | **Main** | L1, L3 |
| — | Freeform snapshot, repeated 4×+ | 35–107 ms | **Main** | L1, L3 |
| — | Copy/Cut with PDF | 76 ms | **Main** | L13 |
| — | Control rebuild, 20 notes | 17 ms | **Main** | P8 |
| — | Dense page autosave | 233 ms encode, 3.68 MB | Background | None needed now |
| — | `pages(in:)`, 1,000 pages | 0.59 ms per call | **Main** | Only if body evaluation shows up in Instruments |

**B2 — Eraser cliff — High when it triggers.** `EraserEditing.swift:31`: when the outline exceeds 40,000 elements, it falls back to a full boolean. Likely source of the jump between 1,000 and 3,000 samples, though I did not isolate it. It runs in `previewErasing`, per Pencil move. Stroke mode is the default, so this requires Precision on a very long stroke. **Fix:** do not take the full boolean on the main thread: keep the raw result during the gesture and compact it later off main. Medium complexity. Verify with the existing `eraser.precision.longstroke3000` benchmark.

**B5 — Render-server cost — HYPOTHESIS, unmeasured.**
- One `CAShapeLayer` per stroke, with a dot + quad per sample. `render.image` takes 569 ms for 300 strokes in CG, so the geometry is expensive to fill.
- One mask layer per clipped stroke may force an offscreen pass each.
- Measure scroll and zoom hitches in Instruments on a dense page first. If confirmed, candidates are simpler outlines for constant-width strokes, and one mask per note container rather than per stroke.

**B6 — SwiftUI invalidation — HYPOTHESIS, low.** Each publish re-runs `updateUIView`: about 25 closures reassigned and an O(strokes) scan at `PageScrollView+Notes.swift:86`. Autosave publishes 700 ms after the last stroke, possibly mid-writing. Nothing publishes per frame during drags, which is correct. Add a signpost before acting.

**Not justified by evidence:**
- **Rust:** the costs are redundant work and full-page raster, not language speed. No port would help L1 or L2.
- **Metal:** avoiding the raster is cheaper than accelerating it. Only reconsider if B5 is measured as a real limit.
- **Spatial index for lasso:** ID lookup wins.
- **Drawing format change:** encoding is off main.

---

## 6. Bugs and reproduction steps

| ID | Sev. | Steps | Observed | Expected |
|---|---|---|---|---|
| L1 | Critical | Lasso a word, drag onto another, drag again | Both words move | Only the selected word |
| L1 | Critical | Tap a long diagonal stroke with a neighbour in its box, then Delete | Neighbour also deleted | Only that stroke |
| L6 | High | Write in a note, lasso with note filter off, drag out | Ink vanishes | Ink visible, detached |
| L6 | High | Lasso page ink, drag onto a note | Ink vanishes | Ink joins the note |
| L5 | High | Turn on "Write with your finger", pick lasso, drag | No selection | Selection |
| P1 | High | Dense page, select a note, drag | Stall at start | Immediate |
| P2 | High | Zoom in, one-finger drag from an unselected note | No scroll | Scroll |
| P3 | High | Select a note, aim at the top-left corner, inside | Note deleted | Resize |
| G1 | High | Pen tool, finger tap on ink | Tool becomes lasso | Nothing |
| G2 | High | Finger mode, 2-finger swipe at fit | No page turn | Page turn |
| B2 | High | Precision eraser on a 3,000-sample stroke | Multi-second freeze | Fluid |
| L7 | Medium | Collapse a note with a child, turn off note filter, lasso where the child was, Delete | Hidden child deleted | Not selectable |
| L8 | Medium | Scale ink near the edge | Ink off the page | Clamped |
| L8 | Medium | Scale an element past the edge | Reverts, selection lost | Clamped, selection kept |
| L9 | Medium | Move a selection, Undo | Outline stays at old spot | Cleared or follows |
| P6 | Medium | Edit note text, pinch zoom, type, Done | Font size changes | Unchanged |
| P5 | Medium | Write from a note out over its edge | Part vanishes at pen-up | Clipped while writing |

---

## 7. Recommended architecture improvements

Keep everything else; the current SwiftUI chrome / UIKit canvas split and retained layers are sound.

1. **`Selection` value** (`strokeIDs`, `elementIDs`, screen path). Single source of truth for lasso, tap and circle. Replaces geometric re-evaluation.
2. **Transient transforms on existing layers** in `InkContentView`. The drag preview becomes only what has no layer (elements, cropped).
3. **Object gestures hosted by `PageScrollView`**, with unselected notes not capturing touches. Can eventually retire part of `StickyNavigationPan`.
4. **Explicit gesture pair list and a stroke lock.**
5. **Note controls diffed by ID** rather than rebuilt.

No new dependency, no new module, no document format change.

---

## 8. Prioritized optimization roadmap

| Rank | Item | Impact | Complexity | Risk |
|---|---|---|---|---|
| 1 | L1 Selection by ID | Very high (correctness + speed) | Medium | Medium |
| 2 | L5, G2, G4 one-line gesture fixes | High for finger mode | Low | Low |
| 3 | G1 Finger tap no longer changes tool | High | Low | Low |
| 4 | L6 Re-parent on move | High (apparent data loss) | Low–Medium | Medium |
| 5 | P3 Move the cross | High | Low | Low |
| 6 | L2 + P1 Pickup without full raster | Very high (feel) | Medium | Medium |
| 7 | P2 Navigation over notes | High | Medium | Medium |
| 8 | L3 (b)(c)(d) Cheap test first, benchmarks | Medium | Low | Low |
| 9 | L7, L8, L9, P5, P6 | Medium | Low | Low |
| 10 | L10 Menu behaviour | Medium | Low | Low |
| 11 | P7 Commit without pre-flush | Medium | Low | **Durability** |
| 12 | B2 Eraser cliff | High, rare | Medium | Medium |
| 13 | L4 Coalesced lasso input | Medium | Medium | Medium |
| 14 | P8 items, control diffing | Low–Medium | Low–Medium | Low |
| 15 | B5, G5, B6: measure first | Unknown | — | — |

---

## 9. Regression risks and testing strategy

### Main risks

| Change | Risk | Mitigation |
|---|---|---|
| L1 | Filters, parent ownership and clipboard semantics change subtly | Keep `SelectionMoveSnapshot` logic for the first capture. Existing `SelectionTransactionTests` and `CanvasInteractionTests` must stay green |
| L2 / P1 | Preview no longer matches the committed result (masks, markers, stacking) | Pixel comparison of preview vs post-commit at several zooms |
| P2 | Tap, keyboard and VoiceOver flows | Run `StickyManipulationTests` and Post-it UI flows; check VoiceOver by hand |
| L6 | Undo restores wrong parents | Test undo/redo and reload |
| P7 | Lost edits on failed saves | Keep failure tests; review with sync; kill-app test |
| L10 | UI tests assuming the menu | Update them deliberately |

### Automated

- **Convert these probes into regression tests** (the probe sources are not in the repo; their raw results are in the appendix): selection identity, ink across note edge, hidden content, affine bounds, corner hit map, inline zoom font, finger-mode lasso UI test.
- **Extend `PerformanceTests`:** freeform lasso, page with post-its, pickup preview, post-it pickup. The current rectangle benchmark reports 0.6 ms while a freeform lasso takes 35 ms.
- **New UI tests:** pan from a note, tap on ink keeps the tool, 2-finger page turn in finger mode, undo clears the selection.
- **Signposts to add:** `lasso.pickup`, `sticky.pickup`, `canvas.update`.

### Physical iPad checklist (none run)

1. Pencil on a note: writes, highlights, and never moves the container.
2. Pencil on handles and the cross after P4.
3. Resting palm + Pencil: no tool switch, menu, scroll or zoom.
4. Lasso on a dense page at fit and at 4×: Animation Hitches during pickup, drag and drop.
5. Scroll and pinch on a dense page with post-its (B5), on the oldest supported iPad as well as a recent one.
6. Drag preview vs final position, with and without PDF background.
7. Is the `allTouches` check in `hitTest` reliable (P4)?

---

## 10. Exact files and functions to modify

| File | Functions / lines | Issues |
|---|---|---|
| `Editor/EditorSelection.swift` | `SelectionMoveSnapshot.init` (95-131), new ID-based init; `moveSelection`, `transformSelection` | L1, L3, L6, L7 |
| `Editor/SelectionActions.swift` | `selectionAction` (20), `affineSelection` (96) | L1, L8, L13 |
| `Editor/DocumentClipboard.swift` | `payload` (101), `contains` (33), `selectedElements` (15) | L1, L3, L7 |
| `Editor/PageSelectionView.swift` | `hostGestures` (64-65), `installSelection` (128), `updateDrag` (231), `transformDragged` (178), `render` (309), `StickyResizePreview` (383) | L1, L2, L4, L5, L8, L10, P1 |
| `Editor/PageScrollView+Selection.swift` | `configureSelection`: `directSelection`, `menuActions`, `moveBegan`, `moved`, `transformCommitted` | L1, L2, L11 |
| `Editor/InkCanvasView.swift` | `InkContentView`: new transient transform; `show` (559) preview mask; lasso touch routing (`begin`, 194) | L2, L4, P5 |
| `Editor/StickyInkIntegration.swift` | `attachingInk` (37) | L6 |
| `Editor/StickyNoteControl.swift` | `hitTest` (241), `point(inside:)` (235), `layoutSubviews` (251-278), `draft` (379), `beginInlineEditing` (341), `gestureRecognizer(_:shouldReceive:)` (175); delete dead controls | P2, P3, P4, P6, P8 |
| `Editor/PageScrollView.swift` | `hitTest` (63), gesture delegate (231-249), `fingerDrawing` (96) | P2, G3, G4, G5 |
| `Editor/PageScrollView+Notes.swift` | `tappedBackground` (17), `configureNotes` (80), `movePreviewBegan` (137), `resizePreviewBegan` (166), `control.edit` (177) | P1, P2, P8, G1 |
| `Editor/WritingCanvas.swift` | `updateUIView`: line 119; `onDirectSelection` (155-173); `Coordinator` undo observers (238) | G1, G2, L9 |
| `Editor/EditorSession.swift` | `apply` (372), `insertSticky` (14) | P7, P8 |
| `Editor/EraserEditing.swift` | `erase` line 31 | B2 |
| `Editor/TiledPaperView.swift` | `configure` (25), only if the ghost is confirmed | P8 |
| `OpenNotesTests/PerformanceTests.swift`, new regression tests | — | Section 9 |

---

## Implementation phases

### Phase A — Quick wins (low risk, immediate benefit)

- **L5** Finger-mode lasso touch types.
- **G2** Remove `WritingCanvas.swift:119`.
- **G4** Tie `pasteHold` to its menu flag.
- **G1** Finger tap no longer selects ink or changes tool.
- **G3** Stroke lock on finger gestures.
- **P3** Move the cross clear of the grip.
- **P6** Freeze zoom for inline editing.
- **L7** Filter hidden content.
- **L9** Clear selection on undo/redo.
- **L3 (b)(c)** Cheap test first, shared edges.
- **P5** Mask the live preview.
- **Tests and benchmarks** from section 9. Dead code removal from P8.

### Phase B — Core improvements

- **L1** Selection by ID. Do this first in the phase; it unblocks the rest.
- **L6** Re-parent on move.
- **L2 + P1** Pickup through existing layers, with cropped raster for elements.
- **P2 + P4** Object gestures hosted by `PageScrollView`, with the state model in section 3.
- **L8** Clamp and keep selection on failure.
- **L10** Menu on demand.
- **P7** Commit without pre-flush, with durability review.
- **Gesture pair list** replacing "always simultaneous".

Gate: Physical iPad checklist passes, with Hitches captured before and after.

### Phase C — Advanced optimization (only if evidence demands)

Do each only if its trigger is met.

| Change | Trigger |
|---|---|
| **B2** Eraser cliff removal | Do it if Precision stays exposed for long strokes |
| **L4** Coalesced lasso input | iPad video shows lasso visibly behind ink after Phase B |
| Off-main first snapshot | `lasso.snapshot` still causes hitches after L1/L3 |
| Control diffing | Pages with many notes show hitches on commit |
| Tile dirty rects | Slow-motion capture confirms the ghost |
| Per-note mask container, simpler outlines | Instruments confirms B5 |
| Metal / Rust | Only if all of the above are done and a measured limit remains. Nothing today supports it |

---

## Appendix — Probe results (raw)

```
selection.identity first=1 strokes, afterMoveOverB=2 strokes
selection.tap hit=1 stroke, onDrag(rect of bounds)=2 strokes
note.inkDraggedOut ok=true parentAfter=true visibleStrokes=1/2
note.inkDraggedIn ok=true parentAfter=false visibleStrokes=0/2
collapsed.hiddenChildElementSelected=true
collapsed.hiddenChildInkSelected=true
affine.inkOnly ok=true boundsAfter=(695.5, 995.5, 249.0, 309.0) pageSize=794x1123
affine.element.overflow ok=false
sticky.inlineEdit.zoom1to2 fontBefore=16 fontAfter=8.0
fingerMode.pen.undoEnabled=true
fingerMode.lasso.menuAppearedAfterDrag=false   (allowedTouchTypes = [])
fingerMode.lasso.menuAppearedAfterDrag=true    (control: allowedTouchTypes = [direct])
action.default path=nil, opacity=CABasicAnimation (implicit animation hypothesis rejected)
layout InkStroke.stride=232 InkStrokePoint.stride=72 PageElement.stride=288
```

```
PERF lasso.snapshot.rect4edges.300strokes            0.51 ms
PERF lasso.snapshot.freeform100/400/1200.300strokes  11.14 / 35.03 / 74.24 ms
PERF lasso.snapshot.freeform100/400/1200.1500strokes 7.46 / 42.07 / 107.47 ms
PERF lasso.snapshot.concave160edges.300/1500strokes  12.48 / 18.41 ms
PERF lasso.snapshot.5notes.pageInk300                206.47 ms
PERF lasso.snapshot.100childInkStrokes.noteFilterOff 160.97 ms
PERF lasso.counterfactual.current/sharedEdges/idLookup 25.12 / 17.54 / 0.05 ms
PERF lasso.pickup.preview.sync.300/1500strokes       490.87 / 573.62 ms
PERF sticky.move.begin.syncPreview.300strokes        730.17 ms
PERF sticky.configureNotes.2 rebuilds.5/20notes      7.09 / 33.32 ms
PERF sticky.elements.draw.screenSized                3.85 ms
PERF canvas.install.first/append1/move30.300strokes  2.63 / 0.14 / 0.64 ms
PERF canvas.install.first/append1/move30.1500strokes 14.02 / 0.77 / 4.98 ms
PERF artwork.init.pdf200pages / 5images              0.19 / 1.34 ms
PERF capture.fallback.pdf200pages                    75.80 ms
PERF eraser.precision.longstroke1000/3000            51.29 / 10184.90 ms
PERF eraser.stroke/standard/precision.dense300       1.27 / 3.74 / 56.98 ms
PERF render.image.dense300strokes.scale1/2           569.17 / 670.44 ms
PERF drawing.encode/decode.dense300strokes           233.17 / 99.20 ms (3,682,713 bytes)
PERF disk.save.20pdfs1000pages                       13.90 ms
```
