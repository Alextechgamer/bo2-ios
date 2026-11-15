# iPhone frame-rate measurements

| Build | Mode | Recorded time | Two-second samples | Samples above 60 fresh FPS | Peak fresh FPS | Reported drops |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 2611131501 | Multiplayer | 256.944 s | 128 | 102 | 98.4 | 1 |
| 2611141901 | Multiplayer | 377.318 s | 188 | 87 | 108.2 | 1 |
| 2611142101 | Multiplayer | 449.405 s | 224 | 187 | 118.5 | 1 |

Fresh FPS counts newly produced frames that Metal reported displaying. Peak is the highest sample average. The export includes menus, loading, and matches without labeling them. The phone reported a 120 Hz target and Low Power Mode off. Thermal state stayed nominal in the first two runs and ranged from nominal to fair in the third.

The time-weighted mean for 2611141901 was 57.5 fresh FPS. Of 21,802 ready frame IDs, 21,732 had matching submit rows. New frames arrived more than 8.33 ms apart in 98.5% of measured intervals. This measures production cadence, including waits, rather than CPU execution time.

| Interval on 2611141901 | Median | 95th percentile |
| --- | ---: | ---: |
| Between consecutive fresh frames | 16.206 ms | 24.498 ms |
| Ready to renderer pickup | 0.773 ms | 6.368 ms |
| Pickup to Metal commit | 3.099 ms | 5.180 ms |
| Ready to Metal commit | 4.144 ms | 10.232 ms |

Build 2611142101 averaged 68.8 fresh FPS across the run, weighted by sample duration. Of 31,493 ready frame IDs, 30,963 had submit rows. Of 31,492 fresh-frame intervals, 94.6% exceeded the 8.33 ms budget. Match-only performance remains unmeasured.

| Interval on 2611142101 | Median | 95th percentile |
| --- | ---: | ---: |
| Between consecutive fresh frames | 14.384 ms | 19.596 ms |
| Ready to renderer pickup | 0.787 ms | 6.237 ms |
| Pickup to Metal commit | 2.186 ms | 3.922 ms |
| Ready to Metal commit | 3.053 ms | 8.956 ms |

The multiplayer executable reads `com_maxfps` and a second runtime limit at `0x6c5cc5–0x6c5cf7`. A positive second limit can apply even with `com_maxfps` set to zero. The loop divides 1000 by the effective limit using integer division and requests 1 ms waits while elapsed time is below that target. A limit of 60 would select 16 ms. The device export omits the effective limit and time spent inside the loop, so the share attributable to pacing remains unknown.

Build 2611142201 adds one pacing row per multiplayer engine-loop iteration. `limiterWaitMs` sums the monotonic elapsed time inside that iteration's wait calls. `pickedFPS` is the signed value after the engine selects between the two limits. Zero waits produce a zero-duration row. `lastReady` identifies the most recent ready event observed by the exporter, which can belong to a different engine iteration.

For this diagnostic build, disassemble the supported MP `batch_0.bc` with LLVM 17, run `python3 ios/instrument_mp_limiter.py original.ll traced.ll`, and assemble the result as `batch_0.bc` in a separate input directory. Use that directory as `FOLD_SRC` and a fresh `FOLD_OUT` when running `fold_modes.sh` for MP slice 0. Link the resulting object alongside the MP input object built with the current `controller-friction.patch`.

Build 2611141901 also records a sequence number each time a nonempty game frame becomes ready. `intervalMs` measures elapsed time since the previous ready frame (−1 for the first). For each fresh frame submitted, `pickupWaitMs` measures ready-to-renderer pickup and `pickupToCommitMs` measures pickup to the start of Metal command-buffer commit. Their sum is `readyToCommitMs`. A ready frame superseded before pickup has no submit row. A 120 FPS cadence gives about 8.33 ms between new frames. CPU-side commit and GPU completion are separate events.
