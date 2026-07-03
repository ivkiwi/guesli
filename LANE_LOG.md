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
