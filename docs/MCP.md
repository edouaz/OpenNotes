# OpenNotes remote MCP

`server/` is a Node 22 service exposing Streamable HTTP MCP at `/mcp`. It uses the same Supabase account, private notebook archives, revision heads and conflict rules as the iPad application. It can operate while the iPad is offline. Changes become visible when the app next synchronizes.

The database and private-transfer migrations are applied to the existing **Test** project (`evuqpcklfxxnjzjcrwos`), including `20261031152942_mcp_transfers.sql`. Live transaction checks verified notebook owner isolation, rejection of stale revisions, and denial of direct head writes. Transfer policies are owner-scoped; Storage API transfer deletion still requires an authenticated end-to-end check (direct SQL deletion is prohibited by Supabase).

Production deployment `dpl_4NngpM77VuqtzV6nJSWoJx7bxXgQ` reached READY on Vercel Hobby. The endpoint is `https://opennotes-mcp-edouazs-projects.vercel.app/mcp`. Public discovery returns 200 and unauthenticated MCP requests return 401. Supabase OAuth and dynamic registration are enabled with the approved HTTPS Site URL and `/oauth/consent` path. The public signing key is ES256. A real client registration returned 201 and authorization redirected to the deployed consent page, whose login form was verified in a browser. No Vercel SSO protection setting was changed. The public test client is named **OpenNotes connection check**; it has not been granted access to any user account.

