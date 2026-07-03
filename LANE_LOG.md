# LANE_LOG

## 2026-07-03 - D1 token-budget meeting summary prompt

- Status: complete on `codex/lane-summary`.
- What changed: `MeetingSummaryClient.summaryUserPrompt` now sends a bounded transcript slice through the shared prompt path used by ChatGPT OAuth, OpenAI, OpenRouter, Ollama, LM Studio, and Custom LLM.
- Budgeting: reused the existing `transcriptChunks` splitter and the transcript-cleanup 24k character budget; long transcripts keep opening and closing sections with an explicit `[Transcript truncated: middle omitted...]` marker.
- Choice: picked middle truncation instead of map-reduce because it is deterministic, adds no extra backend calls, and composes with the existing summary retry wrapper by rebuilding the same bounded prompt on each retry.
- Targeted tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter MeetingSummaryClientTests` passed, 41 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary` passed, 1211 tests in 131 suites.
- Flaky note: `PasteController` and `StreamingVadController` passed in the full suite; no quiet rerun needed.

## 2026-07-03 - B5 #236 summary retries

- Status: complete on `codex/lane-summary`.
- Source: `gh pr diff 236 -R Muesli-HQ/muesli`; `CODEX_PLAN.md` was absent in this worktree, so `CODEX_PLAN_LOG.md` plus the lane prompt were used for scope.
- What changed: adopted upstream summary retry handling around `MeetingSummaryClient.summarize`, covering ChatGPT OAuth, OpenAI, OpenRouter, Ollama, LM Studio, and Custom LLM through the shared summary entry point.
- Config/UI: added persisted `meeting_summary_retry_count`, clamped to `0...10`, default `3`, with a Settings stepper.
- Permanent-error behavior: retries skip cancellation, ChatGPT auth errors, permanent URL errors, 4xx backend failures except transient `408`, `409`, `425`, and `429`, and backend failures without status.
- Targeted tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter MeetingSummaryClientTests` passed, 40 tests.
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter AppConfig` passed, 42 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary` passed, 1210 tests in 131 suites.
- Diff check: `git diff --check` passed.
- Flaky note: `PasteController` and `StreamingVadController` passed in the full suite; no quiet rerun needed.
