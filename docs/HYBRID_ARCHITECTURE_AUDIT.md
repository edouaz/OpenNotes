# Hybrid architecture audit — 2026-11-02

## Decision

Keep the current native application and backend. Defer Rust adoption until profiling or a second-platform consumer justifies its build and interoperability cost. First isolate shape recognition from editor orchestration and run its existing contract tests without the application. This removes an unnecessary UIKit dependency without changing algorithms, documents or interaction.

## Current state and boundaries

The repository contains an iOS/iPadOS 16+ SwiftUI application, UIKit drawing/editor code, a share extension, XCTest/UI tests, a Node.js MCP service and Supabase SQL migrations. `scripts/generate-project.py` owns the Xcode project; its Swift language setting is 5. The Apple project uses system frameworks; the server has its own npm dependencies (MCP SDK, Supabase JS, PDF/font/RTF parsing and Zod). No Cargo workspace or Rust bridge currently exists.

| Component | Classification | Reason and next action |
| --- | --- | --- |
| SwiftUI views, LibraryStore, native editor coordinator | KEEP SWIFT | Native presentation and observable UI state; keep SwiftUI primary. |
| InkCanvasView, Pencil samples, predictions, gestures, sticky controls | KEEP SWIFT | Latency-sensitive UIKit interaction; do not cross FFI per sample/frame. |
| PageRenderer, CGPath erasing, PDFTextIndex, OCR/rich text | KEEP SWIFT | Core Graphics, PDFKit, Vision and UIKit provide platform behavior. |
| ShapeRecognition math, hierarchy validation | RUST CANDIDATE | Small deterministic contracts; isolate and test first. Core Graphics point/transform types still need a portable representation before Rust. |
| NoteDocument/NotePage and InkDocument Codable models | KEEP AS IS | Existing versioned files and compatibility defaults outweigh a second model/serialization layer. Reconsider with an actual second client. |
| EditorSession undo/history | KEEP SWIFT | UndoManager, committed drawing state, sticky reconciliation and autosave form one correctness boundary. |
| DiskStore and NotebookArchive | INVESTIGATE | Portable packaging/validation may eventually be shared, but current code mixes atomic disk operations, native validation and thumbnail rendering. Establish archive fixtures before extraction. |
| CloudSync | INVESTIGATE | Domain revision/conflict decisions could be portable; Keychain, CryptoKit, network monitoring and lifecycle remain platform adapters. |
| Supabase auth/database/storage and SQL/RLS | KEEP AS IS | Already supports native and MCP consumers; no cloud replacement or paid service is justified. |
| Node MCP service and archive validation | KEEP AS IS | Already independent of Swift. Cross-language archive consistency is a stronger immediate need than rewriting the service. |

Local persistence is owned by the DiskStore actor in `NotebookArchive.swift`: atomic metadata/journal/backup operations and separate resources. Legacy CatNotes directory and interoperability identifiers are compatibility keys. Notebook archives accept versions 1–2; ink supports schema-versioned JSON and old PencilKit data has explicit compatibility limits. Keep optional fields, IDs, dates, resource naming and validation behavior stable.

CloudSync uses authenticated Supabase requests, per-account binding, immutable uploads and optimistic revision commits, with conflict copies. The Node service has a second archive validator and renders through PDF libraries/native tooling. `docs/MCP_SYNC_AUDIT_2026-11-01.md` records an unresolved installation/encoded-data failure: outbound archive validation checks drawing resource presence while installation decodes the drawing. That is an investigation lead, not a demonstrated cause. Do not make a format migration while this remains unexplained.

## Benefits, costs and risks

The first change makes recognition independently compilable/testable on macOS with Foundation/Core Graphics. It separates pure calculation from undoable editor mutation, preserving all callers and the existing algorithm. It does **not** establish Windows/Linux/Android portability or a speed improvement.

A Rust core could later share validation, geometry and conflict decisions across clients. Its costs include DTO conversion, errors/cancellation/ownership across FFI, Apple device/simulator build artifacts, generated bindings and two-language debugging. A tiny math port alone does not repay those costs. CGPath clipping, rendering, Pencil calibration and native undo are especially poor first migrations.

Performance-sensitive areas include input processing/preview, shape fitting, eraser intersection, large-page rendering, JSON/base64 archive memory, thumbnails, and cloud hashing/upload. The eraser already builds a spatial index per gesture. No profiler evidence currently establishes a Rust-worthy bottleneck.

## Migration order and acceptance gates

1. Isolate recognition math and reuse its existing XCTest contract on the host and in iOS tests. Keep all UI and persisted data unchanged.
2. Add shared synthetic archive acceptance/rejection fixtures for Swift and Node, including schema versions, date encoding, missing/corrupt drawing resources, hierarchy and resource limits. Reproduce the reported sync failure before changing validators.
3. Measure representative large-page recognition/erasing, document load/save, peak archive memory and sync conflict behavior. Record hardware, inputs, release configuration and latency distributions; do not infer Pencil responsiveness from host tests.
4. Only with measured need or an active second client, pilot a single batch operation in Rust. Evaluate UniFFI against a small C ABI using current official documentation at that time. Keep primitive/value DTOs at the boundary; preserve validation, errors and cancellation. Never route per-frame Pencil input through it.
5. Before shipping a bridge, require reproducible builds for the actual iOS device/simulator architectures and minimum OS, Swift/Rust parity tests, malformed-input tests, verified archive compatibility, and physical iPad regression checks. Expand only after those gates pass.

No Rust dependency, generated bindings, duplicate document model or alternate sync engine is introduced by this step. Existing user modifications are preserved. See the implementation's validation report for checks actually executed; this audit is source inspection, not a security certification or device benchmark.

## Validation completed

- Isolated macOS recognition target: all 4 existing XCTest cases passed with Xcode 27.1 (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh scripts/test-shape-recognition.sh`). The default command-line-tool selection and sandbox caches initially prevented compilation; the Xcode toolchain outside the sandbox succeeded.
- iOS app/test build and all 263 OpenNotesTests passed on the available iPhone 18 Pro simulator (iOS 27.0), using signing-disabled `xcodebuild test` and separate `/tmp/opennotes-hybrid-validation` derived data. No iPad simulator was available. Simulator results do not establish iOS 16 or physical Pencil behavior.
- Server suite: 19/20 passed together outside the sandbox; HTTP discovery failed at its startup polling assertion. That HTTP test passed when rerun alone. Do not describe the full server suite as a clean pass. The initial sandbox run also prohibited its localhost listener.
- Website appearance regression check and `git diff --check` passed.
- Generated project/scheme compared byte-for-byte against generation in a temporary directory with the same source/config inventory; both match, and existing project files were not overwritten.
- Source comparison confirms recognition math and the relocated editor method are unchanged apart from the algorithm file's UIKit-to-CoreGraphics import.

Not performed: UI automation, device/Pencil latency or pressure tests, benchmarks, production sync/auth checks, or a Rust/UniFFI build. No performance gain or cross-platform runtime support is claimed. The documented real-device sync failure remains unresolved.
