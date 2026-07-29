# Terminal V2 Release Performance Baseline

Recorded on 2026-07-29 for the SwiftTerm 1.15.0 terminal integration.

## Decision

Keep SwiftTerm, keep Metal as the default renderer, and keep Core Graphics as
the runtime fallback. Do not start a Ghostty spike from this baseline.

The five synthetic workloads place Metal between 2.03% slower and 0.06% faster
than Core Graphics at the median. The attached Release app trace contains 421
frame-lifetime intervals, 421 GPU intervals, and zero Animation Hitches. The
end-to-end PTY test records sub-millisecond PTY-read-to-renderer-submission
latency for both SwiftTerm backends, while the full output path stalls the main
thread for 18.6–18.7 seconds at the median.

The next performance target is the per-chunk main-thread work shared by
`RuntimeStore.consume` and `SwiftTermSurface.feedView`. `RuntimeStore.startLocked`
feeds every PTY chunk to the terminal surface and separately enqueues an
`OutputPipeline` projection on `MainActor`; `SwiftTermSurface.feedView` then
synchronously enters the main queue. Batching and coalescing these handoffs is
the named optimization to implement and remeasure before evaluating another
terminal engine.

## Test machine and toolchain

| Item | Value |
| --- | --- |
| Model | MacBook Pro, Mac16,7 |
| Chip | Apple M4 Pro |
| CPU | 14 cores: 10 performance, 4 efficiency |
| Memory | 48 GB |
| macOS | 26.5.2 (25F84) |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 |
| SwiftTerm | 1.15.0 |
| Build | SwiftPM Release |
| Recorded HEAD | `92784a41135905f174d2b6edf918994e05527e16` plus the Task 10 working tree |

The runner starts with `swift package clean`, builds the app and tests in
Release, and never reads or edits Aloft's `config.json`.

## Raw artifacts

- Report: `artifacts/performance/terminal-20260729T120404Z.json`
- Log: `artifacts/performance/terminal-20260729T120404Z.log`
- Metadata: `artifacts/performance/terminal-20260729T120404Z-metadata.txt`
- Report SHA-256:
  `9f574c23c329cec8d7b03f8f7f2f9b613fc5764781fd789e3d3918a7f629b3a3`
- Release app Time Profiler:
  `artifacts/performance/terminal-release-dist-time-profiler-attached.trace`
- Release app Animation Hitches:
  `artifacts/performance/terminal-release-dist-animation-hitches-attached.trace`
- OutputPipeline Time Profiler:
  `artifacts/performance/terminal-output-pipeline-attached.trace`

`artifacts/` is ignored by Git so the raw JSON, logs, metadata, and Instruments
traces stay intact locally without entering the repository. Regenerate a fresh
set with:

```bash
./script/run_terminal_benchmarks.sh
```

## Method

The report contains 18 series, five samples per series, and 90 raw Release
samples. Each sample runs in its own xctest process and is written atomically
to the report before the next process starts. This isolates AppKit and
SwiftTerm window lifetime from later samples and makes interrupted runs
resumable.

Synthetic inputs use deterministic SHA-256-identified payloads:

- 100,000,000 bytes of plain UTF-8 log lines;
- 100,000,000 bytes of ANSI color and carriage-return progress;
- 16,000,000 bytes of cursor-addressing updates;
- 16,000,000 bytes of combining Unicode and emoji;
- 16,000,000 bytes of continuous ANSI/control output.

SwiftTerm runs in a 1,200 × 800 `NSWindow` with a 20,000-line scrollback limit.
The end-to-end samples use the production `ProcessSupervisor`, real PTYs,
`RuntimeStore`, restart/stop, resize, Terminal/Text switching, a 4,000,000-byte
first generation, and a 500,000-byte restarted generation. A 16,000,000-byte
Text-path calibration did not reach its marker before the timeout and ended
after 73.795 seconds; the 4,000,000-byte gate completes all 15 PTY repetitions.

All table pairs use `median / worst`. Throughput uses decimal MB/s. RSS uses
MiB.

## Synthetic results

