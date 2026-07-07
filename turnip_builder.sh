#!/bin/bash -e

# The shebang's -e is ignored when CI invokes this as `bash ./turnip_builder.sh`;
# set it explicitly so a failed download/step actually fails the build.
set -e

#Define variables
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)/turnip_workdir"
base_workdir="$(pwd)"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
# Android platform SDK for mesa's android code paths; 36 = Android 16,
# which is what the KPFE (KONKR Pocket Fit Elite) ships with.
platformsdk="36"
mesasrc="https://github.com/whitebelyash/mesa-unified"
srcfolder="mesa"

clear || true

#There are 4 functions here, simply comment to disable.
#You can insert your own function and make a pull request.

# Set BUILD_TARGETS to a space-separated list of variant names to build a
# subset (e.g. BUILD_TARGETS=turnip-gen8-kpfe). Unset = build everything.
should_build(){
	[[ -z "$BUILD_TARGETS" || " $BUILD_TARGETS " == *" $1 "* ]]
}

run_all(){
	echo "====== Begin building TU V$BUILD_VERSION! ======"
	echo "Current directory: $base_workdir"
	check_deps
	prepare_workdir
	# This has path slash in the branch name and thus needs some workarounds
	if should_build turnip-gen8; then
		build_lib_for_android turnip/gen8 turnip-gen8
	fi
	if should_build turnip-gen8-sync; then
		build_lib_for_android turnip/gen8 turnip-gen8-sync "patches"
	fi
	# KPFE (KONKR Pocket Fit Elite, Snapdragon 8 Elite / Adreno 830) stability
	# build: KGSL timeline sync + forced sysmem rendering on A830.
	if should_build turnip-gen8-kpfe; then
		build_lib_for_android turnip/gen8 turnip-gen8-kpfe "patches patches-kpfe"
	fi
	# KPFE GMEM experiment: GMEM (tiled) rendering stays ENABLED on A830,
	# with A825/A829-style CCU cache windows instead of the oversized
	# a8xx_gen1 defaults (suspected cause of the GMEM write page faults).
	# KPFE-only: compiled with -mcpu=oryon-1, not safe on older SoCs.
	if should_build turnip-gen8-kpfe-gmem; then
		build_lib_for_android turnip/gen8 turnip-gen8-kpfe-gmem "patches patches-kpfe-gmem"
	fi
	#build_lib_for_android gen8-yuck
}

check_deps(){
	echo "Checking system for required Dependencies ..."
		for deps_chk in $deps;
			do
				sleep 0.25
				if command -v "$deps_chk" >/dev/null 2>&1 ; then
					echo -e "$green - $deps_chk found $nocolor"
				else
					echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
					deps_missing=1
				fi;
			done

		if [ "$deps_missing" == "1" ]
			then echo "Please install missing dependencies" && exit 1
		fi

	echo "Installing python Mako dependency (if missing) ..." $'\n'
		pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Preparing work directory ..." $'\n'
		mkdir -p "$workdir" && cd "$_"

	echo "Downloading android-ndk from google server ..." $'\n'
		curl -fSs --retry 3 https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip
	echo "Exracting android-ndk ..." $'\n'
		unzip "$ndkver"-linux.zip &> /dev/null

	echo "Downloading mesa source ..." $'\n'
		git clone $mesasrc --depth=1 --no-single-branch $srcfolder
		cd $srcfolder
}

apply_patch() {
	echo "Applying patch $1"
	if ! git apply --check $1; then
			echo "Failed to apply $1!"
			exit 1
		fi
    	git apply $1
}

# $1 - real branch, $2 - escaped branch name, $3 - optional space-separated
# list of patch directories (relative to repo root) to apply in order
build_lib_for_android(){
	echo "==== Building Mesa on $1 branch ===="
	git checkout --force origin/$1
	for patchdir in $3; do
		echo "Applying patches from $patchdir"
		for patch in "$base_workdir/$patchdir"/*; do
			apply_patch $patch
		done
	done
	echo "Pushing TU_VERSION..."
	echo "#define TUGEN8_DRV_VERSION \"v$BUILD_VERSION\"" > ./src/freedreno/vulkan/tu_version.h
	#Workaround for using Clang as c compiler instead of GCC
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"

	# KPFE GMEM experiment targets only the Snapdragon 8 Elite: tune codegen
	# for its Oryon cores. Emits ARMv8.7+ instructions — will SIGILL on
	# older SoCs, which is acceptable for this device-specific variant.
	# -mcpu=oryon-1 needs LLVM 19+; probe the NDK clang and skip the
	# tuning (with a warning) if it's too old rather than failing the build.
	cpuflags=""
	if [[ "$2" == *kpfe-gmem* ]]; then
		if "$ndk/aarch64-linux-android$sdkver-clang" -mcpu=oryon-1 -x c -c /dev/null -o /dev/null &>/dev/null; then
			cpuflags=", '-mcpu=oryon-1'"
			echo "Oryon CPU tuning enabled (-mcpu=oryon-1)"
		else
			echo -e "$red NDK clang does not support -mcpu=oryon-1, building without CPU tuning $nocolor"
		fi
	fi

	echo "Generating build files ..." $'\n'
		cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang'$cpuflags]
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++'$cpuflags, '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

		cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

		meson setup build-android-aarch64 \
			--cross-file "android-aarch64.txt" \
			--native-file "native.txt" \
			--prefix /tmp/turnip-$2 \
			-Dbuildtype=release \
			-Db_ndebug=true \
			-Dstrip=true \
			-Dplatforms=android \
			-Dvideo-codecs= \
			-Dandroid-stub=true \
			-Dgallium-drivers= \
			-Dvulkan-drivers=freedreno \
			-Dvulkan-beta=true \
			-Dfreedreno-kmds=kgsl \
			-Degl=disabled \
			-Dplatform-sdk-version="$platformsdk" \
			-Dandroid-libbacktrace=disabled \
			--reconfigure

	echo "Compiling build files ..." $'\n'
		ninja -C build-android-aarch64 install

	if ! [ -a /tmp/turnip-$2/lib/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi
	echo "Making the archive"
	pkgname="A8XX Turnip v$BUILD_VERSION"
	pkgdesc="A8xx support with some hacks. Built from $1 branch"
	if [[ "$2" == *kpfe-gmem* ]]; then
		pkgname="KPFE Turnip v$BUILD_VERSION (A830 GMEM experiment)"
		pkgdesc="EXPERIMENTAL build for KONKR Pocket Fit Elite ONLY: GMEM (tiled) rendering enabled on A830 with retuned CCU cache windows + KGSL timeline sync + Oryon codegen. May glitch; report results. Built from $1 branch"
	elif [[ "$2" == *kpfe* ]]; then
		pkgname="KPFE Turnip v$BUILD_VERSION (A830 stable)"
		pkgdesc="Stability build for KONKR Pocket Fit Elite (Snapdragon 8 Elite / Adreno 830): forced sysmem rendering on A830 + KGSL timeline sync. Built from $1 branch"
	fi
	cd /tmp/turnip-$2/lib
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "$pkgname",
  "description": "$pkgdesc",
  "author": "whitebelyash",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
zip /tmp/a8xx-$2-V$BUILD_VERSION.zip libvulkan_freedreno.so meta.json
cd -
if ! [ -a /tmp/a8xx-$2-V$BUILD_VERSION.zip ]; then
	echo -e "$red Failed to pack the archive! $nocolor"
fi
}

run_all
