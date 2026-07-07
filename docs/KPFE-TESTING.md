# KPFE data collection guide

What to test on the KONKR Pocket Fit Elite and exactly how, so driver
problems become diagnosable instead of "it was terrible". Everything
here works **without root** unless marked otherwise.

## One-time setup

1. On the KPFE: *Settings → About device → tap Build number 7 times*,
   then *Settings → System → Developer options → USB debugging: on*.
2. On a PC, install
   [Android platform-tools](https://developer.android.com/tools/releases/platform-tools)
   and connect the KPFE over USB. Accept the authorization prompt on the
   device. `adb devices` should list it.
3. Get the collector script: clone this repo or download
   [`tools/kpfe-report.sh`](../tools/kpfe-report.sh).

## The key trick: driver knobs over adb, no root, works in Eden

Mesa reads every driver option from Android **system properties** as
well as environment variables, and `debug.*` properties can be set from
`adb shell` without root. Prefix `debug.mesa.`, lowercase, dots instead
of underscores:

| Env var | adb equivalent |
|---|---|
| `TU_DEBUG=sysmem` | `adb shell setprop debug.mesa.tu.debug sysmem` |
| `TU_GMEM=1048576` | `adb shell setprop debug.mesa.tu.gmem 1048576` |
| `FD_DEV_FEATURES=…` | `adb shell setprop debug.mesa.fd.dev.features "…"` |

This applies to **every** app using the Turnip driver — including Eden,
which has no env-var UI. Rules:

* **Force-stop and relaunch** the emulator after changing a property
  (the driver reads them at startup).
* **Keep values under 91 characters** — properties are truncated above
  that, and a truncated `FD_DEV_FEATURES` makes Vulkan apps abort at
  startup.
* **Clear every property when done testing** (they persist until reboot
  and affect all games):

  ```
  adb shell setprop debug.mesa.tu.debug ""
  adb shell setprop debug.mesa.tu.gmem ""
  adb shell setprop debug.mesa.fd.dev.features ""
  ```

  `adb shell getprop | grep mesa` should print nothing afterwards.

## The tests, in priority order

Use the newest `kpfe_v*` release. Note the version in every report.

### T1 — Shader cache validation (stable zip, no props needed)

The v0.4+ builds cache compiled shaders on disk; before that, every
session recompiled everything.

1. Install the **stable** zip in Eden, launch TOTK, play ~10 minutes
   (walk around so shaders build). Note the stutter level.
2. Quit Eden completely (swipe away), relaunch, play the same area.
3. **Report:** was session 2 clearly smoother than session 1? Also
   compare against how v0.1 felt if you remember.

### T2 — The decisive GMEM test (gmem zip)

This single test decides whether the GMEM experiment continues.

1. Install the **gmem** zip.
2. `adb shell setprop debug.mesa.tu.gmem 1048576`
3. Launch any game that locked up (TOTK is fine). Play 5 minutes.
4. **If it runs without locking up:** the faults are an overflow near
   the top of GMEM. Repeat with `1572864`, then `2097152`, then
   `2621440` and report the largest value that still works.
5. **If it still locks up at 1048576:** stop, clear the property, and
   run T3 — the CCU theory is dead and we need the fault details.
6. Clear the property afterwards.

### T3 — Fault capture during a lockup

Run the collector during a reproduction:

```
bash tools/kpfe-report.sh
```

Step 2 of the script records logcat while you trigger the lockup, and
grabs the kernel GPU-fault details (plus a KGSL hang snapshot if the
device is rooted — that file pinpoints the faulting GPU unit and
address, which is exactly what we need). Attach the resulting zip.

### T4 — TOTK black-squares knob (stable zip)

Tests whether the ground flashes are the oversized sysmem depth-cache
window:

```
adb shell setprop debug.mesa.fd.dev.features "sysmem_ccu_depth_cache_fraction=1:sysmem_per_ccu_depth_cache_size=131072"
```

Force-stop Eden, relaunch TOTK, go to a spot where the black squares
flash. **Report:** still there, changed, or gone? Clear the property
afterwards. (The gmem zip has this baked in, so if you already know the
squares' behavior on that zip, say so.)

### T5 — "Performance is terrible" profiling

While a badly-performing game runs, use step 3 of `kpfe-report.sh`
(60-second GPU clock/load/thermal sample). This tells us whether the
GPU is maxed (driver/GPU bound), idling (CPU/emulator bound), or being
thermally throttled — three completely different fixes.

If the game runs in GameNative/GameHub, one more data point is gold:
run the same scene once with the **stock system driver** instead of
Turnip and note both FPS numbers. That measures how much headroom
Turnip actually has on this GPU.

## What to send back

The `kpfe-report-*.zip` from the script (fill in `NOTES.txt`), plus
one line per test: driver zip version, game/emulator, what you saw.