| Workload | Backend | Wall s | MB/s | Main stall ms | Peak RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| Plain UTF-8 100 MB | OutputPipeline | 12.606 / 12.635 | 7.933 / 7.915 | 9.378 / 11.289 | 223.1 / 223.5 |
| Plain UTF-8 100 MB | SwiftTerm CG | 1.237 / 1.252 | 80.811 / 79.878 | 1.672 / 1.681 | 317.3 / 317.5 |
| Plain UTF-8 100 MB | SwiftTerm Metal | 1.239 / 1.286 | 80.701 / 77.783 | 1.564 / 8.147 | 324.7 / 324.9 |
| ANSI progress 100 MB | OutputPipeline | 12.895 / 13.205 | 7.755 / 7.573 | 10.341 / 23.473 | 215.8 / 215.9 |
| ANSI progress 100 MB | SwiftTerm CG | 1.834 / 1.881 | 54.526 / 53.152 | 2.034 / 2.190 | 317.4 / 317.7 |
| ANSI progress 100 MB | SwiftTerm Metal | 1.833 / 1.850 | 54.556 / 54.046 | 2.037 / 3.915 | 324.6 / 324.8 |
| Cursor addressing 16 MB | OutputPipeline | 1.567 / 1.612 | 10.214 / 9.924 | 7.533 / 8.183 | 92.6 / 92.7 |
| Cursor addressing 16 MB | SwiftTerm CG | 0.295 / 0.297 | 54.206 / 53.877 | 1.325 / 1.359 | 76.2 / 76.4 |
| Cursor addressing 16 MB | SwiftTerm Metal | 0.296 / 0.307 | 54.112 / 52.164 | 1.356 / 1.447 | 83.6 / 83.6 |
| Unicode and emoji 16 MB | OutputPipeline | 1.344 / 1.346 | 11.901 / 11.888 | 6.411 / 6.497 | 58.7 / 59.0 |
| Unicode and emoji 16 MB | SwiftTerm CG | 2.077 / 2.167 | 7.705 / 7.384 | 10.336 / 21.930 | 156.9 / 157.3 |
| Unicode and emoji 16 MB | SwiftTerm Metal | 2.120 / 2.338 | 7.549 / 6.844 | 9.588 / 20.426 | 164.1 / 164.2 |
| Continuous controls 16 MB | OutputPipeline | 1.989 / 2.078 | 8.043 / 7.701 | 9.166 / 14.080 | 55.4 / 55.4 |
| Continuous controls 16 MB | SwiftTerm CG | 0.628 / 0.645 | 25.460 / 24.806 | 3.206 / 3.242 | 156.7 / 156.9 |
| Continuous controls 16 MB | SwiftTerm Metal | 0.633 / 0.636 | 25.278 / 25.176 | 3.242 / 3.347 | 164.1 / 164.2 |

Metal median throughput relative to Core Graphics:

| Workload | Metal delta |
| --- | ---: |
| Plain UTF-8 | -0.14% |
| ANSI progress | +0.06% |
| Cursor addressing | -0.17% |
| Unicode and emoji | -2.03% |
| Continuous controls | -0.71% |

## End-to-end PTY results

| Backend | Wall s | Raw PTY MB/s | Main stall s | Read-to-submit ms | Peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Text | 22.270 / 22.611 | 0.2437 / 0.2419 | 18.252 / 18.396 | 18,337 / 18,482 | 156.6 / 159.9 |
| SwiftTerm CG | 23.763 / 24.466 | 0.2229 / 0.2130 | 18.741 / 19.898 | 0.067 / 0.094 | 367.1 / 370.8 |
| SwiftTerm Metal | 23.906 / 25.360 | 0.2235 / 0.2106 | 18.622 / 19.925 | 0.063 / 0.182 | 288.5 / 290.7 |

The Text read-to-submit value measures the synchronous text projection and is
18 seconds. Both SwiftTerm backends accept the corresponding PTY chunk in less
than 0.2 ms at the worst recorded value. The shared 18-second main-thread stall
therefore occurs before or alongside renderer submission, not in kernel PTY
drain.

## Instruments attribution

### Release app Time Profiler

The opt-in Release benchmark fixture creates a visible Metal
`SwiftTermSurface`, feeds deterministic 64 KiB chunks continuously, and exits
without touching user configuration. Instruments attached to its exact PID and
recorded 14,356 one-millisecond CPU sample rows; the process exited with status
0.

Inclusive sample attribution:

| Stack | Samples | Share |
| --- | ---: | ---: |
| `SwiftTermSurface.feedView` closure | 11,924 | 83.06% |
| `Terminal.parse` | 11,921 | 83.04% |
| `EscapeSequenceParser.parse` | 11,639 | 81.07% |
| `MetalTerminalRenderer.draw` | 2,147 | 14.96% |
| `MetalTerminalRenderer.buildDrawDataPass` | 2,081 | 14.50% |
| `MetalTerminalRenderer.buildRowDrawData` | 1,663 | 11.58% |
| `MetalTerminalRenderer.glyphEntry` | 962 | 6.70% |

SwiftTerm parsing, not Metal drawing, owns the dominant Release fixture stack.

### Release app Animation Hitches

The current Xcode toolchain exposes the former Core Animation workflow as the
`Animation Hitches` template. Instruments attached to the exact Release app
PID. The target exited with status 0 after a 7.469-second captured interval.

| Metric | Result |
| --- | ---: |
| Target hitches | 0 |
| Frame-lifetime intervals | 421 |
| GPU intervals | 421 |

### Aloft OutputPipeline slow path

A separate Time Profiler attachment to the Release performance test captured
5,008 one-millisecond CPU sample rows while processing the 100 MB text
workload:

| Stack | Samples | Share |
| --- | ---: | ---: |
| `OutputPipeline.consume` | 4,997 | 99.78% |
| `OutputPipeline.flush` | 3,057 | 61.04% |
| `KeywordMatcher.append` | 944 | 18.85% |
| `GraphemeBoundaryState.startsNewCluster` | 805 | 16.07% |
| `OutputPipeline.process` | 569 | 11.36% |
| `ANSITextFilter.consume` | 483 | 9.64% |

This trace names `OutputPipeline.flush` as Aloft's largest measured text
projection consumer. Together with the production code's two main-thread
handoffs per PTY chunk, it defines the next optimization scope.
