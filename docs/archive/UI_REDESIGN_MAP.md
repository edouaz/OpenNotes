# OpenNotes UI integration — 2026-10-29

The existing SwiftUI shell is adapted in place. UIKit native ink input, document storage, canvas transforms and the renderer remain the existing implementation. Design tokens are OpenNotes calibration defaults, not measurements of proprietary Goodnotes UI.

## Screen and state map

| Previous view | Result | State/persistence |
| --- | --- | --- |
| `App/LibraryScreen.swift` single grid | Regular-width navigation rail, notebook header, grid/list picker, creation and bulk-move controls, cover accent, folder breadcrumbs, retained search and Trash | `libraryLayout`, `librarySort`, `appearance` (System/Light/Dark) in UserDefaults; folder/search/selection in view state; actual folder/favorite/title metadata in LibraryStore |
| Immediate new notebook | `App/NewNotebookSheet.swift`: title, cover color, actual paper template, A4 portrait/landscape | Existing NoteDocument.colorHex and NotePage.template/width/height; store flush before opening |
| `App/NotebookWorkspace.swift` tabs | Scrollable document tabs with dedicated Library control, active tab accent, title/rename/close | Existing openNotebooks/activeNotebook and one cached session per document |
| `Editor/EditorScreen.swift` quick actions | Navigation: Library/pages/search/read-only, document title, add/share/More; sidebar retained | Existing page position and session; read-only session guard; sidebar view state |
| `Editor/WritingInstrumentBar.swift` fixed four tools | Lasso fixed first, configurable writing tools, pinned Undo/Redo, image/text/shape insertion, Sticky, tool settings, palette toggle | Existing EditorToolSettings.toolbarOrder/hiddenTools; undoPlacement in UserDefaults |
| Tool options popover only | Compact active palette at top/bottom/left/right, edge switch by dragging, full options still available | toolPaletteDock/toolPaletteVisible; actual tool parameters in existing EditorToolSettings |
| `Editor/EditorInstrumentOptions.swift` color favorites | Independent tool colors, at most twelve, valid HEX input, reordering/removal/reset, retained pen styles and dynamics | Existing per-tool favoriteColors and instrument presets |

## Menu contracts

| Trigger | Content/action | Persistence and closure | Verification |
| --- | --- | --- | --- |
| Library rail / Show | Documents, Favorites, Trash | Existing filtered store queries, immediate | UI integration test and existing library tests |
| Library options | Import, new notebook/folder, filter, sort, grid/list | UserDefaults for layout/sort, actual importer/folder store actions | Existing import/folder coverage |
| New notebook | Title, cover, paper, orientation | Store update and flush; dismiss then open on success | GoodnotesUIIntegrationTests |
| Select notebooks | Selected count, move destination | Existing atomic LibraryAction.moveDocuments; exit selection on destination sheet | Existing folder tests |
| Notebook menu | Rename/favorite/move/Trash, or restore | Existing library mutation and recoverable deletion; native dismiss | Existing library tests |
| Tab chevron/close | Rename or close one tab | Existing flush before switch/close; errors retained | Workspace tests |
| Pages | Sidebar on regular width, sheet on compact width; navigate/reorder/duplicate/delete | Existing store operations; navigate actual page IDs | Existing pagination tests |
| Read-only | Toggle protected reading state | Session mutation guards and WritingCanvas reading mode; navigation/search/export continue | GoodnotesUIIntegrationTests + session guards |
| Insert | Image/text/shape/Sticky, capture area/page | Existing model forms and renderer; sheet/dialog dismissal | Existing element tests |
| Sticky shortcut | Choose background in the active palette, tap to create a structured note, switch to Lasso | Existing upsert transaction and StickyNoteSheet | Sticky integration and UI placement tests |
| Selected writing tool / sliders | Ballpoint/Fountain/Brush, pressure/tilt, stabilization, patterns, width, sharpness, colors | Existing preference methods, close with Done | Existing ink option tests |
| Eraser menu | Precision/Standard/Stroke, size, pen/highlighter filters, auto return, confirmed Clear page | Shared tool settings and session.clearPage transaction | Geometry/session tests |
| Lasso menu | Freehand/rectangle, selection inclusions | Existing tool settings, Done/outside dismissal | Selection tests |
| Color menu | Edit, move up/down, delete except last; add ≤12; reset current tool; HEX validation | favoriteColors keyed by tool; reset removes only current key | ToolSettingsTests |
| Toolbar layout | Show/hide and reorder allowed writing tools, fixed Lasso, Undo side, palette edge, reset | UserDefaults, sheet Done | Native SwiftUI list reorder, UI smoke |
| Share | Existing native archive/PDF export and activity sheet | Existing renderer, error handling and resource storage | Existing export tests |

## Visual and accessibility rules

Semantic system backgrounds and text colors support light/dark automatically; OpenNotesStyle centralizes accent/chrome/rail/canvas/control tokens. Controls retain 44-point targets, VoiceOver labels, dynamic text, scrolling overflow, safe-area placement and native sheets. Palette content scrolls at small dimensions or with twelve colors. History is pinned outside scrolling tool controls. Existing Reduce Motion handling remains in the editor.

## Actual limits requiring further work or device evidence

- Palette edge drag chooses the dominant drag direction; no proprietary Goodnotes animation or exact dimensions are claimed. Top/bottom palettes are horizontal, side palettes vertical.
- Sticky insertion uses a page-space tap and the shared session transaction; background choices are separate from ink colors.
- Creation supports the existing A4 format and four paper templates; no invented cover asset gallery is shown.
- Library imports/search/favorites/folders/Trash remain real existing features. No AI, audio, math recognition or collaboration command is added.
- Compact keyboard layout, old physical iPad, Pencil latency, contemporary Goodnotes screenshot parity and VoiceOver interaction require real-device validation; simulator success is not evidence for these.
- UI tests that created notebooks immediately now confirm the new notebook form. Historical tests that depend on removed prior toolbar layouts need selection by applicable behavior rather than treating all old snapshots as a valid design contract.
