# Post-it 2.0

Scope: Post-it rendering, direct manipulation, inspector, exact-object layer actions and tests. Existing MCP/account/cloud changes were left intact. No dependency or document-version change.

## Behavior

- Tap an expanded note to select it, then drag its body with one finger. New notes are selected after insertion completes.
- Pencil input passes through the note interaction overlay to the existing ink canvas. Finger-drawing mode keeps unselected note bodies available for drawing.
- Selected notes show text, collapse, actions and resize controls. At small on-screen sizes, actions and resize move outside the body to preserve its drag target.
- Tap a collapsed note to reopen it; hold and drag to move it while closed. Reopening preserves the expanded size.
- Two-finger navigation starting over a note uses the parent viewport and cancels unfinished object gestures.
- Resize previews preserve the opposite rotated corner. Movement respects the page bounds of the note and its attached elements; locked descendants prevent manipulation.
- The actions menu provides text editing, customization, duplication, arrangement, lock and deletion. Exact-ID actions include descendants without capturing overlapping notes.

## Appearance and compatibility

- Square, slightly rounded and rounded corners; Paper and Card presets; custom background color; background opacity; border color/width; restrained shadow. Opacity changes the paper fill; ink occlusion continues to use object silhouettes.
- Common settings appear first; extra appearance settings, text formatting, size and rotation are disclosed on demand.
- The compact preview follows document scale; rich-text formatting is edited in the existing rich-text editor.
- New optional fields (`stickyCornerRadius`, `stickyOpacity`, `stickyShadow`) preserve legacy defaults. Existing stroke fields store borders. Validation covers document actions, import and disk persistence through the shared validator.
- Canvas, thumbnails and PDF export share the rendered silhouette. Attached elements and ink clip to sticky ancestors; collapsed descendants remain stored.
- Gesture updates remain transient until completion. Appearance Save uses the existing content transaction; Cancel discards the local draft. Existing combined ink/element undo and save/load paths remain in use.

## Verification

Validated on 1 November 2026 with Xcode 27.1 and an isolated iPad Pro 11-inch (M5), iOS 27.0 simulator (`OpenNotes Post-it QA`).

- Build succeeded, unsigned simulator configuration.
- 108 unit/regression tests passed: Post-it appearance/manipulation/actions/compatibility, rich text, attachment reconciliation, selection transactions, document foundation, native ink, ink pipeline, canvas interaction, clipboard, storage and PDF export.
- 3 UI flows passed: handwriting-first explicit text with collapse/reopen; move, resize, collapsed hold-and-drag, reopen, Card preset/save and exact-note duplication; pinch starting on the selected note zooms the canvas and adds no object-edit undo step.
- `git diff --check` passed. Inspector static risk scan has no high findings; its miniature preview deliberately uses document-scaled font sizes.
- Result bundle: `/tmp/CatNotesPostItFinalQA.xcresult`; log: `/tmp/catnotes-postit-final-qa.log`. Normal-light screenshots were reviewed for the inspector and overlapping duplicated cards.

The additional zoom/undo UI test passed separately; log: `/tmp/catnotes-postit-zoom-qa.log`. Both Xcode test commands completed with `TEST SUCCEEDED`.

Not verified on physical hardware: Pencil/finger arbitration, palm rejection and tactile feel. VoiceOver, largest accessibility text, dark/increased-contrast appearances, reduced effects, mixed-touch pure panning, and Instruments profiling with many overlapping notes still need a manual pass. No frame-rate or Apple-quality rating is claimed.
