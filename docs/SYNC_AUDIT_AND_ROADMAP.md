# OpenNotes — sync audit, decision and roadmap

Date: 2026-11-05. Branch `codex/account-persistence-sync`. Based on reading `CloudSync.swift`, `CloudFolders.swift`, `LibraryStore.swift`, the four Supabase migrations and `server/`. Earlier audits (`MCP_SYNC_AUDIT_2026-11-01.md`, `SYNC_BUILD17.md`) were taken as context, not as proof.

Status labels: **CONFIRMED** (read in code or reproduced by a test), **ARCHITECTURAL** (design limit), **HYPOTHESIS** (needs a test on real infrastructure).

## 1. Current infrastructure

| Layer | What exists |
| --- | --- |
| Local storage | `LibraryStore`: JSON library snapshot + resource files on disk, atomic writes, `flush()`. Sync state in `cloud-state.json` (atomic, rolled back on write failure). |
| Unit of sync | One immutable **whole-notebook archive** (`.catnote` JSON: note, pages, base64 resources: native ink, PDFs, images, sticky notes). SHA-256 over sorted-keys encoding. |
| Cloud | Supabase project `evuqpcklfxxnjzjcrwos`: Auth (email/password + OAuth 2.1 server for MCP), Postgres (`notebook_revisions`, `notebook_heads`, `cloud_folders`, audits), private Storage bucket `notebooks`, `mcp-transfers`. RLS on every table, no service-role key in the app. |
| Write protocol | Upload immutable object, then RPC `commit_notebook_revision(expected_revision)` under a per-notebook advisory lock. Stale head returns `40001`. Clients cannot update or delete revisions or heads. |
| Conflicts | Notebook: both versions kept (remote copy imported as "· remote revision"), explicit user choice. Folders: fingerprint + `updated_at` compare-and-swap, explicit choice. |
| Deletes | Soft: `deletedAt` / `purgedAt` live inside the archive, so they replicate as ordinary revisions. Nothing is ever hard-deleted in the cloud. |
| Triggers | Debounced 1 s after save, foreground, `NWPathMonitor`, 30 s poll while active. |
| MCP | `server/` (Node 22, Streamable HTTP, Vercel container). Uses the caller's token, so RLS applies. Reads/edits through the same head/revision protocol. No permanent delete. |
| CLI | None. |

## 2. Defects

### Confirmed
1. **One bad notebook blocked all uploads** (fixed, see §5). The upload loop had no per-notebook isolation: a single 413 (archive over the Free 50 MB limit), stale-head or encoding error aborted the pass, so every later notebook never synced, on every retry.
2. **Fixed-rate retry.** Failures retried every 30 s forever (fixed, §5).
3. **Backend is untracked in git.** `server/` and three of four migrations are `??` (never committed) on this branch, along with ~60 modified files. One disk failure loses the backend and the only record of the schema. **Commit them.**
4. **Server tests are not hermetic.** `npm test`: 18/20 pass; the 2 failures need `pdftoppm` (Poppler), absent on this Mac (`brew install poppler`). Environmental, but CI must install it.
5. Local `cloud-state.json` `seen` set grows without bound (cosmetic).

### Architectural
- **Whole-archive re-upload on every edit.** A 40 MB PDF notebook uploads 40 MB per change, and every revision is kept forever. Free Storage (1 GB) is exhausted fast. No garbage collection exists, and orphan objects from failed commits are never removed. This is the main cost and bandwidth risk.
- **No persistent operation queue.** State is derived: each pass diffs local checksums against `links`. This is *correct and restart-safe* (nothing is lost on relaunch, because dirtiness is recomputed from content) and simpler than a queue. The cost is no per-operation retry/error history, only per-notebook last error.
- **Conflict granularity is the whole notebook.** Two devices editing different pages still produce a conflict copy. Safe (no silent overwrite), but noisy.
- **No background sync** when iOS suspends the app.
- **Remote-vs-local change detection compares encoded bytes.** The MCP writes `JSON.stringify` (unsorted keys) while the app writes sorted keys. This stays correct (the app installs when its local checksum equals its recorded link) but means checksums are not comparable across writers. Normalize in one place if a CLI is added.
- **MCP token audience is not validated** (`getUser` only). Spec asks for audience binding. Not a data-loss risk; a security hardening item.

### Hypotheses to test on real infrastructure
- Real 2-device round trip with Supabase (only mocked transports and local Postgres have been exercised).
- Behaviour at the 50 MB upload cap (now isolated, but the user-facing message should say "too large").
- Lost commit response after a successful RPC (code path exists and has a download-side recovery; no live test).
- Storage API deletion of `mcp-transfers` objects.

## 3. Supabase decision

