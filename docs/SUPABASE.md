# Supabase — account, sync and validation

OpenNotes uses Supabase Auth for its application accounts and the remote MCP service uses the same accounts. These are separate from Supabase dashboard or Vercel administrator credentials. No default application email or password is supplied.

## Application workflow

1. Open **Account and connections** using the person button in the library toolbar.
2. Choose **Create account**, enter your email and password twice, and submit. If email confirmation is required, follow the email link, return to OpenNotes and choose **Sign in**. Account creation does not silently upload the library.
3. Choose **Link and sync this library**. Wait for **Synced** before expecting the library to be available to another device or assistant.
4. Sync runs automatically after local saves, on returning to the app, and after a network connection returns. The bottom-left library indicator opens account details and a retry action. **Pause sync** stops app synchronization; **Resume sync** restarts it. Signing out removes the session on this device and stops requests; signing back into the same linked account resumes automatic sync unless it was explicitly paused. Neither action deletes local notebooks, cloud revisions or existing chatbot authorizations.

A local library is linked to one account. Signing into a different account does not upload that library to the new account. Use the original account to resume it; account migration is not provided by this screen.

Tokens are stored in the device-only Keychain and become accessible after first unlock. Password inputs are cleared after authentication attempts. An invalid/expired session prompts another sign-in and stops automatic requests until sign-in succeeds. Temporary network failures preserve the session and allow subsequent retries. A restored session is not proof of a fresh successful connection.

## Assistant workflow

The **Assistants** section copies `https://opennotes-mcp-edouazs-projects.vercel.app/mcp`. Add it to an OAuth-capable chatbot, sign into the same application account on the authorization page, and choose **Allow**. The app does not connect to arbitrary MCP servers and does not infer an active chatbot connection from a saved URL. Authorized assistants access the cloud while the iPad is closed; their changes appear on the next app sync.

Web signup, password recovery, an authorized-client list and user-facing grant revocation are not implemented by this screen. App sign-out does not revoke an assistant's grant. See [MCP deployment and validation](MCP.md) for server configuration, tools and the distinction between verified public endpoints and the unverified signed-in production round trip.

## Configuration and data

The existing **Test** project (`evuqpcklfxxnjzjcrwos`) has been configured in the previous deployment work. `Config/Supabase.plist` is ignored by Git; it contains the HTTPS project URL and a publishable key. The configuration loader rejects secret keys and privileged-role JWTs. The project generator includes the plist when present. No privileged backend key belongs in the app.

For a new environment, apply all migrations in order:

- `202610210001_notebooks.sql`
- `20261030001002_notebook_heads_mcp.sql`
- `20261031095542_notebook_foreign_key_indexes.sql`
- `20261031152942_mcp_transfers.sql`

Private Storage contains immutable notebook archives, including native ink and source PDFs. Postgres holds owner-scoped revision metadata, heads, folders and audit records. The client uploads an immutable object and publishes its revision through `commit_notebook_revision` with an expected head. Stale updates are rejected. Unchanged remote documents update existing local documents; concurrent changes preserve both versions for explicit resolution. Cloud state is stored atomically in the library's `cloud-state.json`.

Local saves debounce synchronization by one second. The app also checks for remote changes every 30 seconds while active. Local writing does not wait for the network. Busy editors and edits made during network requests remain pending; conflicts and save failures do not show a successful sync. The last complete successful synchronization is persisted in cloud state and shown separately in account details. It is a historical timestamp, not proof that later edits are backed up.

Background transfer while iOS suspends the app is not guaranteed. A failed publication can leave an unreferenced immutable object. Supabase Free's global upload limit applies to the entire encoded archive; a larger bucket limit does not override it.

## Validation boundaries

`OpenNotesTests/CloudSyncTests.swift` covers account response validation, verification-required signup, session identity, expired-session recovery, retry behavior, atomic publication, in-place updates, conflict preservation, persistent success timestamps, state-write rollback and local save scheduling with injected network responses. `scripts/test-rls-local.py` checks owner isolation, immutable revisions, expected-head commits and folder cycles in disposable PostgreSQL with Supabase schema stubs. Tests are not a substitute for real Supabase email delivery, Storage API calls or a signed-in chatbot.

Previous live database checks verified account isolation, stale-head rejection and denial of direct head writes. Production public discovery and the beginning of OAuth were verified previously; the full real-account create/confirm/sync/assistant read-write cycle remains to be tested. Use a disposable notebook for that check and verify the return change in the app.

Validation on 2026-11-01 (branch `codex/account-persistence-sync`): the final Xcode 27.1 simulator `build-for-testing` passed, as did the disposable PostgreSQL checks and `git diff --check`. An interrupted iPad run recorded 14 passing sync tests, including offline retry, concurrent-edit preservation, automatic scheduling and mocked restoration after restart. The complete unit suite and the indicator UI test did not finish: isolated simulator startup stalled, and Xcode reported `invalidDigitCount` SDK/runtime metadata errors. These are partial execution results, not a complete suite pass. Real Supabase and multi-device round trips remain unverified.
