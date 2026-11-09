# Build 17 — synchronization, Trash and MCP

## Findings and limits

On 2026-11-01 the configured Supabase project contained 17 current notebook heads. Each head referenced an existing private Storage object; no missing head revision was found. All revision checksum strings had the expected 64-character length. These checks verify references and object presence, not the readability or actual byte checksums of the user's private archives. The user's phone error has not been reproduced against those exact archives.

The previous generic `localizedDescription` discarded the decoding path. A missing required field, invalid archive, checksum mismatch or installation failure could all appear as “the data couldn't be read.” A single failed notebook also stopped every subsequent download.

InkStyle's synthesized Codable implementation required every property even when Swift supplied an initial default. Older style objects without newer fields were rejected. Build 17 supplies compatible defaults for absent style fields, while still requiring a numeric width and rejecting malformed values. This is a demonstrated compatibility defect, not a confirmed diagnosis of the particular phone failure.

## Application changes

- Decode older native ink styles using defaults for optional historical fields.
- Identify the sync stage, notebook ID prefix and JSON field path on failure, without displaying document contents or credentials.
- Continue other downloads after a notebook fails. Do not upload over the failed remote notebook or mark the overall sync successful.
- Delete a folder and all descendants by marking them deleted and moving their active notebooks to Trash. The existing primary library folder remains in place.
- Restore a notebook from a deleted folder into an available library folder.
- Empty Trash with confirmation. A per-notebook `purgedAt` marker is saved and synchronized so emptied entries remain hidden after restart and on updated devices.

Emptying Trash removes entries from the app library; it does **not** erase immutable cloud revisions or all local resource files. This is stated in the confirmation. Existing revision history remains available through the MCP. Use build 17 on all devices; older versions do not understand the new marker.

## MCP changes

The public endpoint responded to unauthenticated GET `/mcp` with HTTP 405 before providing an OAuth challenge. Build 17 checks authentication before rejecting unsupported methods, returning HTTP 401 plus `WWW-Authenticate` resource metadata for unauthenticated GET/POST. Protected resource metadata is also available at the root well-known path for client compatibility. Owner-scoped Supabase authentication and RLS are unchanged.

Local server verification: 20 tests passed, including HTTP discovery and MCP SDK discovery/execution. A real ChatGPT authorization and tool call with the user's account has not been performed.

## Build and verification

40 targeted iOS tests passed (CloudSyncTests, ClipboardAndFoldersTests, InkDocumentTests), including fresh-install restore/restart, folder-tree deletion, restore and emptied Trash persistence, legacy ink defaults and malformed input rejection. The final CloudSyncTests run passed all 28 tests, additionally verifying that an unreadable remote archive does not stop a valid download or get overwritten, and that its error stays visible instead of being replaced by the pending status. Across these targeted suites, 41 distinct iOS tests passed.

Device Release archive succeeded. The packaged IPA was checked for ZIP integrity, app/share build number 17, iOS 16 minimum, expected Supabase public configuration and absence of signing material. No private/admin API key is packaged.

Artifact: `build/artifacts/OpenNotes-build17-sync-trash-unsigned.ipa` with adjacent SHA-256 file. It requires signing with the same application identifiers/team as the installed app. Update in place; do not uninstall to install this build.

## Production deployment

With explicit user approval, the MCP fix was deployed to the existing Vercel project: `dpl_BrWyC9rzRqVrivHsC241FhmCN517` (READY). Production GET and POST `/mcp` both return 401 plus the OAuth metadata challenge when unauthenticated; both well-known metadata routes return the expected configuration. No user data was changed during these public HTTP checks. End-to-end ChatGPT account authorization is still unverified.

Final IPA SHA-256: `f45c30d0f54311b3a68d7a5925a60e0853dcf05abf182f3d14917dc00ad0b1b8`.
