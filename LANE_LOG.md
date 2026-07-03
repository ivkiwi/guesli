# LANE_LOG

## 2026-07-03 - D2 PDF export off main thread

- Status: complete on `codex/lane-summary`.
- AppKit check: Apple thread-safety guidance marks `NSView` descendants as main-thread-only and `NSAttributedString` as generally thread-safe, so the PDF path no longer uses `NSTextView`/`NSPrintOperation`.
- What changed: manual export now presents `NSSavePanel` on main, then builds Markdown, attributed text, pagination, and PDF bytes on a user-initiated background queue. `MeetingMarkdownAutoExporter` reuses the same off-main shared writer instead of wrapping it in `MainActor.run`.
- PDF renderer: replaced synchronous print operation with Core Text pagination into a `CGContext` PDF, preserving the manual attributed-string builder and avoiding `NSAttributedString(html:)`.
- Targeted tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter MeetingExporterTests` passed, 24 tests.
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter 'MeetingExporterTests|MeetingMarkdownAutoExporterTests'` passed, 36 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary` passed, 1225 tests in 132 suites.
- Flaky note: `PasteController` and `StreamingVadController` passed in the full suite; no quiet rerun needed.

## 2026-07-03 - B4 upstream meeting auto-export

- Status: complete on `codex/lane-summary`.
- Source: `git fetch origin`; inspected Muesli-HQ/muesli PR #263 merge `9a91db7c` and commits `c7ccc280`, `d0a83d63`, `ab9f14a7`, `da605806`, `ae5745b6`.
- Cherry-pick: `git cherry-pick -x c7ccc280` conflicted in `Models.swift` and `SettingsView.swift`; aborted and manually reapplied the merged upstream behavior.
- What changed: added `MeetingMarkdownAutoExporter` to auto-export completed meeting notes as Markdown and optional PDF to a configured folder, reusing existing `MeetingExporter` markdown/PDF rendering.
- Guesli adaptation: exporter defaults to `AppIdentity.supportDirectoryURL`, uses a Guesli bundle-id fallback for unified logging, and Settings copy/path behavior stays fork-local.
- Targeted tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter MeetingMarkdownAutoExporterTests` passed, 12 tests.
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter 'MeetingHookIntegrationTests|MeetingExporterTests|AppConfig'` passed, 71 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary` passed, 1224 tests in 132 suites.
- Diff check: `git diff --check` passed.
- Flaky note: `PasteController` and `StreamingVadController` passed in the full suite; no quiet rerun needed.

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
