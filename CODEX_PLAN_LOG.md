# CODEX_PLAN_LOG

## Summary

- Status: in progress.
- Integration branch: `codex/integration`.
- Completed: pre-flight crashfix absorption, A3 SenseVoice chunking, A4 model download temp-file leak, A5 Nemotron RNNT shape guards.
- Current next item: B1 upstream PR #268.

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

### A4: model download temp-file leak

- Status: complete on `codex/download-temp-cleanup-wt`.
- What changed: downloaded temp files now move through a cleanup helper that removes the temp file whenever the destination move fails, while leaving the successful destination move intact.
- Tests added: `DownloadUtils` covers failed move deletes temp and successful move creates destination/removes temp.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-download-temp-cleanup-wt --filter DownloadUtils` passed, 2 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-download-temp-cleanup-wt` passed, 1202 tests.
- Diff check: `git diff --check` passed.
- Notes: used explicit `/private/tmp/muesli-spm-download-temp-cleanup-wt` scratch path; no package-local `.build`.

### A5: Nemotron RNNT shape guards

- Status: complete on `codex/nemotron-shape-guards`; merged `codex/integration` via `fd57b5a6` so A4 log/code is included.
- What changed: RNNT CoreML array reads now validate data type, rank, dimensions, positive strides, and backing-count bounds before using unsafe pointers for mel, mel_length, encoded, encoded_length, and logits.
- Why: corrupt or skewed compiled Nemotron models should produce descriptive preprocessing/decoding errors instead of trapping on bad MLMultiArray shape/stride assumptions.
- Tests added: `NemotronRNNTShapeGuardTests` covers wrong-rank mel output and mismatched encoder dimension errors.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-nemotron-shape-guards --filter NemotronRNNTShapeGuardTests` passed, 2 Swift Testing tests; XCTest bridge executed 0 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-nemotron-shape-guards` failed, 1204 tests in 131 suites with 3 issues on the requested run. A quiet diagnostic rerun failed with 4 issues in existing full-suite tests: `StreamingVadControllerTests.swift:70`, `StreamingVadControllerTests.swift:139`, `PasteControllerTests.swift:103`, and `PasteControllerTests.swift:115`.
- Diff check: `git diff --check` passed.
- Notes: used explicit `/private/tmp/muesli-spm-nemotron-shape-guards` scratch path; no package-local `.build`, main, remotes, or code edits after merge.
