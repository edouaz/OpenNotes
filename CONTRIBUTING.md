# Contributing to OpenNotes

Start with the [developer guide](https://edouaz.github.io/OpenNotes/develop.html) and [architecture](docs/ARCHITECTURE.md). The app is a prototype; small, focused fixes are welcome.

1. Open an issue describing the problem, device, iOS version and steps to reproduce. Use synthetic notes and remove personal information from screenshots.
2. Fork the repository and create a branch for one change.
3. Follow the surrounding Swift patterns. Keep local use independent of accounts, preserve iOS 16 compatibility and handle failed saves without dropping pending data.
4. Add or update a focused test for behavior changes. Run affected tests, then the unit suite. For canvas or layout changes, run the relevant UI tests and include a screenshot.
5. If files were added or removed, run `python3 scripts/generate-project.py` and commit the generated Xcode project. Change build settings in that script so regeneration preserves them.
6. Open a pull request explaining the problem, behavior after the fix, checks performed and any hardware testing still needed.

Commit each coherent feature or fix with its related tests, fixtures and generated project changes. Keep unrelated work in separate commits, and keep each commit buildable so it can be reverted on its own. Use descriptive messages such as `fix(editor): preserve selection while dragging` or `feat(mcp): mark matching text`. Push the branch and open a pull request once the relevant checks pass; preserve these commits when merging if they remain useful rollback points. If a published change causes a regression, use `git revert <commit>` and submit the revert through a pull request.

For server changes, run `cd server && npm ci && npm test` with Node.js 22 and Poppler installed (`brew install poppler` on macOS, `apt-get install poppler-utils fonts-dejavu-core` on Debian/Ubuntu). GitHub Actions runs these tests independently of the iOS suite.

Do not commit credentials, signing certificates, provisioning profiles, personal notebooks, DerivedData or IPA files. `Config/Supabase.plist` is local and ignored. Cloud work must retain row-level security and reject privileged keys in the app.

The GitHub Actions workflow builds and runs unit tests on an available iPad simulator. Simulator tests do not establish physical Pencil latency or compatibility with every iOS 16 device.
