#!/bin/bash
# KPFE driver diagnostic collector.
# Run on a PC (Linux/macOS/WSL/Git-Bash) with the KPFE connected over adb.
# Produces a kpfe-report-<timestamp>.zip to attach to bug reports.
#
# Usage: bash tools/kpfe-report.sh
set -u

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[1;33m'; nc='\033[0m'

command -v adb >/dev/null 2>&1 || {
	echo -e "${red}adb not found. Install Android platform-tools first:${nc}"
	echo "  https://developer.android.com/tools/releases/platform-tools"
	exit 1
}

if ! adb get-state >/dev/null 2>&1; then
	echo -e "${red}No device visible to adb.${nc} On the KPFE: Settings -> About -> tap Build number 7x,"
	echo "then Settings -> System -> Developer options -> enable USB debugging, plug in USB,"
	echo "and accept the authorization prompt on the device."
	exit 1
fi

out="kpfe-report-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
echo -e "${green}Collecting into $out/${nc}"

have_root=0
if adb shell su -c id 2>/dev/null | grep -q uid=0; then
	have_root=1
	echo -e "${green}Root available - will collect extras (dmesg, snapshot, cache dirs).${nc}"
else
	echo -e "${yellow}No root - that's fine, collecting the non-root set.${nc}"
fi

section() { echo -e "${green}== $1${nc}"; }

# ---------------------------------------------------------------- baseline
section "1/4 Device + driver baseline"
{
	echo "### getprop (identity)"
	adb shell getprop ro.build.fingerprint
	adb shell getprop ro.soc.manufacturer
	adb shell getprop ro.soc.model
	adb shell getprop ro.build.version.release
	adb shell getprop ro.build.version.sdk
	echo
	echo "### active mesa debug properties (should be empty when not testing!)"
	adb shell getprop | grep -iE "mesa" || echo "(none set)"
	echo
	echo "### KGSL sysfs dump (GPU model, clocks, gmem size if exposed)"
	adb shell 'for f in /sys/class/kgsl/kgsl-3d0/*; do
		[ -f "$f" ] || continue
		v=$(cat "$f" 2>/dev/null | head -3 | tr "\n" " ")
		echo "$f = $v"
	done'
	echo
	echo "### thermal snapshot (idle)"
	adb shell dumpsys thermalservice 2>/dev/null | head -60
} > "$out/baseline.txt" 2>&1
echo "  -> baseline.txt"

# ---------------------------------------------------------------- repro log
section "2/4 Fault/lockup capture"
echo "Next: reproduce the problem while logcat records."
echo "  1. Get the game to just BEFORE the point where it locks up / glitches."
echo "  2. Press Enter here to start recording."
echo "  3. Trigger the problem (e.g. move so shaders build)."
echo "  4. Press Enter here again to stop."
read -r -p "Press Enter to START recording (or type s to skip): " ans
if [ "${ans:-}" != "s" ]; then
	adb logcat -c 2>/dev/null
	adb logcat > "$out/logcat-full.txt" 2>&1 &
	lcpid=$!
	read -r -p "Recording... reproduce the problem now, then press Enter to STOP: "
	kill $lcpid 2>/dev/null
	wait $lcpid 2>/dev/null
	grep -iE "kgsl|adreno|gpu.*fault|pagefault|iommu|MESA|turnip|vulkan" \
		"$out/logcat-full.txt" > "$out/logcat-gpu-only.txt"
	echo "  -> logcat-full.txt, logcat-gpu-only.txt ($(wc -l < "$out/logcat-gpu-only.txt") GPU lines)"
	if [ $have_root -eq 1 ]; then
		adb shell su -c dmesg > "$out/dmesg.txt" 2>&1
		echo "  -> dmesg.txt"
		# KGSL keeps a snapshot of the last GPU hang; grab it if present.
		if adb shell su -c 'test -e /sys/class/kgsl/kgsl-3d0/snapshot' 2>/dev/null; then
			adb shell su -c 'cat /sys/class/kgsl/kgsl-3d0/snapshot' > "$out/kgsl-snapshot.bin" 2>/dev/null
			[ -s "$out/kgsl-snapshot.bin" ] && echo "  -> kgsl-snapshot.bin (GPU hang state - very useful!)"
		fi
	fi
else
	echo "  skipped"
fi

# ---------------------------------------------------------------- perf sample
section "3/4 Performance sampling (60s)"
echo "Next: play a game that performs badly, and we sample GPU clock/load/thermals."
read -r -p "Get the game running, then press Enter to sample for 60s (or type s to skip): " ans
if [ "${ans:-}" != "s" ]; then
	adb shell 'i=0; while [ $i -lt 60 ]; do
		clk=$(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null)
		busy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null)
		tz=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
		echo "t=${i}s gpuclk=$clk busy=$busy tz0=$tz"
		i=$((i+1)); sleep 1
	done' > "$out/perf-sample.txt" 2>&1
	adb shell dumpsys thermalservice 2>/dev/null | head -60 > "$out/thermal-after.txt"
	echo "  -> perf-sample.txt, thermal-after.txt"
else
	echo "  skipped"
fi

# ---------------------------------------------------------------- cache check
section "4/4 Shader cache check (root only)"
if [ $have_root -eq 1 ]; then
	read -r -p "Emulator package to check (Enter to auto-list eden/game/winlator): " pkg
	if [ -z "${pkg:-}" ]; then
		adb shell pm list packages | grep -iE "eden|yuzu|game|winlator|vita|dolphin" | tee "$out/packages.txt"
		read -r -p "Type one package name from above (without 'package:'): " pkg
	fi
	if [ -n "${pkg:-}" ]; then
		adb shell su -c "ls -laR /data/data/$pkg/cache/mesa_shader_cache*" \
			> "$out/shader-cache-$pkg.txt" 2>&1
		echo "  -> shader-cache-$pkg.txt (empty/missing = cache not engaging, tell us!)"
	fi
else
	echo "  skipped (needs root). Judge by feel instead: second launch of a game"
	echo "  should stutter much less than the first on v0.4+."
fi

# ---------------------------------------------------------------- wrap up
{
	echo "Report created: $(date)"
	echo "Driver zip tested: FILL IN (e.g. kpfe_v0.4 stable / gmem)"
	echo "Game + emulator:   FILL IN (e.g. TOTK on Eden x.y)"
	echo "What happened:     FILL IN"
	echo "debug.mesa.* props set during test: see baseline.txt"
} > "$out/NOTES.txt"

zip -qr "$out.zip" "$out" && echo -e "${green}Done -> $out.zip${nc} (edit $out/NOTES.txt first, then attach the zip)"
