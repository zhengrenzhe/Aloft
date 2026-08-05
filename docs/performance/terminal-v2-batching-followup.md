# Terminal V2 Main-Actor Batching Follow-up

Recorded on 2026-08-03 for SwiftTerm 1.15.0 after adding bounded,
generation-aware batching to the text projection path.

## Decision

Keep SwiftTerm and keep Metal as the default renderer. The batching target from
the 2026-07-29 baseline is complete; this result does not justify a Ghostty
spike.

Across five Release end-to-end samples, the Metal path completed the same PTY
start, output, resize, restart, output, and stop flow in 1.818 seconds at the
median. The previous baseline was 23.906 seconds. Its median longest main-thread
stall fell from 18.622 seconds to 0.026 seconds.

Metal remained the best production backend in the follow-up matrix. Compared
with Core Graphics, it reduced median end-to-end wall time by 1.08%, increased
raw PTY throughput by 1.12%, and reduced median peak RSS by 31.66%.

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
| Recorded HEAD | `8db6caf9146989b9b9f0a09027e56ac04efde99c` plus the batching working tree |

## Raw artifacts

- Report: `artifacts/performance/terminal-20260803T055818Z.json`
- Log: `artifacts/performance/terminal-20260803T055818Z.log`
- Metadata: `artifacts/performance/terminal-20260803T055818Z-metadata.txt`
- Report SHA-256:
  `7508609cd0948b1f4bb4ee90f43e614938fe16c3b2e5701b32b04fcb4f3fbea7`
- Log SHA-256:
  `15675be73f8ef2785bd2428ea8c6df7fdd40c81be539d43744877c9b720ecc84`
- Metadata SHA-256:
  `5207e9b69ec1e65dc1108b51ab83eab9603945f865dd80857ccf1bdfad443891`

The report contains 18 series, five samples per series, and 90 raw Release
samples. The 75 synthetic samples were recorded before the monitor/restart race
fix described below. That fix changes RuntimeStore operation ownership, not the
isolated parsers or renderers used by the synthetic series. All 15 end-to-end
samples were recorded after the fix.

`artifacts/` remains ignored by Git. Regenerate a clean report with:

```bash
./script/run_terminal_benchmarks.sh
```

## End-to-end comparison

Each pair is `median / worst`. Throughput uses decimal MB/s. RSS uses MiB.

| Backend | Run | Wall s | Raw PTY MB/s | Main stall s | Read-to-submit ms | Peak RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Text | 2026-07-29 baseline | 22.270 / 22.611 | 0.2437 / 0.2419 | 18.252 / 18.396 | 18,337 / 18,482 | 156.6 / 159.9 |
| Text | 2026-08-03 batched | 2.712 / 2.741 | 2.0642 / 2.0083 | 0.039 / 0.040 | 1,614.712 / 1,691.550 | 47.3 / 50.2 |
| SwiftTerm CG | 2026-07-29 baseline | 23.763 / 24.466 | 0.2229 / 0.2130 | 18.741 / 19.898 | 0.067 / 0.094 | 367.1 / 370.8 |
| SwiftTerm CG | 2026-08-03 batched | 1.838 / 1.863 | 3.2581 / 3.1261 | 0.025 / 0.051 | 0.200 / 6.226 | 246.1 / 247.8 |
| SwiftTerm Metal | 2026-07-29 baseline | 23.906 / 25.360 | 0.2235 / 0.2106 | 18.622 / 19.925 | 0.063 / 0.182 | 288.5 / 290.7 |
| SwiftTerm Metal | 2026-08-03 batched | 1.818 / 1.832 | 3.2947 / 3.2303 | 0.026 / 0.030 | 0.121 / 0.878 | 168.2 / 170.8 |

Median changes from the prior baseline:

| Backend | Wall-time reduction | Raw PTY multiplier | Main-stall reduction | Peak RSS reduction |
| --- | ---: | ---: | ---: | ---: |
| Text | 87.82% | 8.47x | 99.79% | 69.78% |
| SwiftTerm CG | 92.27% | 14.62x | 99.87% | 32.96% |
| SwiftTerm Metal | 92.40% | 14.74x | 99.86% | 41.70% |

## Synthetic renderer comparison

Metal median throughput relative to Core Graphics in the fresh Release run:

| Workload | Metal delta |
| --- | ---: |
| Plain UTF-8 | -0.88% |
| ANSI progress | +2.55% |
| Cursor addressing | -0.28% |
| Unicode and emoji | +5.84% |
| Continuous controls | +1.41% |

## Concurrency defect found by the matrix

The first fresh end-to-end restart exposed a deterministic conflict between a
monitor refresh and the explicit restart operation. A refresh could advance the
entry projection after stop and invalidate the replacement start generation.
The action then failed with “The operation was superseded by a newer process
generation.”

RuntimeStore now gives an explicit operation ownership of its entry projection:
starting an operation invalidates older monitor probes, and `refreshAll` does
not launch a new probe for an entry with an active operation. Two deterministic
concurrency tests cover both orderings. Five Text, five Core Graphics, and five
Metal real-PTY restart samples then completed without failure.
