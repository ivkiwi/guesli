# Lane log

## 2026-07-03 - B2 upstream PR #235 auto-record wake timers

- Branch/worktree: `codex/lane-controller` in `/Users/kiwi/Projects/muesli-lane-controller`.
- What changed: adopted PR #235 behavior for per-event auto-record wake timers, 5-minute auto-record catch-up, shared auto-record dedup/start helper, and Teams Safe Links URL extraction.
- Why: auto-record previously depended on launch/event-change checks plus a 60s timer that App Nap can suspend, so later meetings could miss the 90s start window.
- Fork reconciliation: kept fork `startOrigin: .calendarAutoRecord` when moving auto-record start into the shared helper; fork calendar-window code from `0804d794` remained intact.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter 'MeetingNotificationController|GoogleCalendarTests'` passed, 43 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller` passed, 1210 tests; no PasteController/StreamingVadController flake rerun needed.
- Hygiene: `git diff --check` passed.
- Note: `CODEX_PLAN.md` was absent in this worktree root; B2 scope was confirmed from user prompt plus read-only sibling plan at `../muesli/CODEX_PLAN.md`.

## 2026-07-03 - C3 cancel starting-now timers from prompt actions

- Branch/worktree: `codex/lane-controller` in `/Users/kiwi/Projects/muesli-lane-controller`.
- What changed: scheduled meeting prompt `Record` and `Join & Record` actions now cancel their pending `Meeting starting now` timer through `cancelMeetingStartingNowTimer(notificationKey:)`, matching existing `Join Only` and dismiss behavior.
- Why: if recording ends before the scheduled event start, or Join & Record fails to reach recording, the old timer could still fire a redundant stale starting-now prompt.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter 'MeetingNotificationController|GoogleCalendarTests'` passed, 44 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller` passed, 1211 tests; no PasteController/StreamingVadController flake rerun needed.
- Hygiene: `git diff --check` passed.

## 2026-07-03 - C4 startup temp sweep for app temp dirs

- Branch/worktree: `codex/lane-controller` in `/Users/kiwi/Projects/muesli-lane-controller`.
- What changed: added one `AppTemporaryDirectories` registry/sweeper, wired launch cleanup through it, repointed temp directory producers to shared names, and removed dead `guesli-retranscription` cleanup.
- Why: crash/SIGKILL could leave old app-owned temp files in dictation, meeting mic, import, WAV, retained-recording, and PCM chunk dirs; launch now deletes only entries older than 1h to avoid racing live work.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter AppTemporaryDirectories` passed, 2 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller` passed, 1213 tests; no PasteController/StreamingVadController flake rerun needed.
- Hygiene: `git diff --check` passed.
