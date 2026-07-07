# Turnip for the KONKR Pocket Fit Elite (KPFE)

This document describes the `turnip-gen8-kpfe` build variant: a Turnip
(Mesa Freedreno Vulkan) driver build tuned for maximum stability on the
AYANEO **KONKR Pocket Fit Elite** handheld, and the research behind it.

## Target hardware

| Component | Value |
|---|---|
| Device | AYANEO KONKR Pocket Fit Elite |
| SoC | Qualcomm Snapdragon 8 Elite |
| GPU | **Adreno 830** @ ~1100 MHz |
| KGSL chip id | `0x44050001` (`0xffff44050000` on drm) |
| OS | Android 16 (platform SDK 36) |
| Display | 6" 1080p @ 144 Hz |

The Adreno 830 is a "gen8" (A8XX) GPU. Upstream Mesa support for gen8 is
still being brought up, so these builds come from the
[whitebelyash/mesa-unified](https://github.com/whitebelyash/mesa-unified)
`turnip/gen8` branch, which carries the A8XX enablement work plus hacks
that have not (yet) landed upstream.

## What makes this variant different

### 1. Sysmem rendering is forced on A830 (the big one)

Adreno GPUs normally render in two modes: **GMEM** (tiled rendering into
fast on-chip memory) and **sysmem** (direct rendering to system memory).
On the Adreno 830, GMEM rendering in the current gen8 bring-up state hits
**write page faults** and produces a glitchy picture. The stock builds
work around this by telling users to export `TU_DEBUG=sysmem` — but most
apps that consume AdrenoTools driver packages (emulators, launchers)
don't give you a way to set driver environment variables per-game, so in
practice many KPFE users run the unstable GMEM path without knowing.

This build flips the device-info property `disable_gmem` for both
Adreno 830 chip ids (see `patches-kpfe/kpfe-a830-stability.patch`), so
**every** render pass takes the sysmem path on the KPFE with no
configuration needed. Other GPUs (A840, A825, 7XX, 6XX) are unaffected
and keep their normal GMEM/autotuner behaviour, so the zip is still safe
to install on non-KPFE devices.

Performance note: for PC-game emulation (Winlator/FEX/DXVK workloads)
GMEM rarely helps anyway — the maintainer's own release notes call it
"pretty much useless for PC emulation". Native Android games may lose a
little performance/battery versus (glitchy) GMEM, but rendering is
correct.

Escape hatches for testing:

* `FD_DEV_FEATURES=disable_gmem=0` — re-enables GMEM at runtime
  (device-info override baked into Mesa).
* `TU_DEBUG=gmem` does **not** override this (the device-level disable is
  checked first) — use `FD_DEV_FEATURES` instead.

### 2. KGSL timeline sync (Mesa MR !39751)

`patches/39751.diff` implements Vulkan timeline semaphores on top of the
KGSL kernel driver's native timeline objects instead of emulating them.
This improves synchronization correctness/latency in emulators that lean
on timeline semaphores heavily. The implementation probes the kernel at
device creation (`IOCTL_KGSL_TIMELINE_CREATE`) and **falls back to the
legacy syncobj path** if the kernel doesn't support timelines, so it
cannot break older kernels. The KPFE's Snapdragon 8 Elite kernel supports
KGSL timelines.

### 3. A830 chip-id check fix

The gen8 branch has a shader-workaround gate with an operator-precedence
bug:

```c
const bool is_a830 = chip_id == 0xffff44050000 || 0x44050001;  // always true!
```

This made `is_target_gpu` true for *every* GPU, unintentionally disabling
sample shading and per-layer fragment-density-map support everywhere. The
KPFE patch fixes the comparison. Behaviour on the KPFE itself is
unchanged (it *is* an A830, so the workarounds still apply); the fix
keeps the build correct on any other device it lands on.

### 4. Release-quality build flags

* `-Db_ndebug=true` — Mesa's recommended setting for release builds.
  Without it, `assert()`s stay compiled in, and any of the numerous
  bring-up asserts in the gen8 code aborts the whole game/emulator
  instead of (usually) rendering through the problem.
* Single, consistent `-Dplatform-sdk-version=36` (Android 16 — what the
  KPFE ships with). The build script previously passed the option twice
  with two different values.
* LTO stays disabled (historically broke these builds).

### 5. On-disk shader cache enabled on Android (both KPFE variants)

Upstream Mesa ships with the disk shader cache **disabled by default on
Android**, and even when enabled it can't find a writable directory
inside an app sandbox (no usable `HOME`/`XDG_CACHE_HOME`). The result:
every emulator session recompiles every pipeline from scratch — in
shader-heavy titles (TOTK in Eden being the worst case) that's minutes
of stutter/lockups on *every* launch, not just the first.

`patches-kpfe-common/kpfe-android-shader-cache.patch` fixes both halves:

* the cache is enabled by default on Android
  (`MESA_SHADER_CACHE_DISABLE=true` turns it back off), and
* when no cache path is set in the environment, the driver falls back to
  the host app's own cache directory
  (`/data/data/<package>/cache/mesa_shader_cache_db`), which is always
  writable from inside the sandbox. Apps that already export
  `MESA_SHADER_CACHE_DIR` (Winlator forks and friends) keep their
  configured path.

What to expect: the **first** run of a game still compiles everything
(combine with the emulator's async-shader option — in Eden enable
*Settings → Graphics → Use asynchronous shaders*). Subsequent runs hit
the cache and the compile stalls largely disappear. Clearing the
emulator app's data/cache in Android settings also clears the shader
cache. Default cache cap is 1 GB per app.

## The GMEM experiment variant (`turnip-gen8-kpfe-gmem`)

The stability build above buys correctness by forcing sysmem rendering,
which costs performance — most of all in console emulators like **Eden**,
whose tiler-friendly render passes are exactly what GMEM (tiled)
rendering accelerates on a bandwidth- and thermal-limited handheld.
The `turnip-gen8-kpfe-gmem` variant attacks the underlying GMEM bug
instead of avoiding it, and is tuned for the KPFE **only**.

### Why GMEM might be fixable: the CCU cache theory

On gen8, the CCUs (color cache units) carve their color and depth cache
windows out of GMEM, and the sizes/offsets are computed from per-GPU
device-info properties (`fd6_gmem_cache.h`). In the gen8 device table,
**A830 is the only gen8 GPU with no per-GPU CCU cache tuning** — it
inherits the `a8xx_gen1` template defaults, including a `FULL` 256 KB
per-CCU depth cache. Its sibling KGSL parts ship explicit, smaller
windows (A825 and A829 both use `HALF` 128 KB for the GMEM depth cache).
If the real A830 cache windows are smaller than the template assumes,
CCU depth writes land outside their window during tiled rendering —
which is precisely the observed failure: write page faults in GMEM mode.

This variant (see `patches-kpfe-gmem/kpfe-a830-gmem-experiment.patch`):

* keeps GMEM rendering **enabled** on A830 (no `disable_gmem`),
* applies the A825/A829-style CCU cache windows (`HALF` 128 KB for both
  GMEM color and depth caches),
* shrinks the **sysmem** depth window the same way (`FULL` 256 KB →
  `HALF` 128 KB, matching A829) — if the template overstates the real
  cache size, this could also explain sysmem-mode artifacts such as the
  **black squares flashing across the ground in Tears of the Kingdom**
  seen on the v0.1 stable build,
* includes the same KGSL timeline-sync patch, shader-cache patch and
  chip-id fix as the stable build,
* is compiled with `-mcpu=oryon-1` (Snapdragon 8 Elite's Oryon cores)
  for CPU-side throughput (driver overhead matters most in DXVK/FEX
  workloads). This emits ARMv8.7+ instructions: **do not install this
  zip on other devices** — it can crash outright on older SoCs.
  (LTO was tried and rejected: Mesa's build system hard-errors on it,
  upstream considers LTO builds a source of undebuggable issues.)

### Test results so far

* **v0.x (HALF/128K CCU windows): FAILED on TOTK/Eden** — the device
  locks up as soon as shader building starts (new pipelines → new render
  passes → GMEM path → fault/recovery loop). The first CCU guess didn't
  fix the faults. Note that a large part of the *perceived* lockup was
  also the missing shader cache (fixed separately, see above) — retest
  after the cache lands before drawing final conclusions.

Next diagnostics, in order of information value (all runtime, no
rebuild — set these on the **gmem** build):

1. **Shrink usable GMEM**: `TU_GMEM=1048576`. If GMEM rendering starts
   working with only 1 MB in use, the faults are an overflow at the top
   of GMEM (CCU/VPC carveout accounting) and we bisect upward
   (`1572864`, `2097152`, …) to find the real limit. **If it still
   faults at 1 MB, the CCU-overflow theory is dead** and the bug is in
   the tiling path itself (VSC/binning), i.e. only fixable upstream.
2. Smaller depth window: append
   `FD_DEV_FEATURES=gmem_ccu_depth_cache_fraction=2:gmem_per_ccu_depth_cache_size=65536`
   (QUARTER/64K).
3. Capture the actual fault: `adb logcat -b all | grep -iE "kgsl|pagefault|fault"`
   while reproducing — the fault IOVA and unit tell us definitively
   which block is writing out of bounds. Please attach this to any
   report.

### Testing it

Install the package named **"KPFE Turnip … (A830 GMEM experiment)"**
next to the stable one and compare per game. What to look for:

* If the page faults are gone: higher and more consistent FPS (and
  better battery) in Eden and native Android games; DXVK/Winlator
  workloads should be roughly unchanged.
* Whether the TOTK ground flashes are gone (they can also be checked in
  isolation on the *stable* build — see the knobs below, the sysmem
  window change doesn't need this build).
* If GMEM still faults: glitchy picture / GPU hangs → keep using the
  stable build and report what you saw.

### Runtime tuning knobs (no rebuild needed)

`FD_DEV_FEATURES` accepts `:`-separated `name=value` overrides for any
device-info property, so testers can bisect the config from the launcher
environment:

| What | Setting |
|---|---|
| Re-enable GMEM on the **stable** build | `FD_DEV_FEATURES=disable_gmem=0` |
| Stable build + this variant's GMEM cache config | `FD_DEV_FEATURES=disable_gmem=0:gmem_ccu_color_cache_fraction=1:gmem_per_ccu_color_cache_size=131072:gmem_ccu_depth_cache_fraction=1:gmem_per_ccu_depth_cache_size=131072` |
| Test the TOTK-artifact theory on the **stable** build | `FD_DEV_FEATURES=sysmem_ccu_depth_cache_fraction=1:sysmem_per_ccu_depth_cache_size=131072` |
| Revert this variant's sysmem change at runtime | `FD_DEV_FEATURES=sysmem_ccu_depth_cache_fraction=0:sysmem_per_ccu_depth_cache_size=262144` |
| Force sysmem on this variant (A/B compare) | `TU_DEBUG=sysmem` |
| Check if an artifact is LRZ-related (diagnostic, slow) | `TU_DEBUG=nolrz` |
| Override the GMEM size the kernel reports | `TU_GMEM=<bytes>` |

Cache-fraction values: `0` = FULL, `1` = HALF, `2` = QUARTER,
`3` = EIGHTH/THREE_QUARTER (a8xx depth).

## Building

Locally:

```sh
BUILD_VERSION=1 BUILD_TARGETS=turnip-gen8-kpfe bash ./turnip_builder.sh
# → /tmp/a8xx-turnip-gen8-kpfe-V1.zip
BUILD_VERSION=1 BUILD_TARGETS=turnip-gen8-kpfe-gmem bash ./turnip_builder.sh
# → /tmp/a8xx-turnip-gen8-kpfe-gmem-V1.zip  (GMEM experiment)
```

CI: run the **Build "turnip" KPFE** workflow (`kpfe_builder.yml`), which
publishes a `kpfe_v<version>` release. The main **Build "turnip"**
workflow also builds and attaches the KPFE zip alongside the generic
variants.

## Installing on the KPFE

Install the zip with any libadrenotools-based loader — e.g. the driver
manager built into emulators (Eden/Sudachi/Vita3K/Dolphin-mmjr forks,
Winlator variants, etc.) or a standalone driver-injector app. Pick the
package named **"KPFE Turnip … (A830 stable)"**.

Recommended per-app tweaks:

* Game refuses to boot / blocks features on Qualcomm: `TU_DEBUG=deck_emu`
  (spoofs a Steam Deck / AMD GPU — patch already included in these
  builds).
* Black artifacts with a DXVK HUD: disable `DXVK_HUD`.
* Swizzling glitches in Eden and friends: try a higher render scale.

## Known limitations

* Gen8 support is bring-up-quality by nature; this variant removes the
  worst known A830 instability (GMEM faults) but cannot make the driver
  conformant.
* Forced sysmem trades some native-Android-game performance for
  correctness. Use `FD_DEV_FEATURES=disable_gmem=0` if you want to
  experiment with GMEM on a per-app basis.
* Vulkan advertises 1.4 with `vulkan-beta` enabled; some extensions are
  incomplete on gen8.