Vercel's Container Runtime is available in beta on the Hobby plan. Point the Vercel project root at `server/` and select the Container framework; the existing Dockerfile includes Poppler and Unicode fonts and listens on port 3000. Vercel routes all requests to it. The production aliases are reachable under the project's existing protection settings; preview/deployment protection was not disabled. MCP operations require a user bearer token. Hobby usage limits apply. See [Container Runtime](https://vercel.com/docs/functions/runtimes/container).

## Run and deploy

Install Node 22 and Poppler (`pdftoppm`), then run `npm ci` and `npm test` in `server/`. The Dockerfile includes Poppler and DejaVu fonts. For local container verification, build with `docker build -t opennotes-mcp server`. Do not copy local `.env` files or `node_modules` into the image; `.dockerignore` excludes them.

Configure only:

- `SUPABASE_URL`: the project's HTTPS origin, without trailing slash.
- `SUPABASE_PUBLISHABLE_KEY`: `sb_publishable_...`; never a secret or service-role key.
- `PUBLIC_ORIGIN`: the public HTTPS origin, without a path or trailing slash.
- `PORT`: internal port, default `3000`.

Optional access policy (all default to the safest value):

- `ALLOW_WRITE=true`: register the write tools. **Default: read-only**; write tools are not even listed to the agent.
- `ALLOW_DESTRUCTIVE=true` (needs `ALLOW_WRITE`): register `remove_element`, `remove_ink`, `reorder_pages`, `restore_revision` and allow `trashed: true`. These carry `destructiveHint`. Unknown future tools default to "write".
- `REQUIRE_OAUTH_CLIENT=true`: accept only tokens that carry a `client_id` claim (issued through the OAuth consent flow), rejecting the app's own password-login session tokens. Leave off until a real client authorization has been validated end to end, then turn it on.
- `RATE_LIMIT_PER_MIN` (default 120 per user), `IP_RATE_LIMIT_PER_MIN` (default 600 per address, applied before the token check): HTTP 429 with `Retry-After`.
- `MAX_BODY_MB` (default 8; Vercel itself caps bodies at 4.5 MB): larger files use the transfer tools.
- `ALLOWED_ORIGINS`: extra browser origins accepted besides `PUBLIC_ORIGIN`. Requests carrying any other `Origin` header get 403 (MCP clients send none).

Token audience: Supabase's OAuth server does not issue resource-bound (RFC 8707) tokens, so the audience cannot be pinned to this server; the `client_id` requirement above is the available narrowing. Revoke a client in Supabase Auth.

TLS terminates at Vercel. The process listens internally over HTTP. The Dockerfile supplies regular, bold, italic and bold-italic Unicode fonts through `NOTES_FONT_*`; direct local runs default to Helvetica unless those paths are provided.

Enable the [Supabase OAuth 2.1 server](https://supabase.com/docs/guides/auth/oauth-server/mcp-authentication) and dynamic client registration. Set the Auth Site URL to `PUBLIC_ORIGIN` and the authorization path to `/oauth/consent`. Configure asymmetric signing keys as required by Supabase's OAuth server. Connect the chatbot to `PUBLIC_ORIGIN/mcp`. OAuth discovery identifies Supabase Auth as the issuer; the consent page signs the user into that same account and explicitly offers Allow/Deny. Revoke client grants through Supabase Auth. The service validates every bearer token with `getUser` and makes storage/database requests with the user's token, preserving RLS. No administrator key is used.

## Operations

The application exposes **Account and connections** from the person button in the library toolbar. Create/confirm an account, sign in, then explicitly link and sync the library. The **Assistants** section copies the production MCP endpoint and explains signing into the same account from an OAuth-capable chatbot. It does not claim a connected assistant merely because the endpoint is configured. See [account and sync workflow](SUPABASE.md). Pausing app sync or signing out on the device does not revoke existing chatbot grants; a client inventory/revocation screen and web signup/recovery are not part of this app refinement.

Tools support:

- Listing, reading, creating, renaming, moving, favoriting, trashing and restoring notebooks.
- Listing and creating folders; rename, move, trash and restore with `expectedUpdatedAt` to prevent stale writes. Folder changes have readable audit history. Trashing a folder hides its container; it does not delete its documents.
- Reading/searching extracted text and titles, including paginated search across notebooks.
- Appending blank or PDF pages, editing page text/bookmarks/paper, reordering pages and removing pages while retaining their historical archives.
- Adding and editing text, highlights, rectangles, ellipses, lines, arrows and sticky notes; inserting PNG/JPEG images; adding and removing editable native ink strokes.
- Moving/rotating a sticky note together with attached content. Resizing its frame preserves ink coordinates. Removing it also removes its attached content from the new revision.
- PDF export and page renders returned as actual MCP PNG image content so chatbots can inspect handwriting and visual exercises.
- Reading revision history and restoring a historical archive as a new head. Every notebook mutation records an immutable revision and an audit entry. There is no permanent-delete operation. The app keeps only the newest 10 revisions per notebook (older ones are pruned daily), so "recoverable through revision history" means those ten.

Every existing-notebook write requires the revision returned by the previous read. A stale writer receives a conflict and must read again. `reorder_pages` omits/removes pages only from the new revision; at least one must remain. Typed annotation edits replace that annotation's previous rich formatting. Archive reads include base64 resources and can be large; use `render_page` or text search when sufficient. For larger files, use `create_upload`, PUT bytes to its signed URL with `Content-Type: application/octet-stream`, then call `import_uploaded_pdf` or `add_uploaded_image`. Imports delete their transfer after publishing; if `cleanupRequired` is returned, call `remove_transfer`. `download_notebook` and `download_pdf` return private five-minute links and a path; call `remove_transfer` after downloading. A signed URL is a bearer secret. URL expiration does not delete its object, so unused or failed transfers need explicit cleanup. These temporary files use a separate private, owner-scoped bucket and never change immutable history. Search uses stored text/OCR, and does not perform fresh handwriting recognition.

## Data and safety

`commit_notebook_revision` validates the owner-scoped object path, requires an uploaded immutable object, takes a per-notebook transaction lock, checks the expected head, then publishes revision/head/audit atomically. Failed commits can leave an unreferenced immutable object; no automatic deletion occurs. Existing legacy revisions were seeded into heads without deleting history. Old application versions that bypass the head RPC must not participate in the new synchronization protocol.

The RPC is intentionally `SECURITY DEFINER`: authenticated users cannot directly update heads or forge audit records. It checks `auth.uid()` and uses an empty fixed search path. Supabase's security advisor reports [the intentional authenticated definer warning](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable) for this elevated function; the warning is understood and should remain part of review when changing the RPC. Folder audit writes use an equally narrow owner-checked trigger. All exposed tables enforce account RLS; audit/history are readable but cannot be edited or deleted by clients.

Vercel caps HTTP request and response bodies at 4.5 MB, including base64 encoding; use the transfer tools for larger files. This Supabase Free project has a [maximum 50 MB file upload limit](https://supabase.com/docs/guides/storage/uploads/file-limits), which takes precedence over bucket limits and applies to the entire encoded notebook archive. Inputs are otherwise bounded: `MAX_BODY_MB` direct HTTP request bodies (default 8 MiB), 50 MiB PDF import, 20 MiB image import, 150 MiB stored archives, 10,000 pages, and bounded annotation/ink complexity. Archives validate structure, safe resource names/base64, page references, element parents and ink geometry. PDF/image decoders additionally validate imported media. Oversized or unsupported files return errors instead of publishing partial changes.

## Rendering limits and verification

Page images are automatically scaled down when necessary to fit the Vercel response limit. The renderer covers blank/ruled/grid/dotted paper, PDF crop/quarter-turn rotation, PNG/JPEG backgrounds, native shape/text/image elements, basic styled RTF, rotated annotations, solid/dashed/dotted/tapered ink, erased vector outlines and sticky-note clipping. Text content is checked against parsed RTF before rendering. Invalid or unsupported inputs fail explicitly.

The server renderer uses different fonts and text layout from UIKit. Complex RTF tables/lists, exact native font shaping, pressure/opacity interpolation and marker blending may differ. Rendered PNG/PDF output is suitable for visual reading, but is not a byte-for-byte or pixel-identical native export. Retain the native archive for editable recovery; no renderer output replaces stored ink or resources. A native-versus-server visual comparison on real notes remains to be done.

`npm test` passes 20 tests covering archive rejection, edits without mutating original archives, attached sticky ink, PDF import/export and rotation/crop, mixed-style RTF, actual PNG rendering, checksum tampering, publication conflicts, private transfers, official MCP SDK discovery/execution and unauthenticated HTTP discovery/challenges. Live database checks are separate from these local tests. Production discovery, registration, authorization redirect, visible login form and anonymous rejection are verified. Token exchange and authenticated production operations still require signing in with an actual app account; no user credentials were entered during validation. Production rendering load has not been validated.

## Local CLI and stdio MCP (`server/cli.mjs`)

Read-only by default, same repository/MCP code, user session only (RLS), no service key. Set `OPENNOTES_SUPABASE_URL` and `OPENNOTES_SUPABASE_KEY` (publishable key), then:

```
node server/cli.mjs login you@example.com     # session stored in ~/.opennotes/session.json (0600)
node server/cli.mjs documents list [query]
node server/cli.mjs documents get <id>        # resources omitted
node server/cli.mjs documents export <id> out.catnote
node server/cli.mjs sync status
node server/cli.mjs mcp serve [--allow-write] # stdio MCP for a local agent host; destructive tools never exposed
```

`list`, `sync status` and `list_notebooks` need migration `20261106000002_notebook_meta.sql` and one app sync. Revision history keeps the newest 10 per notebook once `20261106000001_prune_revisions.sql` is applied.

## Remote deployment check (2026-11-06)

Discovery returns 200 and unauthenticated calls 401, but a request with a foreign `Origin` also returns 401 instead of 403: **the deployed build predates the Origin check, rate limits and read-only policy in this repo.** Redeploy before relying on them. Full OAuth token flow with a real client is still unverified; keep `REQUIRE_OAUTH_CLIENT` off until it is.
