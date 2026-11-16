# iPhone frame-rate measurements

| Build | Mode | Recorded time | Two-second samples | Samples above 60 fresh FPS | Peak fresh FPS | Reported drops |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 2611131501 | Multiplayer | 256.944 s | 128 | 102 | 98.4 | 1 |
| 2611141901 | Multiplayer | 377.318 s | 188 | 87 | 108.2 | 1 |
| 2611142101 | Multiplayer | 449.405 s | 224 | 187 | 118.5 | 1 |
| 2611142201 | Multiplayer | 206.717 s | 103 | 76 | 119.5 | 1 |
| 2611142201 | Zombies | 128.557 s | 63 | 36 | 62.4 | 2 |
| 2611142301 | Multiplayer | 387.165 s | 193 | 149 | 115.0 | 1 |
| 2611150001 | Multiplayer | 353.054 s | 176 | 137 | 119.5 | 1 |
| 2611150101 | Multiplayer | 329.379 s | 164 | 41 | 75.8 | 1 |
| 2611150201 | Multiplayer | 341.350 s | 170 | 64 | 97.0 | 1 |
| 2611151401 | Multiplayer | 257.011 s | 128 | 64 | 94.6 | 0 |
| 2611151601 | Multiplayer | 431.604 s | 215 | 66 | 93.3 | 1 |

Fresh FPS counts newly produced frames that Metal reported displaying. Peak is the highest sample average. The export includes menus, loading, and matches without labeling them. The phone reported a 120 Hz target and Low Power Mode off. Thermal state stayed nominal in the first two runs and ranged from nominal to fair in the third.

The BO2-FPS 10 capture (2611151401) averaged 57.4 fresh displayed FPS. Thermal state stayed nominal. Median fresh-frame spacing was 16.07 ms and the 95th percentile was 24.54 ms. Among the 14,823 pumps that picked up a fresh frame, main-queue entry delay was 0.006 ms median and 0.009 ms p95. Total worker blocking was 3.42 ms median and 12.25 ms p95. CPU wall time inside Metal encoder scopes was 2.33 ms median and 4.21 ms p95. The blocking duration includes execution on the main thread, so it overlaps encoding. These timings do not measure GPU execution.

After ready frame 5,000, frame production spanned 162.06 seconds with no recorded limiter waits. Median spacing remained 15.87 ms. This capture points away from main-queue entry delay and the selected FPS limit as the source of the persistent frame-production gap. Further profiling should separate guest frame preparation, render-backend preparation, and synchronization waits. Comparisons with prior runs include different, unlabeled gameplay and cannot establish an optimization gain.

Build 2611150201 averaged 53.3 fresh displayed FPS across the capture. Of 18,347 intervals between ready frames, 99.2% exceeded 8.33 ms. Median spacing was 16.60 ms (95th percentile 28.32 ms). For the 18,210 submitted fresh frames, median ready-to-pickup time was 0.79 ms and median pickup-to-commit time was 2.74 ms. These stages may overlap production of the following frame.

For pacing rows with `lastReady >= 5000`, 13,286 of 13,287 reported a 200 FPS limit. Only 169 rows recorded a limiter wait, totaling 0.80 s. Ready frames 5,001 through 18,348 spanned 251.25 s and had a median interval of 18.03 ms. Removing these recorded waits alone could recover at most about 0.3% of this period. Earlier rows used different pacing, and the export does not identify the match boundary. To distinguish guest CPU work from blocking or scheduling delays, profile the producer thread in a repeatable local match and correlate its waits and running stacks with ready-frame intervals.

### BO2-FPS 11: preparation and synchronization

Build 2611151601 averaged 55.46 fresh displayed FPS, weighted by reporting-window duration. All 24,156 preparation IDs matched unique ready IDs. Thermal samples were nominal in 159 windows and fair in 57; Low Power Mode was off. The capture includes unlabeled menus, loading and gameplay, so the difference from the previous build is not a controlled performance comparison.

For ready IDs greater than 5,000, 19,156 frames spanned 348.136 seconds. This cutoff excludes startup but does not establish an exact match boundary. All 19,156 corresponding pacing rows selected 200 FPS and recorded zero waits. All device-lock wait totals in this interval were zero. 99.48% of frame intervals exceeded the 8.33 ms budget.

