# CODEX_PLAN_LOG

## Summary

- Status: in progress.
- Integration branch: `codex/integration`.
- Completed: pre-flight crashfix absorption, A3 SenseVoice chunking.
- Current next item: A4 model download temp-file leak.

## Journal

### Pre-flight: absorb existing crash-fix worktree

- Status: complete.
- Branch/worktree: `~/Projects/muesli-wt-crashfix` was absent; branch `fix/gigaam-file-chunking` exists and is already merged into `main` via `5d390665` (`Merge fix/gigaam-file-chunking: chunk long GigaAM files, non-fatal MLX errors`).
- Decision: no fresh `codex/gigaam-file-chunking` branch needed because `codex/integration` was created from `main` and already contains A1/A2 code.
- Evidence: `GigaAMV3FileChunking` and MLX `withError` wrapping present in `GigaAMV3Backend.swift`; `GigaAMV3FileChunking` tests present in `TranscriptionRuntimeTests.swift`.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-codex --filter GigaAMV3FileChunking` passed, 4 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-codex` passed, 1196 tests.
- Diff check: `git diff --check` passed.
- Notes: baseline compile emitted existing Swift warnings in untouched files; no new files changed for this pre-flight.

### A3: SenseVoice chunked file transcription

- Status: complete on `codex/sensevoice-chunking`.
- What changed: `SenseVoiceTranscriber.transcribe(wavURL:)` now keeps short files on the existing `SenseVoiceManager.transcribe(audioURL:)` path and chunks longer files into 15s windows with 2s overlap using FluidAudio's existing `AudioConverter`, then merges text with `TranscriptOverlapMerger`.
- Why: the old path let FluidAudio load/preprocess an entire file and then clamp internally, risking silent truncation and excessive tensors on long imports.
- Tests added: `SenseVoiceFileChunking` covers short-file passthrough, 15s/2s window math, empty input, and overlap merge.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-codex --filter SenseVoiceFileChunking` passed, 4 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-codex` passed, 1200 tests.
- Diff check: `git diff --check` passed.
- Notes: no temp files, no checkout edits, no package-local `.build`.
