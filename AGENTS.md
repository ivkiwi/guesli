# AGENTS.md

## Build Artifacts and Worktrees

SwiftPM can write build artifacts to `native/MuesliNative/.build` inside the active worktree. That can consume several GB per worktree when multiple feature worktrees are used.

Local build scripts resolve a shared SwiftPM scratch path through `scripts/muesli_spm_cache.sh`:

- If `MUESLI_SWIFTPM_SCRATCH_PATH` is set, that explicit path wins.
- If `MUESLI_SWIFTPM_SCRATCH_CHANNEL` is set, scripts use that channel under the resolved cache root.
- If `MUESLI_EXTERNAL_SPM_CACHE_ROOT` is set, it replaces the default `/Volumes/MuesliBuildCache/muesli-spm` external cache root.
- Otherwise, if `/Volumes/MuesliBuildCache/muesli-spm` is mounted, scripts use that external APFS cache.
- Otherwise, scripts fall back to `$HOME/Library/Caches/muesli-spm`.
- Set `MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1` to intentionally use SwiftPM's package-local `.build`; this takes precedence over all scratch path settings.

The external cache lives in an APFS sparse bundle at `/Volumes/eSSD/MuesliBuildCache.sparsebundle`; attach it before build-heavy work:

```bash
hdiutil attach /Volumes/eSSD/MuesliBuildCache.sparsebundle
```

`/Volumes/eSSD/MuesliBuildCache.sparsebundle` is the maintainer's local SSD path. Contributors can substitute their own volume path or skip the attach step; scripts fall back to `~/Library/Caches/muesli-spm` when the external cache is not mounted.

Default channels:

```bash
./scripts/dev-test.sh                 # /Volumes/MuesliBuildCache/muesli-spm/worktrees/<worktree>/dev when mounted
./scripts/build_native_app.sh release # /Volumes/MuesliBuildCache/muesli-spm/release when mounted
./scripts/release-preprod.sh          # /Volumes/MuesliBuildCache/muesli-spm/preprod when mounted
```

For direct or concurrent worktree builds, pass a specific path:

```bash
MUESLI_SWIFTPM_SCRATCH_PATH="/Volumes/MuesliBuildCache/muesli-spm/worktrees/pr182/dev" ./scripts/dev-test.sh
swift test --package-path native/MuesliNative --scratch-path "/Volumes/MuesliBuildCache/muesli-spm/worktrees/pr182/test"
```

Caveat: do not run concurrent builds from different worktrees into the same scratch path. Use separate paths per channel, agent, or simultaneous build, such as `worktrees/pr182/dev`, `worktrees/pr188/dev`, or `agent-1`.

## Parallel Dev Lanes

Use fixed lanes when testing multiple worktrees side by side:

```bash
./scripts/dev-test.sh --lane A
./scripts/dev-test.sh --lane B
./scripts/dev-test.sh --lane C
```

Named lanes install as `/Applications/GuesliDevA.app`, `/Applications/GuesliDevB.app`, and `/Applications/GuesliDevC.app`, with matching bundle IDs `com.guesli.dev.a`, `com.guesli.dev.b`, and `com.guesli.dev.c`. Each lane has its own support directory under `~/Library/Application Support/`.

Named lanes default to local-only signing, which omits iCloud and APNs entitlements for feature work that does not test sync or push behavior. Use `--cloud-entitlements` only for lanes that have matching Apple Developer profiles and need iCloud/APNs behavior.

Deleting a scratch path only removes rebuildable SwiftPM artifacts. It does not delete installed app bundles or app data under `~/Library/Application Support/`.

For direct SwiftPM test runs, pass the scratch path yourself:

```bash
swift test --package-path native/MuesliNative --scratch-path "/Volumes/MuesliBuildCache/muesli-spm/test"
```

## Production Build & Install (Guesli) — canonical flow

This machine has NO Apple Developer ID certificate. The only correct production build command is:

```bash
MUESLI_SKIP_SIGN=1 MUESLI_SIGN_IDENTITY="Guesli Dev" ./scripts/build_native_app.sh
```

Rules (violating any of these produces a broken install):

1. ALWAYS pass both `MUESLI_SKIP_SIGN=1` and `MUESLI_SIGN_IDENTITY="Guesli Dev"`. The "Guesli Dev" self-signed identity lives in the login keychain; it gives a stable designated requirement so macOS TCC grants (Accessibility, Input Monitoring, Screen Recording, Microphone) survive rebuilds. Running the script with no env vars fails on the upstream Developer ID check; plain ad-hoc (`MUESLI_SKIP_SIGN=1` alone) signs with a changing cdhash and silently resets the user's permission grants — never do it unless explicitly instructed.
2. Never modify source, `Package.swift`, or entitlements as part of a build task. Build tasks build.
3. Never touch `~/Library/Application Support/Guesli/` (user data: database, OAuth tokens, recordings).
4. `/Volumes/MuesliBuildCache` may be unmounted — the script falls back to `~/Library/Caches/muesli-spm` automatically. Do not create other scratch paths for production builds.
5. After the script installs `/Applications/Guesli.app`, verify and relaunch:

```bash
codesign -dvv /Applications/Guesli.app 2>&1 | grep Authority   # must print: Authority=Guesli Dev
codesign --verify --deep --strict /Applications/Guesli.app     # must exit 0, no output
osascript -e 'tell application "Guesli" to quit' 2>/dev/null; sleep 2
open /Applications/Guesli.app && sleep 3 && pgrep -x Guesli    # must print a PID
```

6. Relaunch verification is strict: capture the running PID BEFORE the quit; after `open`, the new PID must DIFFER from the old one AND `ps -o lstart= -p <pid>` must be LATER than the new binary's mtime (`stat -f %m /Applications/Guesli.app/Contents/MacOS/Guesli`). If the old PID survived the AppleScript quit, `pkill -x Guesli`, wait, and relaunch — reporting the old PID as success is a task failure.
7. Report all four results (Authority, deep verify, relaunch PID + its start time vs binary mtime, app version from Info.plist). A build task is NOT done until the FRESH binary is the one running.