| Measurement, ready ID > 5,000 | Median | 95th percentile |
| --- | ---: | ---: |
| Fresh-frame interval | 17.914 ms | 25.858 ms |
| First draw request to publication | 11.528 ms | 18.766 ms |
| Summed indexed-draw preparation | 3.082 ms | 5.081 ms |
| Draw recording (included in preparation) | 0.894 ms | 1.430 ms |
| Draw-list lock acquisition | 0.091 ms | 0.234 ms |
| Publication lock acquisition | 0.000 ms | 0.000 ms |
| Main-queue entry delay, fresh pumps | 0.007 ms | 0.011 ms |
| Render-worker blocking, fresh pumps | 5.435 ms | 12.845 ms |
| CPU Metal encoding, fresh pumps | 3.875 ms | 6.284 ms |

Per-frame subtraction gives a median 6.143 ms between the previous publication and the first recorded draw request, and a median 8.462 ms inside the draw span outside the summed indexed-draw calls. These residuals were nonnegative in every selected frame. They are wall-time accounting gaps, not measurements of CPU execution or identified synchronization waits. The summed draw timing and first-record timing have slightly different boundaries. Concurrent work and scheduling can contribute. Separate medians must not be added to reconstruct one frame.

The measured graphics locks and frame limiter do not explain the sustained cadence. Most production time remains outside the instrumented indexed-draw calls. The next investigation should time the guest render-command producer/consumer boundary, other graphics-state preparation, and job/event waits, with running-versus-blocked stack samples in a repeatable local match. Metal encoding remains meaningful work, but runs on another stage and cannot simply be added to the production interval. No optimization gain or specific unmeasured bottleneck is established by this capture.

### Simulator comparison on Aftermath

After BO2-FPS 11, two eight-second stack samples of the 2611151601 MP framework were captured in the simulator with a stationary view. A subsequent debugger read confirmed client state 10 and map `mp_la`. An earlier sample overlapped loading and was excluded. The guest render thread was identified by its `real_draw`/`gfx_real_draw` stacks (`bo2_h6_6db650`). The simulator host retains its development launcher; its framework was the diagnostic MP framework, adapted for the simulator.

| Inclusive stack category on guest render thread | First capture (3,668 samples) | Repeat (3,438 samples) |
| --- | ---: | ---: |
| Guest routine `sub_46c310` and descendants | 3,139 (85.6%) | 2,818 (82.0%) |
| Graphics API bridge `d3d_vtbl_dispatch` | 1,494 (40.7%) | 1,401 (40.8%) |
| Indexed-draw preparation `real_draw` | 862 (23.5%) | 789 (22.9%) |
| `Sleep` shim and descendants | 36 (1.0%) | 83 (2.4%) |
| Single-object event wait shim | 1 (<0.1%) | 0 |
| Texture registration/copy `gfx_register_texture_vol` | 129 (3.5%) | 113 (3.3%) |
| Buffer backing lookup `buf_data_addr` | 133 (3.6%) | 134 (3.9%) |

Counts use each matching subtree once, excluding nested matches of the same category. Categories overlap; these are wall-clock stack observations, not CPU-time measurements. They cannot be added or converted directly into recoverable phone milliseconds. Worker-pool threads do spend substantial time waiting for events, but those idle waits are not evidence that the guest render thread is blocked on the same events.

This repeat narrows the next instrumentation target: measure the whole graphics API bridge, split draw calls from state/resource calls, and attribute resource-copy bytes and time. In the repeat, 109 samples of memory copying were under texture registration, 82 under indexed-draw guest-memory reads, and 47 under other graphics-bridge guest-memory reads. Source inspection confirms that `real_draw` already caches constant-buffer contents by object, address and generation; removing copies or caching addresses without respecting updates would risk stale rendering. The broader guest routine also needs inclusive timing before attributing the remaining time to synchronization. No runtime behavior or scheduling policy was changed during this investigation.

The iOS 26 simulator ran the installed development build (`org.bo2.devloop.fullgame`, version 1) in offline Multiplayer. The game reported `state=10 map=mp_la match=1` before sampling. In an eight-second stack sample, the host render-pump worker was waiting for the main queue in 1,348 of 2,152 observations and sleeping between pumps in 801. A separate guest render thread was preparing draws. These are wall-clock samples of concurrent threads, so the wait counts do not measure CPU cost or identify how much time a phone could recover.

Build 2611151401 exports one `renderFrame` row per submitted render pump. Positive IDs match the existing `submit` and `ready` rows. Zero means that the pump did not pick up a fresh draw list. `mainQueueWaitMs` runs from dispatch on the worker to entry on the main thread. `workerBlockedMs` runs from dispatch until the worker resumes and includes main-thread execution. Both are zero for direct main-thread calls. `metalEncodeMs` sums CPU wall time from encoder creation through the end of each measured render or blit encoder in the frame pump, including work performed inside those scopes. GPU execution is outside that measurement.

