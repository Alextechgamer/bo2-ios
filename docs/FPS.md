# iPhone frame-rate measurements

| Build | Mode | Recorded time | Two-second samples | Samples above 60 fresh FPS | Peak fresh FPS | Reported drops |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 2611131501 | Multiplayer | 256.944 s | 128 | 102 | 98.4 | 1 |
| 2611141901 | Multiplayer | 377.318 s | 188 | 87 | 108.2 | 1 |

Fresh FPS counts newly produced frames that Metal reported displaying. Peak is the highest sample average. The export covers the entire run and does not distinguish menus, loading, or matches. The phone reported a 120 Hz target, Low Power Mode off, and nominal thermal state throughout.

The time-weighted mean for 2611141901 was 57.5 fresh FPS. Of 21,802 ready frame IDs, 21,732 had matching submit rows. New frames arrived more than 8.33 ms apart in 98.5% of measured intervals. This measures production cadence, including waits, rather than CPU execution time.

| Interval on 2611141901 | Median | 95th percentile |
| --- | ---: | ---: |
| Between consecutive fresh frames | 16.206 ms | 24.498 ms |
| Ready to renderer pickup | 0.773 ms | 6.368 ms |
| Pickup to Metal commit | 3.099 ms | 5.180 ms |
| Ready to Metal commit | 4.144 ms | 10.232 ms |

Build 2611141901 also records a sequence number each time a nonempty game frame becomes ready. `intervalMs` measures elapsed time since the previous ready frame (−1 for the first). For each fresh frame submitted, `pickupWaitMs` measures ready-to-renderer pickup and `pickupToCommitMs` measures pickup to the start of Metal command-buffer commit. Their sum is `readyToCommitMs`. A ready frame superseded before pickup has no submit row. A 120 FPS cadence gives about 8.33 ms between new frames. CPU-side commit and GPU completion are separate events.
