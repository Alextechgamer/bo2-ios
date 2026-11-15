# iPhone frame-rate measurements

| Build | Mode | Recorded time | Two-second samples | Samples above 60 fresh FPS | Peak fresh FPS | Reported drops |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 2611131501 | Multiplayer | 256.944 s | 128 | 102 | 98.4 | 1 |

Fresh FPS counts newly produced frames that Metal reported displaying. Peak is the highest sample average. The export covers the entire run and does not distinguish menus, loading, or matches. The phone reported a 120 Hz target, Low Power Mode off, and nominal thermal state throughout.

Build 2611141901 also records a sequence number each time a nonempty game frame becomes ready. `intervalMs` measures elapsed time since the previous ready frame (−1 for the first). For each fresh frame submitted, `pickupWaitMs` measures ready-to-renderer pickup and `pickupToCommitMs` measures pickup to the start of Metal command-buffer commit. Their sum is `readyToCommitMs`. A ready frame superseded before pickup has no submit row. A 120 FPS cadence gives about 8.33 ms between new frames. CPU-side commit and GPU completion are separate events.