Build 2611151601 adds Multiplayer and Zombies draw-production diagnostics. `prepFrame` matches the ready-frame ID. `drawSpanMs` runs from the first recorded draw request to publication. `drawPrepareMs` sums wall time inside the D3D indexed-draw preparation calls, including nested record copying and lock waits. `drawRecordMs` measures time inside draw-list recording with its mutex held. `drawMutexWaitMs` measures acquisition time on those recording calls. `publishMutexWaitMs` measures acquisition at frame publication. `deviceMutexWaitMs` aggregates contended D3D-device lock waits completed since the previous published frame. Draw-call and record-call counts accompany the timings.

These totals can overlap and include scheduling delays. Device-lock activity may come from multiple threads. This instrumentation covers the draw-production boundary and its graphics locks; guest simulation and job-system waits outside it remain part of the unexplained frame interval. Per-draw clock reads add measurement overhead. Campaign retains the prior render-pump diagnostics.

Validation for 2611151601 reached `state=10 map=mp_la match=1` in the Mac simulator. All 6,193 captured preparation rows had matching ready IDs, finite nonnegative values, and survived the actual host export parser. Archive integrity, framework catalog hashes, and code signatures passed. These checks validate the instrumentation path, not phone FPS or Zombies gameplay.

With a stationary view, the engine confirmed `sm_enable` changes in both directions. Each row summarizes ten consecutive windows of about two seconds after warm-up. The simulator recorded fresh submissions but did not report displayed frames for this build.

| Shadow maps | Fresh submissions/s | Median draw records per window's sampled frame | Median of window p95 frame intervals |
| --- | ---: | ---: | ---: |
| On, baseline | 58.78 | 3,852.5 | 23.0 ms |
| Off | 59.61 | 3,052.5 | 24.5 ms |
| On, restored | 59.05 | 3,870.5 | 23.4 ms |

Disabling shadows removed about 21% of draw records in this view. A second on/off/on pass measured process CPU time over 15 seconds per setting. The app consumed 3.75, 3.49, and 3.68 CPU seconds per wall-clock second respectively, while fresh submissions stayed between 59.23 and 59.38 per second. This suggests a CPU saving in this scene. The small throughput difference and higher p95 interval do not establish a frame-pacing improvement. The phone build's 120 Hz path still needs a comparable device measurement.

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

The 2611142201 multiplayer phone capture averaged 68.4 fresh FPS, with 13.502 ms median frame spacing. All 41,425 pacing rows reported a selected limit of zero. After ready frame 5,000, all 9,777 remaining pacing rows reported zero waits. In local practice, 50 of 1,707 changed stick samples were eligible for slowdown and 31 had different input and output values.

The Zombies capture averaged 41.8 fresh FPS including the freeze. The final zone sound milestone was `en_so_zsurvival_zm_transit` at ready frame 5,147. Script progress reached frame 5,200 and production reached ready frame 5,382. Display callbacks continued while the final 14 reporting windows showed zero fresh FPS.

The 2611142301 multiplayer capture had 4,622 changed stick samples. Assist was active in 1,539. The left trigger was below the ADS threshold in 2,155, and right-stick magnitude met the previous breakaway threshold in 1,720. These groups overlap. The export did not record the movement stick.

Build 2611150001 also uses the original MP lock-on routine in local physical-controller practice. For the release build, apply `ios/enable_mp_lockon.py` to the LLVM 17 disassembly of MP slice 46 before assembling and folding that slice, following the slice 0 procedure above. Link both instrumented slices with the updated MP input object. The stock lock-on getter remains effective outside local controller practice.

In the 2611150101 phone run, all 163 sampled target distances came from the enemy crosshair trace. Build 2611150201 enables controller assist through the normal local and Steam online launch paths in both Multiplayer and Zombies. To reproduce the Zombies framework, apply `enable_mp_lockon.py original.ll traced.ll zms` to Zombies slice 41 before folding, and compile the input object with `BO2_TARGET_ZMS`. Zombies uses its own client state, entity table, lock-on routine, and actor IDs. Both modes check the game's script-controlled assist setting and require a physical gamepad.

Build 2611141901 also records a sequence number each time a nonempty game frame becomes ready. `intervalMs` measures elapsed time since the previous ready frame (−1 for the first). For each fresh frame submitted, `pickupWaitMs` measures ready-to-renderer pickup and `pickupToCommitMs` measures pickup to the start of Metal command-buffer commit. Their sum is `readyToCommitMs`. A ready frame superseded before pickup has no submit row. A 120 FPS cadence gives about 8.33 ms between new frames. CPU-side commit and GPU completion are separate events.