**Keep Supabase.** Auth, RLS-enforced Postgres, private Storage and OAuth 2.1 for MCP in one product, usable from a thin client without a custom backend, is exactly the "simple, cheap, secure" fit. The existing schema (immutable revisions + CAS head, no client UPDATE/DELETE on history) is sound. No alternative offers a concrete advantage worth a migration: Firebase lacks Postgres/RLS semantics, CloudKit would lock out CLI/Linux/MCP, and a self-hosted stack adds ops burden.

Limits to plan around: Free tier 1 GB Storage / 50 MB per object / project pausing after inactivity. The pressure point is storage growth from whole-archive revisions, not Supabase itself. Mitigations in order of effort: (1) retention job keeping last N revisions + any revision referenced as a conflict (SQL cron or manual script, never client-side); (2) upload large resources (PDFs) as separate content-addressed objects so unchanged PDFs are not re-sent; (3) Pro plan only when real usage requires it, with the user's approval.

## 4. Local-first sync architecture (target)

What already holds and should be kept: local save is independent of network; state is recomputed from content so relaunch loses nothing; immutable revisions + CAS head prevent silent overwrite; conflicts preserve both sides.

Next increments, in order:
1. **Per-notebook sync state** exposed to UI (synced / pending / failed with reason / conflict), replacing the single global status string.
2. **Content-addressed resource objects** (PDFs, images) uploaded once; archive references them by hash. Largest win for cost, speed and the 50 MB cap.
3. **Revision retention** job (server-side, dry-run first).
4. **Page-level merge** for the common case (different pages changed) before falling back to a conflict copy.
5. **Background tasks** (`BGAppRefreshTask`) for best-effort catch-up.

Rejected for MVP: CRDTs (no concurrent live co-editing requirement; copy-on-conflict suffices), a separate operation-log table (derived state is already restart-safe).

## 5. Implemented in this pass

- `CloudSync.sync()`: per-notebook upload isolation. Failures are collected and reported (`N notebook(s) could not be uploaded`), the pass still commits the others, and the global phase is `failed`, never `synced`. Auth loss (401), network loss and cancellation still abort the pass so they are classified correctly.
- Poll loop backoff: 30 s doubling to 10 min while `failed`/`offline`; any success resets to 30 s. Saves, foregrounding and network return still sync immediately.
- Test `testOneNotebookUploadFailureDoesNotBlockOtherUploads` in `CloudSyncTests`.

No migration, schema or data change was made. No paid service was created.

## 6. Test report

`CloudSyncTests` on the iPhone 18 Pro simulator: **29 tests, 0 failures** (28 existing + the new upload-isolation test), 2026-11-05. Only that suite was run, not the full unit suite. Already covered by existing suites (not re-run end-to-end here): offline retry, concurrent-edit preservation, restore on fresh install and after restart, folder conflicts and cycles, folder-tree delete + Empty Trash persistence, unreadable remote notebook isolation (download side). **Not yet covered:** two physical/independent devices against real Supabase, and sync of PDF + sticky + ink in a single cross-device round trip. These are the first things to run on a disposable account.

## 7. CLI and MCP design

**Do not build a second implementation.** The MCP server already exists and encodes the business rules (validate archive, read head, commit with expected revision). The CLI should wrap the same module.

- **Language: TypeScript (Node 22).** The archive validator, repository and operations already live in `server/*.mjs`. Rust would force a rewrite of `archive.mjs`/`operations.mjs` and a parity test burden for no user-visible gain at this scale. Distribute via `npx`/npm; revisit a single static binary (Bun/`pkg`, or Rust) only if install friction appears. Auth tokens in the OS keychain (`keytar`), never plaintext files.
- Layout: extract `server/` into `core/` (repository, archive, operations) + two thin front-ends: `cli/` and `mcp/`. Both call `core`; neither contains rules.
- Commands (to validate): `opennote auth login` (device/OAuth PKCE), `documents list|get|export`, `sync status`, `mcp serve` (stdio).
- **Local MCP:** stdio transport, launched by the agent host as `opennote mcp serve`, uses the CLI's stored session. **Remote MCP:** the existing Streamable HTTP service with OAuth 2.1 (already built). They share `core`.
- Permissions: read tools by default; write tools require explicit `--allow-write`; delete is **not exposed** (trash/restore only, as today); `permanent delete` stays out of scope.
- Sync ≠ MCP: sync keeps replicas consistent; MCP is an agent interface over the cloud head. The CLI never talks to the iPad directly.

## 8. Roadmap

1. Commit `server/`, migrations and this work (needs your OK; ~60 modified files are unrelated and uncommitted).
2. `brew install poppler`, CI installs it, get server tests to 20/20.
3. Run the real two-device scenario on a disposable account: create → edit → restore on 2nd device → delete → concurrent edit → airplane mode → resume.
4. Per-notebook sync state in the UI.
5. Content-addressed PDF/image resources.
6. Revision retention job (dry-run, with backup).
7. MCP token-audience check.
8. Extract `core/`, ship CLI, add stdio MCP.
9. Page-level merge, background refresh.
